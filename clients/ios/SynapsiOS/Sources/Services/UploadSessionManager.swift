import Foundation

/// Persisted in URLSessionTask.taskDescription so an upload's result can be applied even when
/// it completes after the app was suspended, killed, or relaunched by the system.
public struct UploadTaskInfo: Codable, Sendable {
    public var assetId: String
    public var kind: String
    public var sha256: String
    public var size: Int64
    public var filename: String
    public var originalPath: String
    public var sourceId: String
    /// "stream" (PUT /api/v2/ingest/stream) or "multipart" (POST /api/v2/ingest/upload).
    public var endpoint: String
    /// Staging files (names in AssetExporter.uploadsDirectory) to delete once the task ends.
    public var stagingFiles: [String]
}

/// UIKit's background-session completion handler isn't Sendable; it is only invoked on main.
private final class CompletionBox: @unchecked Sendable {
    let run: () -> Void
    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

public enum UploadOutcome: Sendable {
    case success
    case httpError(status: Int, detail: String?)
    case transportError(code: Int, message: String)
    case cancelled
}

/// Owns the background URLSession used for all file uploads. Uploads keep running in
/// nsurlsessiond while the app is suspended; at most two connections are opened to the NAS
/// (dual-core, single-disk server). Foreground code awaits results through continuations;
/// results that arrive with nobody waiting are applied by SyncResultRecorder.
public final class UploadSessionManager: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let shared = UploadSessionManager()
    public static let sessionIdentifier = "com.synaps.ios.background-upload"
    
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<UploadOutcome, Never>] = [:]
    private var responseBodies: [Int: Data] = [:]
    private var backgroundEventsCompletion: (() -> Void)?
    private var _session: URLSession?
    private var lastActivity = Date()
    private let launchDate = Date()
    private let delegateQueue: OperationQueue
    
    private override init() {
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "com.synaps.ios.upload-delegate"
        super.init()
    }
    
    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _session {
            return existing
        }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 300          // NAS finalizes (hash check, move, DB) after the last byte
        config.timeoutIntervalForResource = 2 * 3600    // a staging window is capped at ~1 GB
        let created = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        _session = created
        return created
    }
    
    /// Call during launch: reconnects to uploads that continued while the app wasn't running
    /// (their results are then delivered to the delegate) and removes orphaned staging files.
    public func activate() {
        let session = self.session
        let cutoff = launchDate
        session.getAllTasks { tasks in
            let live = Set(tasks.compactMap { Self.decodeInfo($0.taskDescription) }.flatMap { $0.stagingFiles })
            AssetExporter.cleanupStagingDirectory(keeping: live, createdBefore: cutoff)
        }
    }
    
    /// From UIApplicationDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:).
    public func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        lock.lock()
        backgroundEventsCompletion = completionHandler
        lock.unlock()
        _ = session
    }
    
    /// Enqueues an upload of `fileURL` and waits for its result. The task itself survives app
    /// suspension; if this process dies, the result is applied on the next launch instead.
    public func upload(request: URLRequest, fileURL: URL, info: UploadTaskInfo) async -> UploadOutcome {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = Self.encodeInfo(info)
        return await withCheckedContinuation { (continuation: CheckedContinuation<UploadOutcome, Never>) in
            lock.lock()
            waiters[task.taskIdentifier] = continuation
            lastActivity = Date()
            lock.unlock()
            task.resume()
        }
    }
    
    /// Cancels every upload (user pressed Cancel, or the NAS disappeared mid-run).
    public func cancelAll() async {
        let tasks = await session.allTasks
        for task in tasks {
            task.cancel()
        }
    }
    
    /// Seconds since any upload made progress (bytes sent, response received, task finished).
    public var secondsSinceLastActivity: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }
    
    // MARK: - URLSessionDataDelegate
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var body = responseBodies[dataTask.taskIdentifier] ?? Data()
        if body.count < 64 * 1024 {
            body.append(data)
        }
        responseBodies[dataTask.taskIdentifier] = body
        lastActivity = Date()
        lock.unlock()
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let waiter = waiters.removeValue(forKey: task.taskIdentifier)
        lastActivity = Date()
        lock.unlock()
        
        let outcome = Self.makeOutcome(response: task.response, body: body, error: error)
        if let waiter {
            waiter.resume(returning: outcome)
            return
        }
        // Nobody is awaiting this task: the app was relaunched, or the run was stopped.
        guard let info = Self.decodeInfo(task.taskDescription) else { return }
        SyncResultRecorder.applyDetachedUploadResult(info: info, outcome: outcome)
    }
    
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundEventsCompletion.map(CompletionBox.init)
        backgroundEventsCompletion = nil
        lock.unlock()
        // UIKit requires the relaunch completion handler to be called on the main thread.
        DispatchQueue.main.async {
            completion?.run()
        }
    }
    
    // MARK: - Helpers
    
    static func makeOutcome(response: URLResponse?, body: Data, error: Error?) -> UploadOutcome {
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return .cancelled
            }
            return .transportError(code: ns.code, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .httpError(status: 0, detail: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            return .httpError(status: http.statusCode, detail: NASClient.errorDetail(from: body))
        }
        guard let decoded = try? JSONDecoder().decode(IngestUploadResponse.self, from: body), decoded.status == "success" else {
            return .httpError(status: http.statusCode, detail: "Unexpected upload response")
        }
        return .success
    }
    
    static func encodeInfo(_ info: UploadTaskInfo) -> String? {
        guard let data = try? JSONEncoder().encode(info) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    static func decodeInfo(_ description: String?) -> UploadTaskInfo? {
        guard let description, let data = description.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UploadTaskInfo.self, from: data)
    }
}
