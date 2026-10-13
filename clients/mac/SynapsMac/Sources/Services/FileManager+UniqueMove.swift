import Foundation

extension FileManager {
    /// Moves `source` to `preferred`, or to "name (1).ext", "name (2).ext", ... when that name is
    /// taken. An existing file is never replaced. Returns the URL actually written.
    func moveItemToUniqueURL(at source: URL, preferred: URL) throws -> URL {
        let directory = preferred.deletingLastPathComponent()
        let ext = preferred.pathExtension
        let base = preferred.deletingPathExtension().lastPathComponent
        var candidate = preferred
        var n = 1
        while true {
            do {
                try moveItem(at: source, to: candidate)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists && n < 10_000 {
                candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
                n += 1
            }
        }
    }
}
