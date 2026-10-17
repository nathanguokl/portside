import XCTest
import Darwin
import PortsideCore
@testable import Portside

@MainActor final class StopControlTests: XCTestCase {
    private struct Fixture {
        let model: AppModel
        let root: URL
        let bottle: Bottle
        let executable: URL
    }

    private func fixture(wine: String? = nil) throws -> Fixture {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Portside stop controls \(UUID().uuidString) 空間")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? files.removeItem(at: root) }
        let bin = root.appendingPathComponent("Fixture Runtime/bin")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let commands = [
            "wine": wine ?? "printf 'ready' > \"$WINEPREFIX/launcher-ready\"\nexec /bin/sleep 30",
            "wineboot": "exit 0",
            "wineserver": "printf '%s\\n' \"$1\" >> \"$WINEPREFIX/server-commands.txt\"\nif [ \"$1\" = '-k' ]; then exit 1; fi\nexit 0"
        ]
        for (name, body) in commands {
            let command = bin.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: command)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        }
        let runtime = WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "stop-control-fixture",
                                  source: "Isolated test; does not run Wine")
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false)
        let store = try XCTUnwrap(model.store)
        let bottle = try store.createBottle(name: "Selected bottle", runtime: runtime)
        try store.markBottleInitialized(id: bottle.id)
        model.sync()
        model.selected = bottle.id

        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = 0x64; bytes[69] = 0x86
        bytes[84] = 240; bytes[86] = 2; bytes[88] = 0x0b; bytes[89] = 2
        let executable = root.appendingPathComponent("Fixture app 中文.exe")
        try Data(bytes).write(to: executable)
        return Fixture(model: model, root: root, bottle: try store.requireBottle(id: bottle.id), executable: executable)
    }

    private func cleanup(_ fixture: Fixture) {
        guard let processes = fixture.model.processes else { return }
        processes.onCompletion = nil
        processes.shutdownStatusWatchers()
        // This manager contains only this test's explicitly started sleep fixtures.
        for process in processes.running { kill(process.pid, SIGKILL) }
    }

    private func prefix(_ fixture: Fixture, bottle: Bottle? = nil) throws -> URL {
        try XCTUnwrap(fixture.model.store).bottleURL(for: bottle ?? fixture.bottle)
    }

    private func logs(_ fixture: Fixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: XCTUnwrap(fixture.model.store).logsURL,
                                                   includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }

    private func startLauncher(_ fixture: Fixture, bottle: Bottle? = nil) throws -> RunningWineProcess {
        let target = bottle ?? fixture.bottle
        return try XCTUnwrap(fixture.model.processes).run(bottle: target, bottleURL: prefix(fixture, bottle: target),
                                                        executableURL: fixture.executable, kind: "Launch fixture")
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testIdleStopDoesNotRunCommandsCreateLogsOrChangeActivity() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let model = fixture.model
        let before = try logs(fixture)
        XCTAssertFalse(model.canStop(fixture.bottle))

        model.stop(fixture.bottle)
        model.stop(fixture.bottle)
        for _ in 0..<12 { await Task.yield() }

        XCTAssertEqual(try logs(fixture), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try prefix(fixture).appendingPathComponent("server-commands.txt").path))
        XCTAssertTrue(try XCTUnwrap(model.processes).running.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.processes).completed.isEmpty)
        XCTAssertNil(model.activity)
        XCTAssertNil(model.logURL)
        XCTAssertNil(model.error)
    }

    func testTrackedLauncherEnablesStopBeforeAnyWineServerContact() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let run = try startLauncher(fixture)
        let prefix = try prefix(fixture)
        try await eventually { FileManager.default.fileExists(atPath: prefix.appendingPathComponent("launcher-ready").path) }

        XCTAssertEqual(kill(run.pid, 0), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("server-commands.txt").path))
        XCTAssertTrue(fixture.model.isRunning(fixture.bottle))
        XCTAssertTrue(fixture.model.canStop(fixture.bottle), "An owned launcher must remain stoppable before it reaches wineserver")
    }

    func testAnotherRunningBottleDoesNotEnableOrStopTheIdleBottle() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let model = fixture.model
        let other = try XCTUnwrap(model.store).createBottle(name: "Other running bottle", runtime: fixture.bottle.runtime)
        model.sync()
        let run = try startLauncher(fixture, bottle: other)
        let before = try logs(fixture)
        XCTAssertTrue(model.canStop(other))
        XCTAssertFalse(model.canStop(fixture.bottle))

        model.stop(fixture.bottle)
        for _ in 0..<12 { await Task.yield() }

        XCTAssertEqual(kill(run.pid, 0), 0, "Stopping an idle selection must not affect another bottle")
        XCTAssertEqual(try logs(fixture), before)
        XCTAssertNil(model.activity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try prefix(fixture).appendingPathComponent("server-commands.txt").path))
    }

    func testBusyAndPresentedDialogsPreventStopWithoutEndingLauncher() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let model = fixture.model
        let run = try startLauncher(fixture)
        let before = try logs(fixture)

        model.activity = "Another operation"
        XCTAssertFalse(model.canStop(fixture.bottle))
        model.stop(fixture.bottle)
        XCTAssertEqual(model.activity, "Another operation")
        model.activity = nil

        model.sheet = .settings
        XCTAssertFalse(model.canStop(fixture.bottle))
        model.stop(fixture.bottle)
        model.sheet = nil
        XCTAssertFalse(model.canStop(fixture.bottle), "A dismissing sheet still owns presentation until onDismiss")
        model.sheetDidDismiss()

        model.beginNativePanel()
        XCTAssertFalse(model.canStop(fixture.bottle))
        model.stop(fixture.bottle)
        model.endNativePanel()

        model.requestDeletion(fixture.bottle)
        XCTAssertFalse(model.canStop(fixture.bottle))
        model.stop(fixture.bottle)
        model.dismissDeletionConfirmation()
        for _ in 0..<12 { await Task.yield() }

        XCTAssertEqual(kill(run.pid, 0), 0)
        XCTAssertEqual(try logs(fixture), before)
        XCTAssertNil(model.activity)
        XCTAssertTrue(model.canStop(fixture.bottle))
    }

    func testConfirmedStopReturnsControlToIdleAndRepeatedStopIsNoOp() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let model = fixture.model
        let run = try startLauncher(fixture)
        let prefix = try prefix(fixture)
        try await eventually { FileManager.default.fileExists(atPath: prefix.appendingPathComponent("launcher-ready").path) }
        XCTAssertTrue(model.canStop(fixture.bottle))

        model.stop(fixture.bottle)
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.canStop(fixture.bottle))
        try await eventually { !model.busy }

        XCTAssertNotEqual(kill(run.pid, 0), 0)
        XCTAssertFalse(model.isRunning(fixture.bottle))
        XCTAssertFalse(model.canStop(fixture.bottle))
        XCTAssertNil(model.error)
        let completed = try XCTUnwrap(model.processes).completed
        XCTAssertTrue(completed.contains { $0.kind == "Stop bottle" && $0.succeeded })
        let stopped = try XCTUnwrap(completed.first { $0.id == run.id })
        XCTAssertTrue(stopped.wasStopped)
        XCTAssertFalse(stopped.succeeded, "Stopping an app does not mean its work completed successfully")
        XCTAssertFalse(stopped.failed)
        XCTAssertEqual(stopped.terminationSignal, SIGTERM)
        XCTAssertFalse(stopped.summary.contains("Windows dependencies"))
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("server-commands.txt"), encoding: .utf8), "-k\n-w\n")
        let before = try logs(fixture)

        model.stop(fixture.bottle)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(try logs(fixture), before)
        XCTAssertEqual(try XCTUnwrap(model.processes).completed.map(\.id), completed.map(\.id))
        XCTAssertNil(model.activity)
    }

    func testNormalExit15StillShowsALaunchFailure() async throws {
        let fixture = try fixture(wine: "exit 15")
        defer { cleanup(fixture) }
        let run = try startLauncher(fixture)
        let result = await fixture.model.processes?.waitForExit(id: run.id)
        XCTAssertEqual(result?.exitCode, 15)
        XCTAssertNil(result?.terminationSignal)
        XCTAssertEqual(result?.wasStopped, false)
        XCTAssertEqual(result?.failed, true)
        XCTAssertTrue(fixture.model.error?.contains("code 15") == true)
    }

    func testUnrequestedSignal15StillShowsALaunchFailure() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let run = try startLauncher(fixture)
        let prefix = try prefix(fixture)
        try await eventually { FileManager.default.fileExists(atPath: prefix.appendingPathComponent("launcher-ready").path) }
        XCTAssertEqual(kill(run.pid, SIGTERM), 0)
        let result = await fixture.model.processes?.waitForExit(id: run.id)
        XCTAssertEqual(result?.terminationSignal, SIGTERM)
        XCTAssertEqual(result?.wasStopped, false)
        XCTAssertEqual(result?.failed, true)
        XCTAssertTrue(fixture.model.error?.lowercased().contains("signal 15") == true)
    }
}
