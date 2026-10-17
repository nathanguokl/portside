import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PortsideCore

@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(PortsideAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        let _ = model
        Window("Portside", id: "main") {
            ContentView().environmentObject(model)
                .tint(PortsideBrand.blue)
                .frame(minWidth: 940, minHeight: 660)
        }
        .defaultSize(width: 1120, height: 760)
        .commands { CommandGroup(replacing: .newItem) {
            Button("New Bottle…") { model.sheet = .newBottle }.keyboardShortcut("n").disabled(model.busy || model.hasModalPresentation)
            Button("Open Windows App…") { model.chooseExternalExecutable() }.keyboardShortcut("o").disabled(model.busy || model.hasModalPresentation)
        }; CommandGroup(after: .appInfo) {
            Button("Make Default for Windows Apps…") { model.makeDefaultExecutableHandler() }
                .disabled(model.isDefaultExecutableHandler || model.settingDefaultExecutableHandler)
        } }
    }

}

enum EditorSheet: String, Identifiable {
    case newBottle, rename, register, runtime, settings, openExecutable
    var id: String { rawValue }
}

@MainActor final class AppModel: ObservableObject {
    typealias RuntimeValidator = @MainActor (URL, String) async throws -> WineRuntime
    typealias InstalledAppScanner = @Sendable (Bottle, URL, [WindowsApp]) throws -> [InstalledAppCandidate]
    private enum RuntimeValidationIntent {
        case manual
        case startup(expectedSelection: WineRuntime?)
    }
    let store: LibraryStore?
    let processes: WineProcessManager?
    private let runtimeValidator: RuntimeValidator
    let installedAppScanner: InstalledAppScanner
    let automaticDiscoveryEnabled: Bool
    var installedDiscoveryTask: Task<Void, Never>?
    var installedDiscoveryGeneration = 0
    var pendingInstalledDiscovery: PendingInstalledDiscovery?
    private var runtimeValidationGeneration = 0
    private var manualRuntimeSelectionStarted = false
    private var reportedRecoveryWarnings = Set<String>()
    @Published var state = LibraryState()
    @Published var selected: UUID? { didSet { if selected != oldValue { selectedBottleChangedForDiscovery() } } }
    @Published var sheet: EditorSheet? { didSet { if sheet != nil { sheetIsPresented = true } } }
    @Published var editingApp: WindowsApp?
    @Published var error: String? { didSet { if error == nil { resumeFileOpening() } } }
    @Published var activity: String? { didSet { if activity == nil { resumeFileOpening() } } }
    @Published var externalOpen: ExternalOpenRequest?
    @Published var isDefaultExecutableHandler = false
    @Published var settingDefaultExecutableHandler = false
    @Published private(set) var deletionTarget: Bottle?
    @Published private(set) var nativePanelDepth = 0
    @Published var installedAppCandidates: [InstalledAppCandidate] = []
    @Published var isDiscoveringInstalledApps = false
    @Published var installedDiscoveryMessage: String?
    var queuedOpenURLs: [URL] = []
    var fileDrainScheduled = false
    var sheetIsPresented = false
    var sheetAfterExternalOpen: EditorSheet?
    @Published var logURL: URL?
    @Published var logText = "Select a task below to view its log."
    @Published var runtimeStatus = "Checking Wine…"
    var bottle: Bottle? { state.bottles.first { $0.id == selected } }
    var busy: Bool { activity != nil }
    var hasModalPresentation: Bool { sheetIsPresented || nativePanelDepth > 0 || deletionTarget != nil }

    init(rootURL: URL? = nil, startsBackgroundWork: Bool = true,
         installedAppScanner: @escaping InstalledAppScanner = { bottle, url, apps in
             try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: url, registeredApps: apps)
         },
         runtimeValidator: @escaping RuntimeValidator = { url, source in
             try await RuntimeManager.validate(wineURL: url, source: source)
         }) {
        self.runtimeValidator = runtimeValidator
        self.installedAppScanner = installedAppScanner
        self.automaticDiscoveryEnabled = startsBackgroundWork
        do {
            let s = try LibraryStore(rootURL: rootURL); store = s
            let p = WineProcessManager(logsURL: s.logsURL); processes = p
            state = s.state; selected = s.state.bottles.first?.id
            showRecoveryWarnings(s.recoveryWarnings)
            p.onChange = { [weak self] in self?.objectWillChange.send() }
            p.onCompletion = { [weak self] result in
                guard let self else { return }
                if !result.isSessionWatcher { self.showLog(result.logURL) }
                if !result.succeeded { self.error = result.summary }
                self.discoverAfterCompletion(result)
            }
            if startsBackgroundWork {
                isDefaultExecutableHandler = FileAssociation.isDefault
                Task { await checkRuntime() }
                Task { await refreshRunning() }
                Task { requestInstalledAppDiscovery() }
            }
        } catch {
            store = nil; processes = nil; self.error = error.localizedDescription
            runtimeStatus = "Library could not be opened"
        }
        ExternalOpenInbox.shared.deliver = { [weak self] urls in self?.openFiles(urls) }
        ExternalOpenInbox.shared.onTerminate = { [weak self] in
            self?.cancelInstalledAppDiscovery()
            self?.processes?.shutdownStatusWatchers()
        }
    }

    func isRunning(_ b: Bottle) -> Bool { processes?.isBottleRunning(b.id) == true }
    func canStop(_ b: Bottle) -> Bool { !busy && !hasModalPresentation && isRunning(b) }
    func sync() {
        if let store { state = store.state }
        pruneRegisteredDiscoveryCandidates()
    }
    func refreshLibrary() {
        guard let store else { return }
        do {
            let previousRuntime = state.runtime
            try store.refresh()
            sync()
            if state.runtime != previousRuntime { showCurrentRuntimeStatus() }
            if let selected, !state.bottles.contains(where: { $0.id == selected }) {
                if hasModalPresentation {
                    if error == nil { error = "The selected bottle was removed by another Portside process. Close the current dialog and select an existing bottle." }
                } else { self.selected = state.bottles.first?.id }
            }
            showRecoveryWarnings(store.recoveryWarnings)
        } catch { self.error = error.localizedDescription }
    }
    func showRecoveryWarnings(_ warnings: [String]) {
        guard error == nil else { return }
        let unseen = warnings.filter { !reportedRecoveryWarnings.contains($0) }
        guard !unseen.isEmpty else { return }
        reportedRecoveryWarnings.formUnion(unseen)
        error = unseen.joined(separator: "\n\n")
    }
    func report(_ operation: () throws -> Void) {
        do { try operation(); sync() } catch { self.error = error.localizedDescription }
    }
    func perform(_ label: String, operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        activity = label
        Task {
            defer { activity = nil; sync() }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
    @discardableResult func useRuntime(at url: URL, source: String) async throws -> WineRuntime {
        manualRuntimeSelectionStarted = true
        do {
            return try await validateAndUseRuntime(at: url, source: source, intent: .manual)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            runtimeStatus = "Runtime selection failed"
            throw error
        }
    }
    private func showCurrentRuntimeStatus() {
        runtimeStatus = state.runtime?.version ?? "Wine setup required"
    }
    private func validateAndUseRuntime(at url: URL, source: String, intent: RuntimeValidationIntent) async throws -> WineRuntime {
        guard let store else { throw PortsideError.persistence("The Portside library is unavailable.") }
        runtimeValidationGeneration += 1
        let generation = runtimeValidationGeneration
        do {
            let runtime = try await runtimeValidator(url, source)
            guard generation == runtimeValidationGeneration else { throw CancellationError() }
            switch intent {
            case .manual:
                try store.setRuntime(runtime)
            case .startup(let expected):
                // Compare and commit under the catalog lock so an automatic
                // probe cannot overwrite a concurrent frontend or CLI choice.
                guard try store.setRuntime(runtime, ifCurrentMatches: expected) else {
                    sync(); showCurrentRuntimeStatus()
                    throw CancellationError()
                }
            }
            sync(); runtimeStatus = runtime.version
            return runtime
        } catch {
            // An old startup probe must not undo a newer choice or show a stale failure.
            guard generation == runtimeValidationGeneration else { throw CancellationError() }
            if case .startup(let expected) = intent {
                do { try store.refresh(); sync() }
                catch {
                    runtimeStatus = "Runtime check deferred"
                    throw CancellationError()
                }
                guard state.runtime == expected else {
                    showCurrentRuntimeStatus()
                    throw CancellationError()
                }
            }
            throw error
        }
    }
    func checkRuntime() async {
        guard !manualRuntimeSelectionStarted else { return }
        do {
            guard let store else { return }
            try store.refresh(); sync()
            let expectedSelection = state.runtime
            let url = state.runtime?.wineURL ?? RuntimeManager.discoverCandidates().first
            guard let url else { runtimeStatus = "Wine setup required"; return }
            _ = try await validateAndUseRuntime(at: url, source: state.runtime?.source ?? "Detected external Wine runtime",
                                               intent: .startup(expectedSelection: expectedSelection))
        } catch is CancellationError {
            // Superseded by an explicit runtime selection.
        } catch {
            runtimeStatus = "Wine unavailable"
            if self.error == nil { self.error = error.localizedDescription }
        }
    }
    func refreshRunning() async {
        guard let store, let processes else { return }
        let bottles = state.bottles.compactMap { b -> (bottle: Bottle, bottleURL: URL)? in
            guard let url = try? store.bottleURL(for: b) else { return nil }
            return (b, url)
        }
        await processes.refreshBottleStatuses(bottles)
        objectWillChange.send()
    }
    func create(_ name: String) {
        guard let store, let processes, let runtime = state.runtime else { error = "Select and validate Wine in Runtime Setup first."; return }
        perform("Creating bottle…") {
            let b = try store.createBottle(name: name, runtime: runtime)
            self.selected = b.id; self.sync()
            do {
                try await processes.initialize(bottle: b, bottleURL: store.bottleURL(for: b))
                try store.markBottleInitialized(id: b.id)
            } catch {
                try? store.markBottleInitialized(id: b.id, error: error.localizedDescription); throw error
            }
        }
    }
    func retryInitialize(_ b: Bottle) {
        guard let store, let processes else { return }
        perform("Initializing bottle…") {
            try await processes.initialize(bottle: b, bottleURL: store.bottleURL(for: b))
            try store.markBottleInitialized(id: b.id)
        }
    }
    func pickFile(directory: URL? = nil, folders: Bool = false) -> URL? {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.canChooseDirectories = folders; panel.canChooseFiles = !folders
        panel.directoryURL = directory
        panel.message = folders ? "Choose a working directory" : "Choose a Windows executable (.exe)"
        if !folders { panel.allowedContentTypes = [.exe] }
        return withNativePanel { panel.runModal() == .OK ? panel.url : nil }
    }
    func beginNativePanel() { nativePanelDepth += 1 }
    func endNativePanel() {
        precondition(nativePanelDepth > 0)
        nativePanelDepth -= 1
        if nativePanelDepth == 0 { resumeFileOpening() }
    }
    func withNativePanel<T>(_ operation: () throws -> T) rethrows -> T {
        beginNativePanel()
        defer { endNativePanel() }
        return try operation()
    }
    func install() {
        guard let b = bottle, let store, let processes,
              let exe = pickFile() else { return }
        report {
            let run = try processes.run(bottle: b, bottleURL: store.bottleURL(for: b), executableURL: exe,
                                        kind: "Install \(exe.lastPathComponent)")
            showLog(run.logURL)
        }
    }
    func launch(_ app: WindowsApp) {
        guard let store, let processes else { return }
        report {
            try store.refresh(); sync()
            guard let current = state.apps.first(where: { $0.id == app.id }) else {
                throw PortsideError.commandFailed("This application was removed from the library. Select an existing application.")
            }
            let b = try store.requireBottle(id: current.bottleID)
            guard b.initialized else { throw PortsideError.commandFailed("Initialize this bottle before opening a Windows app.") }
            selected = b.id
            let run = try processes.run(bottle: b, bottleURL: store.bottleURL(for: b), executableURL: current.executableURL,
                                        arguments: current.arguments, workingDirectory: current.workingDirectoryURL, kind: "Launch \(current.name)")
            showLog(run.logURL)
        }
    }
    func stop(_ b: Bottle) {
        guard canStop(b), let store, let processes else { return }
        perform("Stopping bottle processes…") {
            try await processes.stopBottle(bottle: b, bottleURL: store.bottleURL(for: b))
        }
    }
    func delete(_ b: Bottle) {
        guard let store, let processes else { return }
        perform("Removing bottle…") {
            try await processes.stopBottle(bottle: b, bottleURL: store.bottleURL(for: b))
            try store.deleteBottle(id: b.id)
            self.selected = store.state.bottles.first?.id
        }
    }
    func requestDeletion(_ bottle: Bottle) {
        guard !busy, !hasModalPresentation else { return }
        deletionTarget = bottle
    }
    func dismissDeletionConfirmation() {
        deletionTarget = nil
        resumeFileOpening()
    }
    func confirmDeletion(_ target: Bottle) {
        // The dialog supplies its captured target even if selection changes or
        // SwiftUI clears the presentation binding before invoking this action.
        delete(target)
        dismissDeletionConfirmation()
    }
    @discardableResult func apply(_ settings: BottleSettings) -> Bool {
        guard let store, let processes else { error = "The Portside library is unavailable."; return false }
        guard let b = bottle else { error = "This bottle is no longer available. Close Settings and select an existing bottle."; return false }
        guard !busy else { return false }
        perform("Applying bottle settings…") {
            var updated = b; updated.settings = settings
            try await processes.applySettings(bottle: updated, bottleURL: store.bottleURL(for: b))
            try store.updateSettings(bottleID: b.id, settings: settings)
        }
        return true
    }
    @discardableResult func configuration() -> Bool {
        guard let store, let processes else { error = "The Portside library is unavailable."; return false }
        guard let b = bottle else { error = "This bottle is no longer available. Close Settings and select an existing bottle."; return false }
        do {
            let p = try processes.launchConfiguration(bottle: b, bottleURL: store.bottleURL(for: b))
            showLog(p.logURL)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func showLog(_ url: URL) { logURL = url; readLog() }
    func readLog() {
        guard let url = logURL else { return }
        if let f = try? FileHandle(forReadingFrom: url) {
            defer { try? f.close() }
            let size = (try? f.seekToEnd()) ?? 0
            try? f.seek(toOffset: size > 100_000 ? size - 100_000 : 0)
            let text = String(decoding: (try? f.readToEnd()) ?? Data(), as: UTF8.self)
            if text != logText { logText = text }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    PortsideLogo(size: 44)
                    VStack(alignment: .leading) { Text("Portside").font(.title2.bold()); Text("Windows, on your Mac").font(.caption).foregroundStyle(.secondary) }
                }.padding(20)
                List(selection: $m.selected) {
                    Section("Bottles") {
                        ForEach(m.state.bottles) { b in
                            HStack {
                                Image(systemName: "shippingbox.fill").foregroundStyle(PortsideBrand.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(b.name)
                                    Text(b.initialized ? b.settings.windowsVersion.displayName : "Needs initialization").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if m.isRunning(b) { Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Running") }
                            }.padding(.vertical, 5).tag(b.id)
                        }
                    }
                }
                Button { m.sheet = .newBottle } label: { Label("New Bottle", systemImage: "plus") }.buttonStyle(.bordered).disabled(m.busy || m.hasModalPresentation).padding()
                Divider()
                Button { m.sheet = .runtime } label: {
                    HStack { Image(systemName: "cpu"); VStack(alignment: .leading) { Text("Runtime Setup"); Text(m.runtimeStatus).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption) }
                }.buttonStyle(.plain).disabled(m.busy || m.hasModalPresentation).padding(18)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 310)
        } detail: {
            VStack(spacing: 0) {
                if let activity = m.activity { HStack { ProgressView().controlSize(.small); Text(activity); Spacer() }.padding(12).background(PortsideBrand.blue.opacity(0.08)) }
                if let b = m.bottle {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(b.name).font(.largeTitle.bold())
                                    HStack { Label(b.settings.windowsVersion.displayName, systemImage: "desktopcomputer"); Text("·"); Text(b.runtimeVersion); Text("·"); Text(m.isRunning(b) ? "Processes running" : "Ready") }.font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu { Button("Rename…") { m.sheet = .rename }; Button("Show Files") { if let u = try? m.store?.bottleURL(for: b) { NSWorkspace.shared.open(u) } }; Divider(); Button("Delete Bottle…", role: .destructive) { m.requestDeletion(b) } } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title2)
                                        .frame(width: 36, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .accessibilityLabel("Bottle actions")
                                .help("Bottle actions")
                                .disabled(m.busy || m.hasModalPresentation)
                            }
                            if !b.initialized {
                                GroupBox { VStack(alignment: .leading, spacing: 10) { Text(b.initializationError ?? "This bottle has not finished initializing."); Button("Retry Initialization") { m.retryInitialize(b) } }.frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { installButton; findAppsButton; Spacer(); settingsButton }
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack { installButton; Spacer(); settingsButton }
                                    findAppsButton
                                }
                            }.disabled(m.busy || m.hasModalPresentation || !b.initialized)
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Applications").font(.title2.bold())
                                    Spacer()
                                    Button { m.editingApp = nil; m.sheet = .register } label: {
                                        Label("Add Manually…", systemImage: "plus.app")
                                    }.disabled(m.busy || m.hasModalPresentation || !b.initialized)
                                }
                                InstalledAppReviewView()
                                let apps = LibraryEntryPresentation.sorted(m.state.apps.filter { $0.bottleID == b.id })
                                if apps.isEmpty {
                                    VStack(spacing: 12) { Image(systemName: "app.dashed").font(.system(size: 36)).foregroundStyle(.secondary); Text("A place for your Windows apps").font(.headline); Text("Finish the Windows installer, then choose Find Installed Apps.\nUse Add Manually to select another installed .exe.").multilineTextAlignment(.center).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(28).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                                }
                                ForEach(apps) { app in
                                    HStack(spacing: 14) {
                                        Image(systemName: "window.ceiling").font(.title2).foregroundStyle(PortsideBrand.blue).frame(width: 44, height: 44).background(PortsideBrand.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack(spacing: 6) {
                                                Text(app.name).font(.headline).lineLimit(1).truncationMode(.tail)
                                                if LibraryEntryPresentation.isSetupTool(app) {
                                                    Text("Setup").font(.caption2).foregroundStyle(.secondary)
                                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                                        .background(.quaternary, in: Capsule())
                                                }
                                            }
                                            Text(applicationPath(app, in: b))
                                                .font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                                .help(app.executablePath)
                                            if LibraryEntryPresentation.isSetupTool(app) {
                                                Text("After installation, open the installed app’s launcher or use Find Installed Apps.")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                        Button("Launch") { m.launch(app) }
                                            .buttonStyle(.borderedProminent)
                                            .fixedSize()
                                            .disabled(m.busy)
                                        Menu {
                                            Button("Edit…") { m.editingApp = app; m.sheet = .register }
                                            Button("Remove from Library", role: .destructive) { m.report { try m.store?.deleteApp(id: app.id) } }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                                .frame(width: 36, height: 32)
                                                .contentShape(Rectangle())
                                        }
                                        .menuStyle(.borderlessButton)
                                        .menuIndicator(.hidden)
                                        .fixedSize()
                                        .accessibilityLabel("Actions for \(app.name)")
                                        .help("App actions")
                                        .disabled(m.busy || m.hasModalPresentation)
                                    }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                                }
                            }
                            diagnostics(b)
                        }.padding(28)
                    }
                } else {
                    ContentUnavailableView {
                        VStack(spacing: 16) {
                            PortsideLogo(size: 80)
                            Text("Bring a Windows app aboard").font(.title2.bold())
                        }
                    } description: { Text("A bottle holds a separate Windows environment.\nSet up Wine, create a bottle, and install your first app.") } actions: { Button("Runtime Setup") { m.sheet = .runtime }; Button("Create Bottle") { m.sheet = .newBottle }.buttonStyle(.borderedProminent) }
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: $m.sheet, onDismiss: m.sheetDidDismiss) { s in
            switch s {
            case .newBottle: NameSheet(title: "Create a Bottle", initial: "", action: m.create)
            case .rename: NameSheet(title: "Rename Bottle", initial: m.bottle?.name ?? "") { name in
                if let b = m.bottle { m.report { try m.store?.renameBottle(id: b.id, name: name) } }
                else { m.error = "This bottle was removed. Select an existing bottle before renaming it." }
            }
            case .register: AppEditor(app: m.editingApp)
            case .runtime: RuntimeSheet()
            case .settings: BottleSettingsSheet()
            case .openExecutable: if let request = m.externalOpen { ExternalExecutableSheet(request: request) }
            }
        }
        .onAppear {
            ExternalOpenInbox.shared.windowDidAppear()
            m.resumeFileOpening()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            m.refreshLibrary()
            m.isDefaultExecutableHandler = FileAssociation.isDefault
            Task { await m.refreshRunning() }
        }
        .alert("Portside needs attention", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) { Button("OK") { m.error = nil }; Button("Show Logs") { if let u = m.store?.logsURL { NSWorkspace.shared.open(u) }; m.error = nil } } message: { Text(m.error ?? "") }
        .confirmationDialog("Delete \(m.deletionTarget?.name ?? "bottle") and its installed files?", isPresented: Binding(get: { m.deletionTarget != nil }, set: { if !$0 { m.dismissDeletionConfirmation() } }), titleVisibility: .visible, presenting: m.deletionTarget) { target in
            Button("Delete Bottle", role: .destructive) { m.confirmDeletion(target) }
        } message: { target in
            Text("All processes in “\(target.name)” will stop. Only this bottle and its library entries will be removed. This cannot be undone.")
        }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); m.readLog() } }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                m.discoverWhileBottleIsRunning()
            }
        }
    }

    private var installButton: some View {
        Button { m.install() } label: { Label("Install Windows App…", systemImage: "square.and.arrow.down") }
            .buttonStyle(.borderedProminent).fixedSize()
    }
    private var findAppsButton: some View {
        Button { m.requestInstalledAppDiscovery(userInitiated: true) } label: {
            Label("Find Installed Apps", systemImage: "magnifyingglass")
        }.buttonStyle(.bordered).fixedSize().disabled(m.isDiscoveringInstalledApps)
            .help("Look inside this bottle for installed app launchers")
    }
    private var settingsButton: some View {
        Button { m.sheet = .settings } label: { Label("Settings", systemImage: "slider.horizontal.3") }
            .buttonStyle(.bordered).fixedSize()
    }

    private func applicationPath(_ app: WindowsApp, in bottle: Bottle) -> String {
        LibraryEntryPresentation.executablePath(app.executableURL, in: bottle, bottlesURL: m.store?.bottlesURL)
    }

    @ViewBuilder func diagnostics(_ b: Bottle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity & Logs").font(.title2.bold())
                Spacer()
                Button("Refresh Status") { Task { await m.refreshRunning() } }
                Button("Stop Bottle") { m.stop(b) }
                    .disabled(!m.canStop(b))
                    .help(m.isRunning(b) ? "Stop this bottle’s Windows processes." : "No running processes detected. Use Refresh Status to check again.")
            }
            let running = m.processes?.running.filter { $0.bottleID == b.id } ?? []
            ForEach(running) { p in Button { m.showLog(p.logURL) } label: { HStack { ProgressView().controlSize(.mini); Text(p.kind); Spacer(); Text("PID \(p.pid)").monospacedDigit().foregroundStyle(.secondary) } }.buttonStyle(.plain) }
            let finished = Array((m.processes?.completed.filter { $0.bottleID == b.id } ?? []).prefix(5))
            ForEach(finished) { p in Button { m.showLog(p.logURL) } label: { HStack { Image(systemName: p.succeeded ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(p.succeeded ? .green : .orange); Text(p.kind); Spacer(); Text("Exit \(p.exitCode)").foregroundStyle(.secondary) } }.buttonStyle(.plain) }
            ScrollView { Text(m.logText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(height: 150).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack { Text("Logs stay on this Mac.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Open Log Folder") { if let u = m.store?.logsURL { NSWorkspace.shared.open(u) } } }
        }
    }
}

struct NameSheet: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    @State var name: String
    let action: (String) -> Void
    init(title: String, initial: String, action: @escaping (String) -> Void) { self.title = title; _name = State(initialValue: initial); self.action = action }
    var body: some View { VStack(alignment: .leading, spacing: 20) { Text(title).font(.title2.bold()); TextField("Bottle name", text: $name).textFieldStyle(.roundedBorder); HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save") { action(name); dismiss() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(24).frame(width: 390) }
}
