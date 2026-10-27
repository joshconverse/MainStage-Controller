import Foundation

/// Mirrors the bridge log to ~/Library/Logs/FOH Bridge.log (fresh each launch) so it can be tailed while
/// learning assignments in MainStage.
enum LogFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FOH Bridge.log")

    /// Past this the file starts over, so hours of logging can't fill the disk.
    static let maxBytes: UInt64 = 10 << 20

    private static let queue = DispatchQueue(label: "foh.bridge.logfile")
    nonisolated(unsafe) private static var handle: FileHandle? = open()
    nonisolated(unsafe) private static var written: UInt64 = 0

    private static func open() -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    static func append(_ line: String) {
        queue.async {
            let data = Data((line + "\n").utf8)
            if written + UInt64(data.count) > maxBytes {
                try? handle?.close()
                handle = open()
                written = 0
            }
            // The throwing API: the old write(_:) raised an uncatchable exception on a full disk.
            do {
                try handle?.write(contentsOf: data)
                written += UInt64(data.count)
            } catch {
                try? handle?.close()
                handle = nil   // stop writing; the in-app log keeps working
            }
        }
    }
}
