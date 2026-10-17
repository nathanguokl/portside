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
            // The banner carries no stack, so the text must not assert a cause. A traced case (R2Beat's
            // 32-bit launcher with Gcenx Wine Stable 11.0_1 on Apple silicon) faulted inside Wine's own
            // wow64cpu.dll before any application assembly loaded, which a minimal 32-bit program reproduces.
            return "Wine Mono reported a native crash for “\(kind)” (Wine exit code \(exitCode)). " +
                "Mono's crash banner has no stack, so it does not show which component failed or that .NET is missing. " +
                "On Apple silicon the selected Wine runtime can itself be unable to run 32-bit .NET programs at all " +
                "(Gcenx Wine Stable 11.0_1 fails this way before the application's own code runs; see Gcenx/macOS_Wine_builds#160), " +
                "and then reinstalling .NET or Mono cannot fix it. " +
                "To check, stop this bottle and, in a disposable copy of it, run a minimal 32-bit .NET program " +
                "(the runtime's Wine Mono includes mcs.exe, which can build one with -platform:x86). " +
                "If that also crashes, choose a different Wine runtime; if it runs, inspect the application's declared .NET target and dependencies. " +
                "Log: \(logURL.path)"
        } catch { return nil }
    }
}
