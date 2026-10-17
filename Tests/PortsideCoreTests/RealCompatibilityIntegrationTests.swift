import XCTest
import CryptoKit
@testable import PortsideCore

/// Explicit opt-in only. Uses disposable prefixes, actual trusted helpers and
/// prebuilt pinned data; it never opens a publisher app or downloads a component.
final class RealCompatibilityIntegrationTests: XCTestCase {
    @MainActor func testPinnedSetupPersistsAndRepeatedSetupPreservesOriginalsAndOtherBottle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let winePath = environment["PORTSIDE_TEST_WINE"], !winePath.isEmpty,
              let resourcesPath = environment["PORTSIDE_TEST_COMPATIBILITY_RESOURCES"], !resourcesPath.isEmpty else {
            throw XCTSkip("Set PORTSIDE_TEST_WINE and PORTSIDE_TEST_COMPATIBILITY_RESOURCES for disposable real-Wine compatibility verification.")
        }
        let root = try temporaryDirectory("Portside Real Compatibility 空間")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let runtime = try await RuntimeManager.validate(wineURL: URL(fileURLWithPath: winePath), source: "Disposable compatibility integration fixture")
        let created = try store.createBottle(name: "Compatibility target 中文", runtime: runtime)
        let control = try store.createBottle(name: "Untouched control", runtime: runtime)
        let prefix = try store.bottleURL(for: created)
        let controlPrefix = try store.bottleURL(for: control)
        let sentinel = controlPrefix.appendingPathComponent("preserve-this.txt")
        let sentinelData = Data("Compatibility setup must preserve this other bottle. 空間".utf8)
        try sentinelData.write(to: sentinel)
        let controlMarker = try Data(contentsOf: controlPrefix.appendingPathComponent(".portside-bottle.json"))
        let setup = CompatibilitySetup(resourcesURL: URL(fileURLWithPath: resourcesPath, isDirectory: true))
        let profile = try XCTUnwrap(setup.loadProfiles().first { $0.id == "r2beat-downloader" })
        XCTAssertEqual(Set(profile.components), Set([.dxvk, .cjk]))
        XCTAssertEqual(profile.executableSize, 664_472)
        let manager = WineProcessManager(logsURL: store.logsURL)
        defer { manager.shutdownStatusWatchers() }

        do {
            _ = try await manager.initialize(bottle: created, bottleURL: prefix)
            try store.markBottleInitialized(id: created.id)
            _ = try await manager.stopBottle(bottle: created, bottleURL: prefix)
            var bottle = try store.requireBottle(id: created.id)
            let controlBefore = try store.requireBottle(id: control.id)
            let missing = try await setup.bottleStatus(profile: profile, bottle: bottle, libraryRootURL: store.rootURL)
            XCTAssertFalse(missing.isConfigured)
            XCTAssertEqual(Set(missing.missingComponents), Set([.dxvk, .cjk]))
            let originalDLLs = try hashes(in: prefix, relativePaths: [
                "drive_c/windows/syswow64/d3d10core.dll", "drive_c/windows/syswow64/d3d11.dll",
                "drive_c/windows/system32/d3d10core.dll", "drive_c/windows/system32/d3d11.dll"
            ])

            let first = try await setup.install(profile: profile, bottle: bottle, libraryRootURL: store.rootURL)
            XCTAssertEqual(first.bottleID, bottle.id)
            XCTAssertEqual(first.installedComponents, profile.components)
            let installed = try await setup.bottleStatus(profile: profile, bottle: bottle, libraryRootURL: store.rootURL)
            XCTAssertTrue(installed.missingComponents.isEmpty, "Actual DLL/font hashes and persisted Wine registry values must match the receipts")
            XCTAssertFalse(installed.settingsMatch, "Component installation alone does not apply the profile's locale")

            bottle.settings = BottleSettings(windowsVersion: profile.windowsVersion, debugLogging: false, locale: profile.locale)
            _ = try await manager.applySettings(bottle: bottle, bottleURL: prefix)
            try store.updateSettings(bottleID: bottle.id, settings: bottle.settings)
            try await waitForIdle(runtime: runtime, prefix: prefix)
            bottle = try store.requireBottle(id: bottle.id)
            let configured = try await setup.bottleStatus(profile: profile, bottle: bottle, libraryRootURL: store.rootURL)
            XCTAssertTrue(configured.isConfigured)
            XCTAssertTrue(configured.settingsMatch)
            XCTAssertEqual(bottle.settings.locale, .simplifiedChinese)

            let backups = prefix.appendingPathComponent(".portside-components/dxvk-macos/originals")
            let backupPaths = ["x32-d3d10core.dll", "x32-d3d11.dll", "x64-d3d10core.dll", "x64-d3d11.dll"]
            let firstBackups = try hashes(in: backups, relativePaths: backupPaths)
            for (name, original) in originalDLLs {
                let arch = name.contains("syswow64") ? "x32" : "x64"
                XCTAssertEqual(firstBackups[arch + "-" + URL(fileURLWithPath: name).lastPathComponent], original)
            }
            let receiptURL = prefix.appendingPathComponent(".portside-components/dxvk-macos/state.json")
            let firstReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? NSDictionary
            let second = try await setup.install(profile: profile, bottle: bottle, libraryRootURL: store.rootURL)
            XCTAssertEqual(second.installedComponents, profile.components)
            XCTAssertEqual(try hashes(in: backups, relativePaths: backupPaths), firstBackups)
            let secondReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? NSDictionary
            XCTAssertEqual(firstReceipt, secondReceipt, "Idempotent graphics setup must retain its original backup/override snapshot")

            let reopened = try LibraryStore(rootURL: store.rootURL)
            let persisted = try reopened.requireBottle(id: bottle.id)
            let persistedStatus = try await setup.bottleStatus(profile: profile, bottle: persisted, libraryRootURL: reopened.rootURL)
            XCTAssertTrue(persistedStatus.isConfigured, "A new store must recognize the installed components and saved profile settings")
            XCTAssertEqual(try reopened.requireBottle(id: control.id), controlBefore)
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
            XCTAssertEqual(try Data(contentsOf: controlPrefix.appendingPathComponent(".portside-bottle.json")), controlMarker)
            XCTAssertFalse(FileManager.default.fileExists(atPath: controlPrefix.appendingPathComponent(".portside-components").path))
            _ = try await manager.stopBottle(bottle: persisted, bottleURL: prefix)
            try copyEvidence(store: store, prefix: prefix, artifactRoot: environment["PORTSIDE_INTEGRATION_ARTIFACTS"])
            print("Real compatibility: pinned graphics/font helpers, persisted registry/settings, repeated setup and control bottle isolation passed with \(runtime.version).")
        } catch {
            _ = try? await manager.stopBottle(bottle: created, bottleURL: prefix)
            try? copyEvidence(store: store, prefix: prefix, artifactRoot: environment["PORTSIDE_INTEGRATION_ARTIFACTS"])
            throw error
        }
    }

    private func hashes(in root: URL, relativePaths: [String]) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: relativePaths.map { path in
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            return (path, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        })
    }

    private func waitForIdle(runtime: WineRuntime, prefix: URL) async throws {
        let result = try await CommandExecutor.execute(executableURL: runtime.wineServerURL, arguments: ["-w"],
            environment: RuntimeManager.environment(runtime: runtime, bottleURL: prefix), timeout: 15)
        guard result.exitCode == 0, !result.timedOut else {
            throw PortsideError.commandFailed("Disposable compatibility fixture did not become idle: \(result.output)")
        }
    }

    @MainActor private func copyEvidence(store: LibraryStore, prefix: URL, artifactRoot: String?) throws {
        guard let artifactRoot else { return }
        let files = FileManager.default
        let output = URL(fileURLWithPath: artifactRoot).appendingPathComponent("compatibility/\(UUID().uuidString)")
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        try files.copyItem(at: store.rootURL.appendingPathComponent("library.json"), to: output.appendingPathComponent("library.json"))
        try files.copyItem(at: store.logsURL, to: output.appendingPathComponent("Logs"))
        let components = prefix.appendingPathComponent(".portside-components")
        if files.fileExists(atPath: components.path) {
            for component in ["dxvk-macos", "noto-cjk-sc"] {
                let target = output.appendingPathComponent(component)
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                for name in ["state.json", "operations.log"] {
                    let source = components.appendingPathComponent(component).appendingPathComponent(name)
                    if files.fileExists(atPath: source.path) { try files.copyItem(at: source, to: target.appendingPathComponent(name)) }
                }
            }
        }
    }
}
