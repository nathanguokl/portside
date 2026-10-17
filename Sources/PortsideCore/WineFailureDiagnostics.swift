import Foundation
import Darwin

enum WineFailureDiagnostics {
    /// Direct Wine children may share a large log with their Windows descendants.
    /// Inspect a bounded tail of a regular, closed log without following symlinks.
    static func monoCrashSummary(kind: String, exitCode: Int32, logURL: URL) -> String? {
        guard exitCode != 0, logURL.isFileURL else { return nil }
        let fd = open(logURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? reader.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return nil }
        let limit = 64 * 1024
        do {
            try reader.seek(toOffset: UInt64(max(0, info.st_size - off_t(limit))))
            let data = try reader.read(upToCount: limit) ?? Data()
            let tail = String(decoding: data, as: UTF8.self)
            guard tail.contains("Native Crash Reporting"), tail.contains("fatal error in the mono runtime") else { return nil }
            // The shared banner identifies a reported crash, not its cause or a missing dependency.
            return "Wine Mono reported a native crash for “\(kind)” (Wine exit code \(exitCode)). " +
                "The banner alone does not identify the failed component or show that .NET is missing. " +
                "Review the log and the application's .NET requirements. " +
                "Test runtime or dependency changes in a separate bottle. " +
                "Log: \(logURL.path)"
        } catch { return nil }
    }
}
