import XCTest
import Darwin
@testable import PortsideCore

final class ProcessLifecycleTests: XCTestCase {
    private final class WeakManager {
        weak var value: WineProcessManager?
        init(_ value: WineProcessManager?) { self.value = value }
    }
    private var root: URL!
    private let files = FileManager.default

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("Portside lifecycle \(UUID().uuidString) 空間")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try files.removeItem(at: root) }

    private func runtime(wine: String, server: String) throws -> WineRuntime {
        let bin = root.appendingPathComponent("Runtime/bin")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("wine", wine), ("wineserver", server), ("wineboot", "exit 0")] {
            let url = bin.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "wine-test", source: "Lifecycle fixture")
    }

    private func executable() throws -> URL {
        let url = root.appendingPathComponent("Windows app.exe")
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = 0x64; bytes[69] = 0x86
        bytes[84] = 240; bytes[86] = 2; bytes[88] = 0x0b; bytes[89] = 2
        try Data(bytes).write(to: url)
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture process did not reach the expected state")
    }

    @MainActor func testStopReapsPreServerLauncherRejectsRacingLaunchAndPreservesOtherBottle() async throws {
        let runtime = try runtime(wine: """
        trap '' TERM
        printf '%s\\n' "$$" > "$WINEPREFIX/launcher.pid"
        exec /bin/sleep 30
        """, server: """
        printf '%s\\n' "$1" >> "$WINEPREFIX/server-commands.txt"
        if [ "$1" = '-w' ] && [ ! -e "$WINEPREFIX/watcher-created" ]; then
            printf 'ready' > "$WINEPREFIX/watcher-created"
            exec /bin/sleep 30
        fi
        if [ "$1" = '-k' ]; then
            read launcher < "$WINEPREFIX/launcher.pid"
            if kill -0 "$launcher" 2>/dev/null; then exit 9; fi
            printf 'launcher reaped' > "$WINEPREFIX/stop-order.txt"
            exit 1
        fi
        exit 0
        """)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let selected = try store.createBottle(name: "Selected", runtime: runtime)
        let other = try store.createBottle(name: "Preserve", runtime: runtime)
        let selectedURL = try store.bottleURL(for: selected), otherURL = try store.bottleURL(for: other)
        let manager = WineProcessManager(logsURL: store.logsURL)
        let exe = try executable()
        let first = try manager.run(bottle: selected, bottleURL: selectedURL, executableURL: exe)
        let second = try manager.run(bottle: other, bottleURL: otherURL, executableURL: exe)
        defer { kill(first.pid, SIGKILL); kill(second.pid, SIGKILL); manager.shutdownStatusWatchers() }
        try await waitUntil { self.files.fileExists(atPath: selectedURL.appendingPathComponent("launcher.pid").path) && self.files.fileExists(atPath: otherURL.appendingPathComponent("launcher.pid").path) }
        await manager.refreshBottleStatus(bottle: selected, bottleURL: selectedURL)
        try await waitUntil { self.files.fileExists(atPath: selectedURL.appendingPathComponent("watcher-created").path) }
        let watcher = try XCTUnwrap(manager.running.first { $0.id != first.id && $0.id != second.id })
        XCTAssertFalse(first.isSessionWatcher)
        XCTAssertFalse(second.isSessionWatcher)
        XCTAssertTrue(watcher.isSessionWatcher, "The interface must distinguish a retained session observer from an application")
        var failures: [ProcessResult] = []
        manager.onCompletion = { if $0.failed { failures.append($0) } }
        let stop = Task { try await manager.stopBottle(bottle: selected, bottleURL: selectedURL) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertThrowsError(try manager.run(bottle: selected, bottleURL: selectedURL, executableURL: exe)) { error in
            XCTAssertTrue(error.localizedDescription.contains("stopping"))
        }
        do {
            _ = try await manager.stopBottle(bottle: selected, bottleURL: selectedURL)
            XCTFail("Concurrent stops should not share or prematurely remove the stop guard")
        } catch { XCTAssertTrue(error.localizedDescription.contains("already stopping")) }
        let result = try await stop.value
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.summary, "Bottle is stopped.")
        XCTAssertNotEqual(kill(first.pid, 0), 0)
        XCTAssertNotEqual(kill(watcher.pid, 0), 0, "Stop must dispose its retained status helper before returning")
        XCTAssertEqual(kill(second.pid, 0), 0, "The other bottle's launcher must stay alive")
        XCTAssertFalse(manager.isBottleRunning(selected.id))
        XCTAssertTrue(manager.isBottleRunning(other.id))
        XCTAssertTrue(failures.isEmpty, "An intentional stop must not display launch failure alerts")
        let stoppedApp = try XCTUnwrap(manager.completed.first { $0.id == first.id })
        XCTAssertEqual(stoppedApp.exitCode, SIGKILL)
        XCTAssertEqual(stoppedApp.terminationSignal, SIGKILL)
        XCTAssertTrue(stoppedApp.wasStopped)
        XCTAssertFalse(stoppedApp.succeeded, "Stopping is not successful completion of the Windows app")
        XCTAssertFalse(stoppedApp.failed)
        XCTAssertEqual(try String(contentsOf: selectedURL.appendingPathComponent("stop-order.txt"), encoding: .utf8), "launcher reaped")
        XCTAssertEqual(try String(contentsOf: selectedURL.appendingPathComponent("server-commands.txt"), encoding: .utf8), "-w\n-k\n-w\n")
        XCTAssertFalse(files.fileExists(atPath: otherURL.appendingPathComponent("server-commands.txt").path))
        manager.onCompletion = nil
        kill(second.pid, SIGKILL)
        _ = await manager.waitForExit(id: second.id)
    }

    @MainActor func testRequestedSIGTERMStopIsNeutralAndKeepsRawDiagnostics() async throws {
        let runtime = try runtime(wine: "printf ready > \"$WINEPREFIX/ready\"\nexec /bin/sleep 30", server: "exit 0")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Stop by request", runtime: runtime)
        let prefix = try store.bottleURL(for: bottle)
        let manager = WineProcessManager(logsURL: store.logsURL)
        let app = try manager.run(bottle: bottle, bottleURL: prefix, executableURL: executable())
        defer { kill(app.pid, SIGKILL); manager.shutdownStatusWatchers() }
        try await waitUntil { self.files.fileExists(atPath: prefix.appendingPathComponent("ready").path) }
        var events: [ProcessResult] = []
        manager.onCompletion = { events.append($0) }
        _ = try await manager.stopBottle(bottle: bottle, bottleURL: prefix)
        let result = try XCTUnwrap(manager.completed.first { $0.id == app.id })
        XCTAssertEqual(result.exitCode, SIGTERM)
        XCTAssertEqual(result.terminationSignal, SIGTERM)
        XCTAssertTrue(result.wasStopped)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.failed)
        XCTAssertTrue(result.summary.contains("stopped by request"))
        XCTAssertEqual(events.filter { $0.id == app.id }.count, 1, "Intentional stops still publish a neutral completion")
        XCTAssertThrowsError(try result.requireSuccess(), "A stopped installer must not be considered installed successfully")
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("exit code 15, terminationReason=signal, stopRequested=true, wasStopped=true"))
    }

    @MainActor func testNormalExit15IsAFailureRatherThanASignalOrRequestedStop() async throws {
        let runtime = try runtime(wine: "exit 15", server: "exit 0")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Actual exit 15", runtime: runtime)
        let manager = WineProcessManager(logsURL: store.logsURL)
        defer { manager.shutdownStatusWatchers() }
        let app = try manager.run(bottle: bottle, bottleURL: store.bottleURL(for: bottle), executableURL: executable())
        let awaited = await manager.waitForExit(id: app.id)
        let result = try XCTUnwrap(awaited)
        XCTAssertEqual(result.exitCode, 15)
        XCTAssertNil(result.terminationSignal)
        XCTAssertFalse(result.wasStopped)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.summary.contains("exited with code 15"))
    }

    @MainActor func testUnexpectedExternalSIGTERMRemainsAFailure() async throws {
        let runtime = try runtime(wine: "printf ready > \"$WINEPREFIX/ready\"\nexec /bin/sleep 30", server: "exit 0")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "External termination", runtime: runtime)
        let prefix = try store.bottleURL(for: bottle)
        let manager = WineProcessManager(logsURL: store.logsURL)
        let app = try manager.run(bottle: bottle, bottleURL: prefix, executableURL: executable())
        defer { kill(app.pid, SIGKILL); manager.shutdownStatusWatchers() }
        try await waitUntil { self.files.fileExists(atPath: prefix.appendingPathComponent("ready").path) }
        XCTAssertEqual(kill(app.pid, SIGTERM), 0)
        let awaited = await manager.waitForExit(id: app.id)
        let result = try XCTUnwrap(awaited)
        XCTAssertEqual(result.exitCode, SIGTERM)
        XCTAssertEqual(result.terminationSignal, SIGTERM)
        XCTAssertFalse(result.wasStopped)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.summary.contains("terminated by signal 15"))
    }

    /// Keep the main actor occupied until Foundation has reaped the child, so its
    /// queued completion cannot run until Stop Bottle starts. No real Wine is used.
    private func waitForReapedChild(_ pid: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return kill(pid, 0) != 0
    }

    @MainActor func testStopDoesNotRelabelOrHideAnAlreadyExitedFailure() async throws {
        let runtime = try runtime(wine: "exit 15", server: "exit 0")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Failure before Stop", runtime: runtime)
        let prefix = try store.bottleURL(for: bottle)
        let manager = WineProcessManager(logsURL: store.logsURL)
        defer { manager.shutdownStatusWatchers() }
        let app = try manager.run(bottle: bottle, bottleURL: prefix, executableURL: executable())
        XCTAssertTrue(waitForReapedChild(app.pid), "Child must exit before Stop signals any tracked launcher")
        var failures: [ProcessResult] = []
        manager.onCompletion = { if $0.failed { failures.append($0) } }
        _ = try await manager.stopBottle(bottle: bottle, bottleURL: prefix)
        let result = try XCTUnwrap(manager.completed.first { $0.id == app.id })
        XCTAssertFalse(result.wasStopped)
        XCTAssertNil(result.terminationSignal)
        XCTAssertTrue(result.failed)
        XCTAssertEqual(failures.map(\.id), [app.id], "Bottle-level stopping must not hide a genuine prior launch failure")
    }

    @MainActor func testSignal1IsNotAcceptedAsIdleStopRequestExit1() async throws {
        let runtime = try runtime(wine: "exit 0", server: """
        if [ "$1" = '-k' ]; then kill -HUP $$; fi
        printf unexpected > "$WINEPREFIX/unexpected-wait"
        exit 0
        """)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Stop request signal", runtime: runtime)
        let prefix = try store.bottleURL(for: bottle)
        let manager = WineProcessManager(logsURL: store.logsURL)
        defer { manager.shutdownStatusWatchers() }
        do {
            _ = try await manager.stopBottle(bottle: bottle, bottleURL: prefix)
            XCTFail("A signal numbered 1 must not pass the normal exit-1 idle rule")
        } catch { XCTAssertTrue(error.localizedDescription.contains("signal 1")) }
        let result = try XCTUnwrap(manager.completed.first)
        XCTAssertEqual(result.terminationSignal, SIGHUP)
        XCTAssertTrue(result.failed)
        XCTAssertFalse(result.wasStopped)
        XCTAssertFalse(files.fileExists(atPath: prefix.appendingPathComponent("unexpected-wait").path))
    }

    @MainActor func testShutdownOnlyEndsWatchersAndPreventsTheirRecreation() async throws {
        let runtime = try runtime(wine: """
        if [ "$2" = '--fast' ]; then exit 0; fi
        exec /bin/sleep 30
        """, server: """
        printf '%s\\n' "$1" >> "$WINEPREFIX/server-commands.txt"
        exec /bin/sleep 30
        """)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Alive session", runtime: runtime)
        let prefix = try store.bottleURL(for: bottle)
        let manager = WineProcessManager(logsURL: store.logsURL)
        let exe = try executable()
        let app = try manager.run(bottle: bottle, bottleURL: prefix, executableURL: exe)
        defer { kill(app.pid, SIGKILL); manager.shutdownStatusWatchers() }
        await manager.refreshBottleStatus(bottle: bottle, bottleURL: prefix)
        let watcher = try XCTUnwrap(manager.running.first { $0.id != app.id })
        try await waitUntil { self.files.fileExists(atPath: prefix.appendingPathComponent("server-commands.txt").path) }
        var failures: [ProcessResult] = []
        manager.onCompletion = { if !$0.succeeded { failures.append($0) } }
        manager.shutdownStatusWatchers()
        _ = await manager.waitForExit(id: watcher.id)
        XCTAssertNotEqual(kill(watcher.pid, 0), 0)
        XCTAssertEqual(kill(app.pid, 0), 0, "Frontend shutdown must preserve the user's Windows app")
        XCTAssertTrue(manager.isBottleRunning(bottle.id))
        XCTAssertTrue(failures.isEmpty, "Disposing frontend helpers must not surface Wine failure alerts")
        let fast = try manager.run(bottle: bottle, bottleURL: prefix, executableURL: exe, arguments: ["--fast"])
        _ = await manager.waitForExit(id: fast.id)
        await manager.refreshBottleStatuses([(bottle, prefix)])
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("server-commands.txt"), encoding: .utf8), "-w\n", "Neither explicit refresh nor launcher completion may restart watcher helpers")
        manager.onCompletion = nil
        kill(app.pid, SIGTERM)
        _ = await manager.waitForExit(id: app.id)
    }

    @MainActor func testReleasingManagerAlsoDisposesItsWatcher() async throws {
        let runtime = try runtime(wine: "exit 0", server: "trap '' TERM\nexec /bin/sleep 30")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Watcher lifecycle", runtime: runtime)
        let prefix = try store.bottleURL(for: bottle)
        var manager: WineProcessManager? = WineProcessManager(logsURL: store.logsURL)
        await manager!.refreshBottleStatus(bottle: bottle, bottleURL: prefix)
        let watcher = try XCTUnwrap(manager!.running.first)
        defer { kill(watcher.pid, SIGKILL) }
        let released = WeakManager(manager)
        manager = nil
        XCTAssertNil(released.value)
        try await waitUntil { kill(watcher.pid, 0) != 0 }
    }
}
