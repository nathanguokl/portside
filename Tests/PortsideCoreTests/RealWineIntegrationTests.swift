import XCTest
@testable import PortsideCore

/// Opt in with PORTSIDE_TEST_WINE=/absolute/path/to/bin/wine. Every Wine operation
/// uses a new temporary WINEPREFIX; the normal Application Support catalog is never opened.
final class RealWineIntegrationTests: XCTestCase {
    @MainActor func testStopIsRepeatableAndOnlyStopsTheSelectedRealWineBottle() async throws {
        guard let winePath = ProcessInfo.processInfo.environment["PORTSIDE_TEST_WINE"], !winePath.isEmpty else {
            throw XCTSkip("Set PORTSIDE_TEST_WINE to run against a real macOS Wine installation.")
        }
        let root = try temporaryDirectory("Portside Real Stop 空間")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let runtime = try await RuntimeManager.validate(wineURL: URL(fileURLWithPath: winePath), source: "Real stop integration fixture")
        let first = try store.createBottle(name: "Selected bottle", runtime: runtime)
        let second = try store.createBottle(name: "Other active bottle", runtime: runtime)
        let firstURL = try store.bottleURL(for: first), secondURL = try store.bottleURL(for: second)
        let manager = WineProcessManager(logsURL: store.logsURL)
        var failures: [ProcessResult] = []
        manager.onCompletion = { if !$0.succeeded { failures.append($0) } }

        do {
            // A never-started prefix reproduces the user's silent `wineserver -k` exit 1.
            let idle = try await manager.stopBottle(bottle: first, bottleURL: firstURL)
            XCTAssertTrue(idle.succeeded)
            XCTAssertEqual(idle.summary, "Bottle is stopped.")

            for url in [firstURL, secondURL] {
                let started = try await CommandExecutor.execute(executableURL: runtime.wineServerURL, arguments: ["-p"],
                                                               environment: RuntimeManager.environment(runtime: runtime, bottleURL: url), timeout: 10)
                XCTAssertEqual(started.exitCode, 0, started.output)
                XCTAssertFalse(started.timedOut)
            }
            await manager.refreshBottleStatuses([(first, firstURL), (second, secondURL)])
            XCTAssertTrue(manager.isBottleRunning(first.id))
            XCTAssertTrue(manager.isBottleRunning(second.id))

            let stopped = try await manager.stopBottle(bottle: first, bottleURL: firstURL)
            XCTAssertTrue(stopped.succeeded)
            XCTAssertFalse(manager.isBottleRunning(first.id))
            XCTAssertTrue(manager.isBottleRunning(second.id), "The other prefix's Wine server must remain alive")
            let again = try await manager.stopBottle(bottle: first, bottleURL: firstURL)
            XCTAssertTrue(again.succeeded)
            XCTAssertTrue(manager.isBottleRunning(second.id))
            XCTAssertTrue(failures.isEmpty, "A confirmed stop must not emit false failure notifications")

            // Deletion of an already stopped bottle also uses this stop path in the UI.
            try store.deleteBottle(id: first.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
            _ = try await manager.stopBottle(bottle: second, bottleURL: secondURL)
            XCTAssertFalse(manager.isBottleRunning(second.id))

            let logs = try FileManager.default.contentsOfDirectory(at: store.logsURL, includingPropertiesForKeys: nil)
            let contents = try logs.map { try String(contentsOf: $0, encoding: .utf8) }
            XCTAssertTrue(contents.contains { $0.contains("Request bottle stop") && $0.contains("exit code 1") })
            XCTAssertTrue(contents.contains { $0.contains("Request bottle stop") && $0.contains("exit code 0") })
            if let artifacts = ProcessInfo.processInfo.environment["PORTSIDE_INTEGRATION_ARTIFACTS"] {
                let destination = URL(fileURLWithPath: artifacts).appendingPathComponent("stop-bottle")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for log in logs { try FileManager.default.copyItem(at: log, to: destination.appendingPathComponent(log.lastPathComponent)) }
            }
            print("Real Wine: idle stop, active stop, repeated stop, and isolation of two prefixes passed with \(runtime.version)")
        } catch {
            // Clean up both servers independently, even after a failed assertion/operation.
            _ = try? await manager.stopBottle(bottle: first, bottleURL: firstURL)
            _ = try? await manager.stopBottle(bottle: second, bottleURL: secondURL)
            throw error
        }
    }

    @MainActor func testMissingRuntimeInvalidExecutableAndRealLoaderFailure() async throws {
        guard let winePath = ProcessInfo.processInfo.environment["PORTSIDE_TEST_WINE"], !winePath.isEmpty else {
            throw XCTSkip("Set PORTSIDE_TEST_WINE to run against a real macOS Wine installation.")
        }
        let fm = FileManager.default
        let root = try temporaryDirectory("Portside Real Wine 空間")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let manager = WineProcessManager(logsURL: store.logsURL)

        do {
            _ = try await RuntimeManager.validate(wineURL: root.appendingPathComponent("missing-runtime/wine"), source: "Missing integration fixture")
            XCTFail("Missing Wine must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Wine runtime unavailable")) }

        let runtime = try await RuntimeManager.validate(wineURL: URL(fileURLWithPath: winePath), source: "Explicit integration-test runtime")
        let bottle = try store.createBottle(name: "Real Wine loader failure 日本語", runtime: runtime)
        let bottleURL = try store.bottleURL(for: bottle)
        let other = try store.createBottle(name: "Deletion control bottle", runtime: runtime)
        let sentinel = try store.bottleURL(for: other).appendingPathComponent("untouched.txt")
        try Data("unrelated bottle remains".utf8).write(to: sentinel)

        do {
            _ = try await manager.initialize(bottle: bottle, bottleURL: bottleURL)
            try store.markBottleInitialized(id: bottle.id)
            let invalid = root.appendingPathComponent("invalid file.exe")
            try Data("A text document is not a Windows executable.".utf8).write(to: invalid)
            XCTAssertThrowsError(try manager.run(bottle: bottle, bottleURL: bottleURL, executableURL: invalid))

            // This intentionally has valid DOS/COFF identifiers but no executable sections
            // or useful image layout. Header checking accepts it; the real Wine loader must fail.
            let fixture = try executable(in: root, name: "corrupt x64 image 日本語.exe")
            XCTAssertEqual(try PEExecutable.validate(url: fixture), .x64)
            let launched = try manager.run(bottle: bottle, bottleURL: bottleURL,
                                            executableURL: fixture, kind: "Expected real Wine loader failure")
            let awaitedResult = await manager.waitForExit(id: launched.id)
            let result = try XCTUnwrap(awaitedResult)
            XCTAssertFalse(result.succeeded, "The real Wine loader must reject the corrupt PE image")
            XCTAssertNotEqual(result.exitCode, 0)
            let log = try String(contentsOf: result.logURL, encoding: .utf8)
            XCTAssertTrue(log.contains("exit code \(result.exitCode)"))
            XCTAssertTrue(result.summary.contains("Open its log"))
            print("Real Wine loader rejected the x64 PE fixture with exit \(result.exitCode); runtime \(runtime.version)")

            if let artifacts = ProcessInfo.processInfo.environment["PORTSIDE_INTEGRATION_ARTIFACTS"] {
                let destination = URL(fileURLWithPath: artifacts, isDirectory: true)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                let fixtureCopy = destination.appendingPathComponent("corrupt-x64.exe")
                let logCopy = destination.appendingPathComponent("real-wine-loader-failure.log")
                if fm.fileExists(atPath: fixtureCopy.path) { try fm.removeItem(at: fixtureCopy) }
                if fm.fileExists(atPath: logCopy.path) { try fm.removeItem(at: logCopy) }
                try fm.copyItem(at: fixture, to: fixtureCopy)
                try fm.copyItem(at: result.logURL, to: logCopy)
                print("Real Wine integration artifacts: \(destination.path)")
            }
            _ = try await manager.stopBottle(bottle: bottle, bottleURL: bottleURL)
            try store.deleteBottle(id: bottle.id)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unrelated bottle remains")
            XCTAssertFalse(fm.fileExists(atPath: bottleURL.path))
            XCTAssertEqual(store.state.bottles.map(\.id), [other.id])
            try store.deleteBottle(id: other.id)
        } catch {
            _ = try? await manager.stopBottle(bottle: bottle, bottleURL: bottleURL)
            throw error
        }
    }
}
