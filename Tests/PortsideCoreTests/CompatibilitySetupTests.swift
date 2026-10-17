import XCTest
import CryptoKit
@testable import PortsideCore

final class CompatibilitySetupTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let resources: URL
        let pack: URL
        let python: URL
        let store: LibraryStore
        let bottle: Bottle
        let prefix: URL
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func profiles(_ profiles: [CompatibilityProfile], resources: URL) throws {
        struct Catalog: Encodable { let schemaVersion = 1; let profiles: [CompatibilityProfile] }
        try JSONEncoder().encode(Catalog(profiles: profiles)).write(to: resources.appendingPathComponent("profiles.json"))
    }

    private var combined: CompatibilityProfile {
        CompatibilityProfile(id: "known", title: "Known app", summary: "Optional setup", components: [.dxvk, .cjk], locale: .simplifiedChinese)
    }

    @MainActor private func fixture(fontExit: Int = 0, pythonVersion: String = "3.11.8") throws -> Fixture {
        let root = try temporaryDirectory("Portside setup 日本語 $(literal)")
        let resources = root.appendingPathComponent("Trusted App Resources/Compatibility")
        let pack = root.appendingPathComponent("Selected data pack 空間;literal")
        let python = root.appendingPathComponent("Python Runtime/bin/python3")
        try write("""
        #!/bin/sh
        while [ "$1" = '-I' ] || [ "$1" = '-B' ]; do shift; done
        if [ "$1" = '--version' ]; then printf 'Python \(pythonVersion)\\n'; exit 0; fi
        exec /bin/sh "$@"
        """, to: python, executable: true)
        for (filename, stage, exit) in [("setup-bottle-dxvk.py", "DXVK", 0), ("setup-bottle-cjk.py", "CJK", fontExit)] {
            try write("""
            printf '%s\\n' "$0" >> "$3/helper-paths.txt"
            printf '%s\\n' "$@" >> "$3/arguments.txt"
            printf '\(stage)\\n' >> "$3/stages.txt"
            printf 'fixture output \(stage)\\n'
            exit \(exit)
            """, to: resources.appendingPathComponent("Scripts/" + filename))
        }
        for name in ["component.json", "x32/d3d10core.dll", "x32/d3d11.dll", "x64/d3d10core.dll", "x64/d3d11.dll"] {
            try write("fixture", to: pack.appendingPathComponent("Components/dxvk-macos/" + name))
        }
        for name in ["NotoSansCJKsc-Regular.otf", "OFL.txt"] { try write("fixture", to: pack.appendingPathComponent("Fonts/noto-cjk/" + name)) }
        try profiles([combined], resources: resources)
        let bin = root.appendingPathComponent("Wine fixture/bin")
        for name in ["wine", "wineboot", "wineserver"] {
            let body = name == "wineserver" ? "printf 'WAIT %s\\n' \"$1\" >> \"$WINEPREFIX/../../stages.txt\"\nexit 0" : "exit 0"
            try write("#!/bin/sh\n" + body, to: bin.appendingPathComponent(name), executable: true)
        }
        let runtime = WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "wine-fixture", source: "Isolated test")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support 資料 with spaces"))
        let initial = try store.createBottle(name: "Captured bottle", runtime: runtime)
        try store.markBottleInitialized(id: initial.id)
        let bottle = try store.requireBottle(id: initial.id)
        return Fixture(root: root, resources: resources, pack: pack, python: python, store: store,
                       bottle: bottle, prefix: try store.bottleURL(for: bottle))
    }

    private func setup(_ f: Fixture, hashes: [CompatibilityComponent: [String: String]]? = nil) -> CompatibilitySetup {
        CompatibilitySetup(resourcesURL: f.resources, pythonCandidates: [f.python], installedHashes: hashes)
    }

    @MainActor func testTrustedHelpersReceiveLiteralCapturedArgumentsAndPassiveWaits() async throws {
        let f = try fixture()
        try write("exit 99", to: f.pack.appendingPathComponent("Scripts/setup-bottle-dxvk.py"))
        let setup = setup(f)
        let plan = try await setup.prepare(profile: combined, packURL: f.pack)
        XCTAssertEqual(plan.pythonURL, f.python)
        XCTAssertEqual(plan.dataDirectories[.cjk], f.pack.appendingPathComponent("Fonts/noto-cjk", isDirectory: true))
        let result = try await setup.install(profile: combined, bottle: f.bottle, libraryRootURL: f.store.rootURL, packURL: f.pack)
        XCTAssertEqual(result.bottleID, f.bottle.id)
        XCTAssertEqual(result.installedComponents, [.dxvk, .cjk])
        XCTAssertEqual(result.logURL.deletingLastPathComponent(), f.store.logsURL)
        let args = try String(contentsOf: f.store.rootURL.appendingPathComponent("arguments.txt"), encoding: .utf8)
        let expected = [f.bottle.id.uuidString, "--home", f.store.rootURL.path, "--component-dir", f.pack.appendingPathComponent("Components/dxvk-macos").path,
                        f.bottle.id.uuidString, "--home", f.store.rootURL.path, "--font-dir", f.pack.appendingPathComponent("Fonts/noto-cjk").path]
        XCTAssertEqual(args, expected.joined(separator: "\n") + "\n")
        let paths = try String(contentsOf: f.store.rootURL.appendingPathComponent("helper-paths.txt"), encoding: .utf8)
        XCTAssertTrue(paths.contains(f.resources.path))
        XCTAssertFalse(paths.contains(f.pack.path), "Selected pack scripts must never execute")
        XCTAssertEqual(try String(contentsOf: f.store.rootURL.appendingPathComponent("stages.txt"), encoding: .utf8), "DXVK\nWAIT -w\nCJK\nWAIT -w\n")
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("fixture output DXVK")); XCTAssertTrue(log.contains("fixture output CJK"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("literal").path))
    }

    @MainActor func testPartialFontFailurePreservesAndReportsCompletedGraphics() async throws {
        let f = try fixture(fontExit: 7)
        do {
            _ = try await setup(f).install(profile: combined, bottle: f.bottle, libraryRootURL: f.store.rootURL, packURL: f.pack)
            XCTFail("Font failure must not become a successful profile setup")
        } catch let error as CompatibilitySetupFailure {
            XCTAssertEqual(error.installedComponents, [.dxvk])
            XCTAssertTrue(error.localizedDescription.contains("not rolled back"))
            XCTAssertTrue(error.localizedDescription.contains("exit 7"))
            let log = try String(contentsOf: XCTUnwrap(error.logURL), encoding: .utf8)
            XCTAssertTrue(log.contains("Earlier completed components: dxvk-macos"))
        }
        XCTAssertEqual(try String(contentsOf: f.store.rootURL.appendingPathComponent("stages.txt"), encoding: .utf8), "DXVK\nWAIT -w\nCJK\n")
    }

    @MainActor func testMissingAndOldPythonOfferActionableInstructionsWithoutExecutingHelpers() async throws {
        let f = try fixture(pythonVersion: "3.8.20")
        for candidates in [[], [f.python]] {
            let setup = CompatibilitySetup(resourcesURL: f.resources, pythonCandidates: candidates)
            do { _ = try await setup.prepare(profile: combined, packURL: f.pack); XCTFail("Unsupported Python must be rejected") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains("Python 3.9"))
                XCTAssertTrue(error.localizedDescription.contains("https://www.python.org/downloads/macos/"))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.rootURL.appendingPathComponent("stages.txt").path))
    }

    @MainActor func testSystemPythonIsSkippedWhenDeveloperToolsCheckFails() async throws {
        let f = try fixture()
        let check = f.root.appendingPathComponent("No developer tools/xcode-select")
        try write("#!/bin/sh\nexit 1", to: check, executable: true)
        let setup = CompatibilitySetup(resourcesURL: f.resources, pythonCandidates: [URL(fileURLWithPath: "/usr/bin/python3")], developerCheckURL: check)
        do { _ = try await setup.prepare(profile: combined, packURL: f.pack); XCTFail("Do not invoke system Python's developer-tools popup") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Python 3.9")) }
    }

    @MainActor func testInvalidOwnershipOrStaleRuntimeIsRejectedBeforeAnyHelper() async throws {
        let f = try fixture()
        var stale = f.bottle; stale.runtime.version = "changed since selection"
        do { _ = try await setup(f).install(profile: combined, bottle: stale, libraryRootURL: f.store.rootURL, packURL: f.pack); XCTFail("Stale runtime must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("same existing")) }
        try write("{\"owner\":\"other.app\",\"bottleID\":\"\(f.bottle.id.uuidString)\"}", to: f.prefix.appendingPathComponent(".portside-bottle.json"))
        do { _ = try await setup(f).install(profile: combined, bottle: f.bottle, libraryRootURL: f.store.rootURL, packURL: f.pack); XCTFail("A foreign marker must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ownership")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.rootURL.appendingPathComponent("stages.txt").path))
    }

    @MainActor func testSymlinkedTrustedHelperAndUninitializedBottleAreRejected() async throws {
        let f = try fixture()
        let helper = f.resources.appendingPathComponent("Scripts/setup-bottle-dxvk.py")
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: f.python)
        do { _ = try await setup(f).prepare(profile: combined, packURL: f.pack); XCTFail("Trusted helper must be a real bundled file") }
        catch { XCTAssertTrue(error.localizedDescription.contains("regular file")) }
        try f.store.markBottleInitialized(id: f.bottle.id, error: "Fixture initialization failed")
        do { _ = try await setup(f).install(profile: combined, bottle: f.bottle, libraryRootURL: f.store.rootURL, packURL: f.pack); XCTFail("Incomplete bottle must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("initialized")) }
    }

    @MainActor func testFingerprintMatchesBytesWithAnyFilenameAndNeverFilenameAlone() async throws {
        let f = try fixture()
        let executable = try executable(in: f.root, name: "Completely different name.exe")
        let data = try Data(contentsOf: executable)
        let profile = CompatibilityProfile(id: "fingerprint", title: "Publisher app", summary: "Known bytes", components: [.dxvk],
                                           executableSHA256: [hash(data)], executableSize: UInt64(data.count))
        try profiles([profile], resources: f.resources)
        let matched = try await setup(f).detectProfile(executableURL: executable)
        XCTAssertEqual(matched, profile)
        let renamed = f.root.appendingPathComponent("downloader.exe")
        var changed = data; changed[511] = 1; try changed.write(to: renamed)
        let wrongBytes = try await setup(f).detectProfile(executableURL: renamed)
        XCTAssertNil(wrongBytes, "A matching filename is insufficient")
        try profiles([profile, CompatibilityProfile(id: "duplicate", title: "Another profile", summary: "Same bytes", components: [.cjk], executableSHA256: [hash(data)])], resources: f.resources)
        let ambiguous = try await setup(f).detectProfile(executableURL: executable)
        XCTAssertNil(ambiguous, "An ambiguous fingerprint must not choose an arbitrary profile")
    }

    @MainActor func testGenericDetectionWorksWithoutMetadataAndOversizedFilesAreBounded() async throws {
        let f = try fixture()
        let executable = try executable(in: f.root, name: "large.exe")
        try profiles([CompatibilityProfile(id: "bounded", title: "Bounded", summary: "Known hash", components: [.dxvk], executableSHA256: [String(repeating: "0", count: 64)])], resources: f.resources)
        let writer = try FileHandle(forWritingTo: executable)
        try writer.truncate(atOffset: 33 * 1024 * 1024); try writer.close()
        let oversized = try await setup(f).detectProfile(executableURL: executable)
        XCTAssertNil(oversized)
        try FileManager.default.removeItem(at: f.resources.appendingPathComponent("profiles.json"))
        let noMetadata = try await setup(f).detectProfile(executableURL: executable)
        XCTAssertNil(noMetadata, "A raw source build must retain generic launching")
        XCTAssertThrowsError(try setup(f).loadProfiles(), "Manual setup still explains missing metadata")
    }

    private func registry(section: String, values: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        var text = "[" + section.replacingOccurrences(of: "\\", with: "\\\\") + "] 123\n"
        for key in values.keys.sorted() {
            text += String(decoding: try encoder.encode(key), as: UTF8.self) + "=" + String(decoding: try encoder.encode(values[key]!), as: UTF8.self) + "\n"
        }
        return text
    }

    @MainActor func testReadinessNeedsPinnedReceiptActualPayloadRegistryAndSavedSettings() async throws {
        let f = try fixture()
        let profile = CompatibilityProfile(id: "fonts", title: "Chinese fonts", summary: "Optional", components: [.cjk], locale: .simplifiedChinese)
        let fontPath = "drive_c/windows/Fonts/NotoSansCJKsc-Regular.otf", licensePath = ".portside-components/noto-cjk-sc/OFL.txt"
        let fixtureBytes = Data("pinned test payload".utf8)
        let setup = setup(f, hashes: [.cjk: [fontPath: hash(fixtureBytes), licensePath: hash(fixtureBytes)]])
        var status = try await setup.bottleStatus(profile: profile, bottle: f.bottle, libraryRootURL: f.store.rootURL)
        XCTAssertFalse(status.isConfigured); XCTAssertEqual(status.missingComponents, [.cjk])
        try write(String(decoding: fixtureBytes, as: UTF8.self), to: f.prefix.appendingPathComponent(fontPath))
        try write(String(decoding: fixtureBytes, as: UTF8.self), to: f.prefix.appendingPathComponent(licensePath))
        let receipt: [String: Any] = ["schemaVersion": 1, "owner": "app.portside.mac", "bottleID": f.bottle.id.uuidString,
            "componentID": "noto-cjk-sc", "version": "2.004", "upstreamCommit": "f8d157532fbfaeda587e826d4cd5b21a49186f7c", "status": "installed"]
        try JSONSerialization.data(withJSONObject: receipt).write(to: f.prefix.appendingPathComponent(".portside-components/noto-cjk-sc/state.json"))
        try write(registry(section: "Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", values: ["Noto Sans CJK SC (OpenType)": "C:\\windows\\Fonts\\NotoSansCJKsc-Regular.otf"]), to: f.prefix.appendingPathComponent("system.reg"))
        try write(registry(section: "Software\\Wine\\Fonts\\Replacements", values: ["Noto Sans CJK JP": "Noto Sans CJK SC"]), to: f.prefix.appendingPathComponent("user.reg"))
        status = try await setup.bottleStatus(profile: profile, bottle: f.bottle, libraryRootURL: f.store.rootURL)
        XCTAssertTrue(status.missingComponents.isEmpty); XCTAssertFalse(status.settingsMatch)
        try f.store.updateSettings(bottleID: f.bottle.id, settings: BottleSettings(windowsVersion: .win10, locale: .simplifiedChinese))
        status = try await setup.bottleStatus(profile: profile, bottle: f.bottle, libraryRootURL: f.store.rootURL)
        XCTAssertTrue(status.isConfigured, "Status must decode real LibraryStore ISO8601 dates and read current settings")
        try write("modified file", to: f.prefix.appendingPathComponent(fontPath))
        status = try await setup.bottleStatus(profile: profile, bottle: f.bottle, libraryRootURL: f.store.rootURL)
        XCTAssertEqual(status.missingComponents, [.cjk], "A receipt alone cannot hide changed payloads")
        try write(String(decoding: fixtureBytes, as: UTF8.self), to: f.prefix.appendingPathComponent(fontPath))
        try write(registry(section: "Software\\Wine\\Fonts\\Replacements", values: [:]), to: f.prefix.appendingPathComponent("user.reg"))
        status = try await setup.bottleStatus(profile: profile, bottle: f.bottle, libraryRootURL: f.store.rootURL)
        XCTAssertEqual(status.missingComponents, [.cjk], "A removed font alias requires attention")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.rootURL.appendingPathComponent("stages.txt").path), "Readiness never invokes Python or Wine")
    }
}
