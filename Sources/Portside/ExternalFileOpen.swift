import AppKit
import SwiftUI
import PortsideCore

/// Finder can deliver documents before the SwiftUI scene has been constructed.
@MainActor final class ExternalOpenInbox {
    static let shared = ExternalOpenInbox()
    private var buffered: [URL] = []
    var deliver: (([URL]) -> Void)? { didSet { flush() } }
    var onTerminate: (() -> Void)?
    var finishedLaunching = false
    private var requestingWindow = false

    func windowDidAppear() { requestingWindow = false }

    func receive(_ urls: [URL]) {
        buffered.append(contentsOf: urls)
        flush()
        _ = presentWindow()
    }

    private func flush() {
        guard let deliver, !buffered.isEmpty else { return }
        let urls = buffered
        buffered.removeAll()
        deliver(urls)
    }

    @discardableResult func presentWindow() -> Bool {
        guard finishedLaunching else { return false }
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.sheetParent == nil
        }) {
            requestingWindow = false
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // Ask SwiftUI's AppKit delegate to create the standard main scene.
            // A file-open launch suppresses the usual untitled-window request.
            guard !requestingWindow else { return true }
            requestingWindow = true
            guard NSApp.delegate?.applicationOpenUntitledFile?(NSApp) == true else {
                requestingWindow = false
                NSLog("Portside could not request its main window. Reopen Portside from Applications.")
                return false
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

struct ExternalOpenRequest {
    let url: URL
    let action: ExternalExecutable.OpenAction
}

@MainActor extension AppModel {
    func chooseExternalExecutable() {
        if let url = pickFile() { openFiles([url]) }
    }

    func makeDefaultExecutableHandler() {
        guard !settingDefaultExecutableHandler else { return }
        settingDefaultExecutableHandler = true
        Task {
            defer { settingDefaultExecutableHandler = false }
            do {
                try await FileAssociation.setDefaultApplication()
                isDefaultExecutableHandler = FileAssociation.isDefault
            } catch { self.error = error.localizedDescription }
        }
    }

    func openFiles(_ urls: [URL]) {
        let current = externalOpen?.url.standardizedFileURL.resolvingSymlinksInPath()
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical != current, !queuedOpenURLs.contains(canonical) else { continue }
            queuedOpenURLs.append(canonical)
        }
        resumeFileOpening()
    }

    func resumeFileOpening() {
        guard !fileDrainScheduled else { return }
        fileDrainScheduled = true
        Task { @MainActor in
            // Let a dismissing sheet and any catalog update finish before showing the next file.
            await Task.yield()
            fileDrainScheduled = false
            drainOpenFiles()
            startPendingInstalledDiscoveryIfPossible()
        }
    }

    private func drainOpenFiles() {
        guard !busy, !hasModalPresentation, sheet == nil, externalOpen == nil, error == nil else { return }
        while !queuedOpenURLs.isEmpty {
            let url = queuedOpenURLs[0]
            do {
                guard let store, processes != nil else {
                    throw PortsideError.persistence("The library is unavailable. Reopen Portside after resolving the catalog error.")
                }
                // Another frontend or CLI may have changed the catalog while we
                // were inactive. A failed refresh leaves this request queued.
                try store.refresh()
                sync()
                showRecoveryWarnings(store.recoveryWarnings)
                guard error == nil else { return }
                queuedOpenURLs.removeFirst()
                let directories = Dictionary(uniqueKeysWithValues: state.bottles.compactMap { bottle -> (UUID, URL)? in
                    guard let url = try? store.bottleURL(for: bottle) else { return nil }
                    return (bottle.id, url)
                })
                let action = try ExternalExecutable.resolve(url: url, state: state, bottleDirectories: directories)
                switch action {
                case .registered(let app):
                    selected = app.bottleID
                    launch(app)
                    if error != nil { return }
                case .bottle(let bottle):
                    try runExternalExecutable(url, bottleID: bottle.id, remember: false)
                case .chooseBottle, .chooseRegistration:
                    externalOpen = ExternalOpenRequest(url: url, action: action)
                    sheet = .openExecutable
                    return
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
    }

    func runExternalExecutable(_ url: URL, bottleID: UUID, remember: Bool) throws {
        guard let store, let processes else { throw PortsideError.persistence("The library is unavailable.") }
        let bottle = try store.requireBottle(id: bottleID)
        guard bottle.initialized else { throw PortsideError.commandFailed("Initialize this bottle before opening a Windows app.") }
        let directory = try store.bottleURL(for: bottle)
        try PEExecutable.validate(url: url)
        let run = try processes.run(bottle: bottle, bottleURL: directory, executableURL: url,
                                    kind: "Open \(url.lastPathComponent)")
        selected = bottleID
        showLog(run.logURL)
        if remember {
            do {
                try store.registerApp(name: url.deletingPathExtension().lastPathComponent,
                                      executableURL: url, bottleID: bottleID)
                sync()
            } catch {
                // The app is already running. Close the picker and report the save failure,
                // rather than offering a Run retry that would start another copy.
                self.error = "The app started, but its library entry could not be saved. \(error.localizedDescription)"
            }
        }
    }

    func prepareExternalBottleSetup() {
        guard let request = externalOpen else { return }
        queuedOpenURLs.insert(request.url, at: 0)
        sheetAfterExternalOpen = state.runtime == nil ? .runtime : .newBottle
    }

    func sheetDidDismiss() {
        sheetIsPresented = false
        externalOpen = nil
        refreshLibrary()
        if let next = sheetAfterExternalOpen {
            sheetAfterExternalOpen = nil
            sheet = next
        } else {
            resumeFileOpening()
        }
    }
}

struct ExternalExecutableSheet: View {
    @EnvironmentObject private var m: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: ExternalOpenRequest
    @State private var bottleID: UUID?
    @State private var registrationID: UUID?
    @State private var remember = false
    @State private var error: String?

    private var bottles: [Bottle] {
        if case .chooseBottle(let bottles) = request.action { return bottles }
        return []
    }
    private var registrations: [WindowsApp] {
        if case .chooseRegistration(let apps) = request.action { return apps }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Open Windows App", systemImage: "window.ceiling").font(.title2.bold())
            Text(request.url.lastPathComponent).font(.headline).textSelection(.enabled)
            Text(request.url.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(3).textSelection(.enabled)
            if !registrations.isEmpty {
                Text("This executable has more than one saved launch entry. Choose which settings to use.")
                    .foregroundStyle(.secondary)
                Picker("Application", selection: $registrationID) {
                    Text("Choose a saved entry").tag(UUID?.none)
                    ForEach(registrations) { app in
                        Text("\(app.name) — \(m.state.bottles.first { $0.id == app.bottleID }?.name ?? "Unavailable bottle")")
                            .tag(Optional(app.id))
                    }
                }
                if let app = registrations.first(where: { $0.id == registrationID }) {
                    Text("Working directory: \(app.workingDirectory)").font(.caption).textSelection(.enabled)
                    if !app.arguments.isEmpty {
                        Text("Arguments: \(app.arguments.joined(separator: " · "))").font(.caption).textSelection(.enabled)
                    }
                }
            } else if bottles.isEmpty {
                Text("Create and initialize a bottle before opening this app. Portside will keep this file ready while you set it up.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose the Windows environment for this app or installer.").foregroundStyle(.secondary)
                Picker("Bottle", selection: $bottleID) {
                    Text("Choose a bottle").tag(UUID?.none)
                    ForEach(bottles) { bottle in Text(bottle.name).tag(Optional(bottle.id)) }
                }
                Toggle("Add to Library for future launches", isOn: $remember)
                Text("Library apps reopen with their saved bottle, working directory, and arguments.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if registrations.isEmpty && bottles.isEmpty {
                    Button(m.state.runtime == nil ? "Set Up Wine…" : "Create Bottle…") {
                        m.prepareExternalBottleSetup()
                        dismiss()
                    }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Run") { run() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(registrations.isEmpty ? bottleID == nil : registrationID == nil)
                }
            }
        }
        .padding(26).frame(width: 570)
        .onAppear { if bottles.count == 1 { bottleID = bottles[0].id } }
    }

    private func run() {
        do {
            if let app = registrations.first(where: { $0.id == registrationID }) {
                m.selected = app.bottleID
                m.launch(app)
                if let failure = m.error { m.error = nil; throw PortsideError.commandFailed(failure) }
            } else if let bottleID {
                try m.runExternalExecutable(request.url, bottleID: bottleID, remember: remember)
            } else { return }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct FinderIntegrationView: View {
    @EnvironmentObject private var m: AppModel
    var body: some View {
        GroupBox("Opening Windows Apps") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.isDefaultExecutableHandler ? "Portside opens Windows .exe files" : "Open Windows apps directly from Finder")
                    Text("Known apps use their library settings. New files ask for a bottle.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if m.settingDefaultExecutableHandler { ProgressView().controlSize(.small) }
                Button("Make Default") { m.makeDefaultExecutableHandler() }
                    .disabled(m.isDefaultExecutableHandler || m.settingDefaultExecutableHandler)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
