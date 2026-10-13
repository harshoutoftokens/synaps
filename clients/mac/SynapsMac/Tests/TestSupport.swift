import Foundation
import XCTest
@testable import SynapsMac

/// Removed when the test process exits (an atexit handler can't capture context).
private var testRootForCleanup: String?

/// Points SYNAPS_CONFIG_DIR at a throwaway directory before anything touches SynapsConfig or a
/// cache store, so tests never read or write ~/.config/synaps.
enum TestEnvironment {
    static let configDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynapsMacTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("SYNAPS_CONFIG_DIR", dir.path, 1)
        testRootForCleanup = dir.path
        atexit {
            if let path = testRootForCleanup {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        return dir
    }()
    
    static func bootstrap() {
        _ = configDir
        let realConfigDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/synaps").path
        precondition(SynapsConfig.configDir.path == configDir.path, "tests must use an isolated config dir")
        precondition(SynapsConfig.configDir.path != realConfigDir, "tests must never touch ~/.config/synaps")
    }
    
    static func makeTempDir(_ label: String = "work") -> URL {
        let dir = configDir.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    static func makeCacheStore() -> LocalCacheStore {
        return LocalCacheStore(databaseURL: makeTempDir("db").appendingPathComponent("client_state.db"))
    }
    
    @discardableResult
    static func writeFile(_ url: URL, _ contents: Data) -> URL {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: contents)
        return url
    }
    
    static func fileItem(for url: URL, sha256: String? = nil, album: String? = nil, sourceId: String = "mac_test") -> SynapsFileItem {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        return SynapsFileItem(
            id: url.path,
            originalPath: url.path,
            filename: url.lastPathComponent,
            fileSize: size,
            sourceLocation: "Tests",
            modifiedAt: mtime,
            createdAt: mtime,
            sha256: sha256,
            albumName: album,
            sourceId: sourceId
        )
    }
}

class SynapsTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestEnvironment.bootstrap()
    }
    
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }
    
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }
    
    func makeClient(token: String = "", baseUrl: String = "http://nas.test:8000") -> NASClient {
        return NASClient(baseUrl: baseUrl, apiToken: token, reportsAuthFailures: false, protocolClasses: [StubURLProtocol.self])
    }
}

typealias Response = StubURLProtocol.Response

/// Answers every request of sessions configured with it, so no test touches the network.
final class StubURLProtocol: URLProtocol {
    struct Request {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
        
        var path: String { url.path }
        
        /// Query decoded the way the backend (Starlette / parse_qsl) decodes it: "+" is a space.
        var query: [String: String] {
            guard let raw = url.query(percentEncoded: true) else { return [:] }
            var result: [String: String] = [:]
            for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                func decode(_ s: Substring) -> String {
                    return String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s)
                }
                result[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
            }
            return result
        }
        
        var json: [String: Any]? {
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }
    
    struct Response {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
        var delay: TimeInterval = 0
        var error: URLError? = nil
        
        static func json(_ object: Any, status: Int = 200, delay: TimeInterval = 0) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(status: status, body: data, delay: delay)
        }
        
        static func failure(_ code: URLError.Code) -> Response {
            return Response(error: URLError(code))
        }
    }
    
    private static let lock = NSLock()
    private static var handler: ((Request) -> Response)?
    private static var requests: [Request] = []
    private static var inFlightByPath: [String: Int] = [:]
    private static var maxInFlightByPath: [String: Int] = [:]
    
    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        inFlightByPath = [:]
        maxInFlightByPath = [:]
        lock.unlock()
    }
    
    static func setHandler(_ newHandler: @escaping (Request) -> Response) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }
    
    static var recorded: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
    
    static func maxConcurrent(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return maxInFlightByPath[path] ?? 0
    }
    
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    
    override func startLoading() {
        let recorded = Request(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(of: request)
        )
        Self.lock.lock()
        Self.requests.append(recorded)
        let path = recorded.path
        Self.inFlightByPath[path, default: 0] += 1
        Self.maxInFlightByPath[path] = max(Self.maxInFlightByPath[path] ?? 0, Self.inFlightByPath[path] ?? 0)
        let handler = Self.handler
        Self.lock.unlock()
        
        let response = handler?(recorded) ?? Response(status: 599)
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [self] in
            Self.lock.lock()
            Self.inFlightByPath[path, default: 1] -= 1
            Self.lock.unlock()
            
            if let error = response.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let http = HTTPURLResponse(url: recorded.url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    
    override func stopLoading() {}
    
    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Minimal multipart/form-data reader for asserting on upload bodies.
enum Multipart {
    static func parts(of body: Data, contentType: String?) -> [String: Data] {
        guard let contentType = contentType,
              let range = contentType.range(of: "boundary=") else { return [:] }
        let boundary = "--" + contentType[range.upperBound...]
        let delimiter = Data(("\r\n" + boundary).utf8)
        var parts: [String: Data] = [:]
        var remaining = body
        // Drop the first boundary line
        guard let first = remaining.range(of: Data(boundary.utf8)) else { return [:] }
        remaining = remaining[first.upperBound...]
        while let end = remaining.range(of: delimiter) {
            var part = Data(remaining[remaining.startIndex..<end.lowerBound])
            remaining = remaining[end.upperBound...]
            if part.starts(with: Data("\r\n".utf8)) {
                part = part.dropFirst(2)
            }
            guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = String(decoding: part[part.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            let value = Data(part[headerEnd.upperBound...])
            if let nameRange = header.range(of: "name=\"") {
                let rest = header[nameRange.upperBound...]
                if let close = rest.firstIndex(of: "\"") {
                    parts[String(rest[..<close])] = value
                }
            }
        }
        return parts
    }
}
