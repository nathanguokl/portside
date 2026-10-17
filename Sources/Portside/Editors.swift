import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PortsideCore

struct AppEditor: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    let app: WindowsApp?
    @State private var name = ""
    @State private var path = ""
    @State private var directory = ""
    @State private var argumentLines = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(app == nil ? "Register an Application" : "Edit Application").font(.title2.bold())
            Text("Choose the installed executable inside your bottle’s drive_c folder.").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                HStack { TextField("Executable", text: $path); Button("Browse…") {
                    let start = m.bottle.flatMap { try? m.store?.bottleURL(for: $0).appendingPathComponent("drive_c") }
                    if let u = m.pickFile(directory: start) { path = u.path; if directory.isEmpty { directory = u.deletingLastPathComponent().path }; if name.isEmpty { name = u.deletingPathExtension().lastPathComponent } }
                } }
                HStack { TextField("Working directory", text: $directory); Button("Choose…") { if let u = m.pickFile(folders: true) { directory = u.path } } }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Launch arguments — one argument per line")
                    TextEditor(text: $argumentLines).font(.system(.body, design: .monospaced)).frame(height: 90).border(.quaternary)
                    Text("Spaces stay within each argument. Do not add shell quotes.").font(.caption).foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save Application") { save() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || path.isEmpty || directory.isEmpty) }
        }.padding(26).frame(width: 620)
        .onAppear { if let app { name = app.name; path = app.executablePath; directory = app.workingDirectory; argumentLines = app.arguments.joined(separator: "\n") } }
    }
    private func save() {
        guard let store = m.store else { error = "The Portside library is unavailable."; return }
        guard let b = m.bottle else { error = "This bottle was removed. Close this editor and select an existing bottle."; return }
        do {
            let args = argumentLines.isEmpty ? [] : argumentLines.components(separatedBy: "\n")
            if var updated = app {
                updated.name = name; updated.executablePath = path; updated.workingDirectory = directory; updated.arguments = args
                try store.updateApp(updated)
            } else { try store.registerApp(name: name, executableURL: URL(fileURLWithPath: path), bottleID: b.id, workingDirectory: URL(fileURLWithPath: directory), arguments: args) }
            m.sync(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct RuntimeSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var path = ""
    @State private var source = ""
    @State private var candidates = [URL]()
    @State private var validating = false
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Wine Runtime", systemImage: "cpu").font(.title2.bold())
            Text("Portside uses your external Wine installation. A paid CrossOver installation is not required.").foregroundStyle(.secondary)
            if !candidates.isEmpty {
                Text("Detected runtimes").font(.headline)
                ForEach(candidates, id: \.path) { url in Button { path = url.path; source = url.path.contains("Wine Stable.app") ? "Gcenx macOS Wine Builds · external installation" : "User-selected external Wine" } label: { Text(url.path).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.bordered) }
            }
            HStack { TextField("Path to wine or Wine .app", text: $path).textFieldStyle(.roundedBorder); Button("Browse…") {
                let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
                if m.withNativePanel({ panel.runModal() }) == .OK, let u = panel.url { path = u.path }
            } }
            TextField("Runtime source / provenance", text: $source).textFieldStyle(.roundedBorder)
            Text("Existing bottles keep the runtime selected at creation. Restore that runtime at its original path if it is moved.").font(.caption).foregroundStyle(.secondary)
            FinderIntegrationView()
            GroupBox("Setup") { VStack(alignment: .leading, spacing: 10) {
                Text("Run scripts/setup-runtime.sh from the source folder to fetch the pinned, checksum-verified Wine 11.0 package. Apple Silicon requires Rosetta 2.")
                Link("Wine builds and manual setup", destination: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1")!)
                Text("Multimedia apps may also need the publisher’s GStreamer framework. Check process logs for missing libraries. Homebrew’s Wine cask is currently disabled.").font(.caption).foregroundStyle(.secondary)
                Link("GStreamer for macOS", destination: URL(string: "https://gstreamer.freedesktop.org/download/#macos")!)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            if let status { Text(status).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if validating { ProgressView().controlSize(.small) }; Button("Validate & Use") { validate() }.buttonStyle(.borderedProminent).disabled(path.isEmpty || source.isEmpty || validating) }
        }.padding(26).frame(width: 670)
        .onAppear { candidates = RuntimeManager.discoverCandidates(); path = m.state.runtime?.wineURL.path ?? candidates.first?.path ?? ""; source = m.state.runtime?.source ?? "Gcenx macOS Wine Builds · external installation" }
    }
    func validate() {
        validating = true; status = nil
        Task {
            defer { validating = false }
            do {
                let r = try await m.useRuntime(at: URL(fileURLWithPath: path), source: source)
                status = "Validated \(r.version). New bottles will use this runtime."
            } catch is CancellationError {
                // A newer selection owns the runtime status now.
            } catch { status = error.localizedDescription }
        }
    }
}

private struct SettingsProfile: Decodable {
    let name: String
    let windowsVersion: WindowsVersion
    let debugLogging: Bool
    let notes: String?
}

struct BottleSettingsSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var windows = WindowsVersion.win10
    @State private var debug = false
    @State private var locale: WineLocale?
    @State private var profileNote: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Bottle Settings").font(.title2.bold())
            Picker("Windows version", selection: $windows) { ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) } }
            Picker("Language", selection: $locale) {
                Text("System default").tag(WineLocale?.none)
                ForEach(WineLocale.allCases) { Text($0.displayName).tag(Optional($0)) }
            }
            Toggle("Verbose Wine diagnostics", isOn: $debug)
            Text("Version and language settings affect future Windows processes. Stop the bottle before changing settings. Wine’s native configuration offers additional controls.").font(.callout).foregroundStyle(.secondary)
            HStack { Button("Open Wine Configuration") { if m.configuration() { dismiss() } }; Button("Import Settings Profile…") { importProfile() } }
            if let profileNote { Text(profileNote).font(.caption).textSelection(.enabled) }
            Text("Profiles are optional JSON settings presets. Install any required application dependencies using its publisher’s installer inside the same bottle.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Apply Settings") { if m.apply(BottleSettings(windowsVersion: windows, debugLogging: debug, locale: locale)) { dismiss() } }.keyboardShortcut(.defaultAction).disabled(m.busy || m.bottle.map { m.isRunning($0) } == true) }
        }.padding(26).frame(width: 530)
        .onAppear { if let b = m.bottle { windows = b.settings.windowsVersion; debug = b.settings.debugLogging; locale = b.settings.locale } }
    }
    func importProfile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        guard m.withNativePanel({ p.runModal() }) == .OK, let url = p.url else { return }
        do { let profile = try JSONDecoder().decode(SettingsProfile.self, from: Data(contentsOf: url)); windows = profile.windowsVersion; debug = profile.debugLogging; profileNote = "\(profile.name): \(profile.notes ?? "Settings loaded. Apply to save.")" }
        catch { profileNote = "Profile could not be read: \(error.localizedDescription)" }
    }
}
