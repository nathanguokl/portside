import XCTest
import Darwin
import PortsideCore
@testable import Portside

@MainActor final class CompatibilitySetupFlowTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let target: Bottle
        let other: Bottle
        let executable: URL
    }

    private let profile = CompatibilityProfile(id: "r2beat-downloader", title: "Downloader setup", summary: "Fixture",
        components: [.dxvk, .cjk], windowsVersion: .win10, locale: .simplifiedChinese)

    private func fixture(settingsExit: Int = 0, appExit: Int? = nil) throws -> Fixture {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Portside compatibility UI \(UUID().uuidString) 空間")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? files.removeItem(at: root) }
        let bin = root.appendingPathComponent("Runtime/bin")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let appBody = appExit.map { "exit \($0)" } ?? "exec /bin/sleep 30"
        for (name, body) in [
            "wine": "if [ \"$1\" = 'winecfg' ]; then printf '%s\\n' \"$@\" > \"$WINEPREFIX/settings-command.txt\"; exit \(settingsExit); fi\n\(appBody)",
            "wineboot": "exit 0", "wineserver": "exit 0"
        ] {
            let command = bin.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: command)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        }
        let runtime = WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "compatibility-ui-fixture", source: "Isolated test")
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false)
        let store = try XCTUnwrap(model.store)
        func bottle(_ name: String) throws -> Bottle {
            let b = try store.createBottle(name: name, runtime: runtime)
            try store.updateSettings(bottleID: b.id, settings: BottleSettings(windowsVersion: .win7, debugLogging: true, locale: .english))
            try store.markBottleInitialized(id: b.id)
            return try store.requireBottle(id: b.id)
        }
        let target = try bottle("Target"), other = try bottle("Preserve")
        model.sync(); model.selected = target.id
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = 0x64; bytes[69] = 0x86
        bytes[84] = 240; bytes[86] = 2; bytes[88] = 0x0b; bytes[89] = 2
        let executable = root.appendingPathComponent("Unknown fixture 中文.exe")
        try Data(bytes).write(to: executable)
        return Fixture(root: root, model: model, target: target, other: other, executable: executable)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.model.processes?.onCompletion = nil
        fixture.model.processes?.shutdownStatusWatchers()
        for process in fixture.model.processes?.running ?? [] { kill(process.pid, SIGKILL) }
    }

    private func result(_ fixture: Fixture) throws -> CompatibilitySetupResult {
        let log = fixture.root.appendingPathComponent("setup.log")
        try Data("Fixture component setup complete".utf8).write(to: log)
        return CompatibilitySetupResult(bottleID: fixture.target.id, installedComponents: profile.components, logURL: log)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testSetupKeepsCapturedBottleAndHoldsFinderFilesUntilDialogCloses() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let model = fixture.model, store = try XCTUnwrap(model.store)
        model.sheet = .settings
        var pending: CheckedContinuation<CompatibilitySetupResult, Error>?
        let operation = Task {
            try await model.applyCompatibilitySetup(profile: profile, bottleID: fixture.target.id, packURL: nil) { target, root in
                XCTAssertEqual(target.id, fixture.target.id)
                XCTAssertEqual(root, store.rootURL)
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
        }
        try await eventually { pending != nil }
        XCTAssertTrue(model.busy)
        model.selected = fixture.other.id
        model.openFiles([fixture.executable])
        for _ in 0..<12 { await Task.yield() }
        XCTAssertNil(model.externalOpen)
        XCTAssertEqual(model.queuedOpenURLs.count, 1)
        try XCTUnwrap(pending).resume(returning: result(fixture))
        _ = try await operation.value

        XCTAssertFalse(model.busy)
        XCTAssertEqual(try store.requireBottle(id: fixture.target.id).settings, BottleSettings(windowsVersion: .win10, locale: .simplifiedChinese))
        XCTAssertEqual(try store.requireBottle(id: fixture.other.id), fixture.other)
        let targetURL = try store.bottleURL(for: fixture.target), otherURL = try store.bottleURL(for: fixture.other)
        XCTAssertEqual(try String(contentsOf: targetURL.appendingPathComponent("settings-command.txt"), encoding: .utf8), "winecfg\n-v\nwin10\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherURL.appendingPathComponent("settings-command.txt").path))
        XCTAssertNil(model.externalOpen, "The settings sheet still owns presentation")
        model.sheet = nil; model.sheetDidDismiss()
        try await eventually { model.externalOpen != nil }
        XCTAssertTrue(model.queuedOpenURLs.isEmpty)
    }

    func testRunningBottleRejectsSetupBeforeInvokingInstaller() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let model = fixture.model, store = try XCTUnwrap(model.store)
        _ = try XCTUnwrap(model.processes).run(bottle: fixture.target, bottleURL: store.bottleURL(for: fixture.target), executableURL: fixture.executable)
        var called = false
        do {
            _ = try await model.applyCompatibilitySetup(profile: profile, bottleID: fixture.target.id, packURL: nil) { _, _ in
                called = true; return try self.result(fixture)
            }
            XCTFail("A running bottle must not be modified")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Stop this bottle")) }
        XCTAssertFalse(called)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(try store.requireBottle(id: fixture.target.id), fixture.target)
    }

    func testBusySetupDoesNotReplaceActivityOrInvokeInstaller() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        fixture.model.activity = "An existing operation"
        var called = false
        do {
            _ = try await fixture.model.applyCompatibilitySetup(profile: profile, bottleID: fixture.target.id, packURL: nil) { _, _ in
                called = true; return try self.result(fixture)
            }
            XCTFail("Busy setup should be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Another operation")) }
        XCTAssertFalse(called)
        XCTAssertEqual(fixture.model.activity, "An existing operation")
        fixture.model.activity = nil
    }

    func testRemovedCapturedBottleCannotRedirectSettingsToSurvivor() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let model = fixture.model, store = try XCTUnwrap(model.store)
        var pending: CheckedContinuation<CompatibilitySetupResult, Error>?
        let operation = Task {
            try await model.applyCompatibilitySetup(profile: profile, bottleID: fixture.target.id, packURL: nil) { _, _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }
        }
        try await eventually { pending != nil }
        try LibraryStore(rootURL: store.rootURL).deleteBottle(id: fixture.target.id)
        model.selected = fixture.other.id
        try XCTUnwrap(pending).resume(returning: result(fixture))
        do { _ = try await operation.value; XCTFail("The removed target must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer exists")) }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(try store.requireBottle(id: fixture.other.id), fixture.other)
        XCTAssertNil(model.compatibilitySetupBottleID)
    }

    func testSettingsFailureStaysInlineAndDoesNotSuppressLaterAppFailures() async throws {
        let fixture = try fixture(settingsExit: 7, appExit: 3)
        defer { cleanup(fixture) }
        let model = fixture.model, store = try XCTUnwrap(model.store), manager = try XCTUnwrap(model.processes)
        do {
            _ = try await model.applyCompatibilitySetup(profile: profile, bottleID: fixture.target.id, packURL: nil) { _, _ in try self.result(fixture) }
            XCTFail("Settings failed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("code 7")) }
        XCTAssertNil(model.error, "The setup sheet owns this error")
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.compatibilitySetupBottleID)
        XCTAssertEqual(try store.requireBottle(id: fixture.target.id), fixture.target)
        let app = try manager.run(bottle: fixture.target, bottleURL: store.bottleURL(for: fixture.target), executableURL: fixture.executable)
        _ = await manager.waitForExit(id: app.id)
        XCTAssertTrue(model.error?.contains("code 3") == true, "Unrelated later app failures must still surface")
    }
}
