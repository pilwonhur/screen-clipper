import Foundation
import os

/// Logs to the unified log and to ~/Library/Logs/ScreenClipper.log (handy for bug reports).
public enum Log {
    private static let logger = Logger(subsystem: "com.pilwonhur.screenclipper", category: "app")
    private static let queue = DispatchQueue(label: "ScreenClipper.log")
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreenClipper.log")

    public static func info(_ message: String) { write("INFO", message); logger.info("\(message, privacy: .public)") }
    public static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }

    private static func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}
