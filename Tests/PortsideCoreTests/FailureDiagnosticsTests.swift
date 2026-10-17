import XCTest
import Darwin
@testable import PortsideCore

final class FailureDiagnosticsTests: XCTestCase {
    private let monoReport = "Native Crash Reporting\nfatal error in the mono runtime or one of the native libraries used by your application.\n"

    @MainActor private func fixture() throws -> (WineProcessManager, LibraryStore, Bottle, URL) {
        let root = try temporaryDirectory("Portside diagnostic fixture 空間")
        let bin = root.appendingPathComponent("Runtime/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$2" in
            mono|ok|wait) printf '%s\\n' 'Native Crash Reporting' 'fatal error in the mono runtime or one of the native libraries used by your application.' ;;
            header) printf '%s\\n' 'Native Crash Reporting' ;;
            fatal) printf '%s\\n' 'fatal error in the mono runtime' ;;
            *) printf '%s\\n' 'Generic Windows loader failure' ;;
        esac
        if [ "$2" = 'ok' ]; then exit 0; fi
        if [ "$2" = 'wait' ]; then printf ready > "$WINEPREFIX/ready"; exec /bin/sleep 30; fi
        exit 3
        """
        for name in ["wine", "wineboot", "wineserver"] {
            let command = bin.appendingPathComponent(name)
            try Data((name == "wine" ? script : "#!/bin/sh\nexit 0\n").utf8).write(to: command)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        }
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let runtime = WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "wine-fixture", source: "Diagnostic fixture")
        let bottle = try store.createBottle(name: "Isolated diagnostic bottle", runtime: runtime)
        return (WineProcessManager(logsURL: store.logsURL), store, bottle, try executable(in: root))
    }

    @MainActor func testCompleteMonoReportExplainsRuntimeFailureWithoutChangingExitOutcome() async throws {
        let (manager, store, bottle, exe) = try fixture()
        defer { manager.shutdownStatusWatchers() }
        for mode in ["mono", "header", "fatal", "plain", "ok"] {
            let process = try manager.run(bottle: bottle, bottleURL: store.bottleURL(for: bottle),
                                          executableURL: exe, arguments: [mode], kind: "Launch test app")
            let awaited = await manager.waitForExit(id: process.id)
            let result = try XCTUnwrap(awaited)
            XCTAssertEqual(result.exitCode, mode == "ok" ? 0 : 3)
            XCTAssertEqual(result.succeeded, mode == "ok")
            XCTAssertEqual(result.failed, mode != "ok")
            XCTAssertFalse(result.wasStopped); XCTAssertNil(result.terminationSignal)
            XCTAssertEqual(result.summary.contains("Wine Mono reported a native crash"), mode == "mono",
                           "A partial marker or successful exit must not be diagnosed as a Mono failure")
            if mode == "mono" {
                XCTAssertTrue(result.summary.contains("Wine exit code 3"))
                XCTAssertTrue(result.summary.contains("Log: \(result.logURL.path)"))
                // The banner has no stack: say so rather than blaming the application or a missing install.
                XCTAssertTrue(result.summary.contains("does not show which component failed or that .NET is missing"))
                // The traced cause class: a runtime that cannot run any 32-bit .NET program (Gcenx#160).
                XCTAssertTrue(result.summary.contains("unable to run 32-bit .NET programs at all"))
                XCTAssertTrue(result.summary.contains("Gcenx/macOS_Wine_builds#160"))
                XCTAssertTrue(result.summary.contains("reinstalling .NET or Mono cannot fix it"))
                // A concrete discriminating check, then a decision for each outcome.
                XCTAssertTrue(result.summary.contains("stop this bottle"))
                XCTAssertTrue(result.summary.contains("disposable copy"))
                XCTAssertTrue(result.summary.contains("minimal 32-bit .NET program"))
                XCTAssertTrue(result.summary.contains("mcs.exe"))
                XCTAssertTrue(result.summary.contains("choose a different Wine runtime"))
                XCTAssertTrue(result.summary.contains("declared .NET target"))
                // Superseded advice: neither removing Mono nor installing a Framework repairs this failure.
                XCTAssertFalse(result.summary.contains("remove Wine Mono"))
                XCTAssertFalse(result.summary.contains("Microsoft .NET Framework version"))
                XCTAssertFalse(result.summary.contains("Modern .NET"))
                XCTAssertFalse(result.summary.contains("4.8"))
                XCTAssertTrue(result.summary.hasSuffix("Log: \(result.logURL.path)"), "The log path ends the message so it can be copied exactly")
                XCTAssertThrowsError(try result.requireSuccess()) { error in
                    XCTAssertEqual(error.localizedDescription.components(separatedBy: result.logURL.path).count, 2,
                                   "The CLI failure should include the log path once")
                }
                XCTAssertTrue(try String(contentsOf: result.logURL, encoding: .utf8).contains("exit code 3, terminationReason=exit"))
            }
        }
    }

    @MainActor func testSignalsAndIntentionalStopsTakePrecedenceOverPrintedMonoReport() async throws {
        let (manager, store, bottle, exe) = try fixture()
        let prefix = try store.bottleURL(for: bottle)
        defer { manager.shutdownStatusWatchers() }
        for requestedStop in [false, true] {
            try? FileManager.default.removeItem(at: prefix.appendingPathComponent("ready"))
            let app = try manager.run(bottle: bottle, bottleURL: prefix, executableURL: exe, arguments: ["wait"])
            defer { kill(app.pid, SIGKILL) }
            let deadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: prefix.appendingPathComponent("ready").path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("ready").path))
            if requestedStop { _ = try await manager.stopBottle(bottle: bottle, bottleURL: prefix) }
            else { XCTAssertEqual(kill(app.pid, SIGTERM), 0) }
            let awaited = await manager.waitForExit(id: app.id)
            let result = try XCTUnwrap(awaited)
            XCTAssertEqual(result.terminationSignal, SIGTERM)
            XCTAssertEqual(result.wasStopped, requestedStop)
            XCTAssertEqual(result.failed, !requestedStop)
            XCTAssertFalse(result.succeeded)
            XCTAssertFalse(result.summary.contains("Wine Mono reported"))
        }
    }

    func testTailBoundAndRegularFileRequirementExcludeOldReportsAndSymlinks() throws {
        let root = try temporaryDirectory(), log = root.appendingPathComponent("fixture.log")
        try Data((String(repeating: "x", count: 128 * 1024) + monoReport).utf8).write(to: log)
        XCTAssertNotNil(WineFailureDiagnostics.monoCrashSummary(kind: "Known fixture", exitCode: 3, logURL: log), "Recent crash details survive a large prefix log")
        XCTAssertNil(WineFailureDiagnostics.monoCrashSummary(kind: "Known fixture", exitCode: 0, logURL: log), "A successful command must not be diagnosed as a crash")
        try Data((monoReport + String(repeating: "x", count: 128 * 1024)).utf8).write(to: log)
        XCTAssertNil(WineFailureDiagnostics.monoCrashSummary(kind: "Known fixture", exitCode: 3, logURL: log), "Reports outside the last 64 KiB are not read")
        try Data(monoReport.utf8).write(to: log)
        let alias = root.appendingPathComponent("alias.log")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: log)
        XCTAssertNil(WineFailureDiagnostics.monoCrashSummary(kind: "Known fixture", exitCode: 3, logURL: alias))
        XCTAssertNil(WineFailureDiagnostics.monoCrashSummary(kind: "Known fixture", exitCode: 3, logURL: root))
        let fifo = root.appendingPathComponent("pipe.log")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertNil(WineFailureDiagnostics.monoCrashSummary(kind: "Known fixture", exitCode: 3, logURL: fifo), "A nonregular log must not block waiting for a writer")
    }
}
