import SwiftUI
import AppKit
import PortsideCore

@MainActor extension AppModel {
    typealias CompatibilityInstaller = @MainActor (Bottle, URL) async throws -> CompatibilitySetupResult

    func applyCompatibilitySetup(profile: CompatibilityProfile, bottleID: UUID, packURL: URL?,
                                 installer: CompatibilityInstaller? = nil) async throws -> CompatibilitySetupResult {
        guard !busy else { throw PortsideError.commandFailed("Another operation is running. Wait for it to finish, then try setup again.") }
        guard let store, let processes else { throw PortsideError.persistence("The Portside library is unavailable.") }
        try store.refresh(); sync()
        let target = try store.requireBottle(id: bottleID)
        guard target.initialized else { throw PortsideError.commandFailed("Initialize this bottle before applying compatibility setup.") }
        guard !isRunning(target) else { throw PortsideError.commandFailed("Stop this bottle before applying compatibility setup. Close this dialog and choose Stop Bottle.") }
        let targetURL = try store.bottleURL(for: target)
        activity = "Applying compatibility setup…"
        compatibilitySetupBottleID = bottleID
        defer {
            compatibilitySetupBottleID = nil
            activity = nil
            sync()
        }
        let result: CompatibilitySetupResult
        if let installer { result = try await installer(target, store.rootURL) }
        else {
            result = try await compatibilitySetup.install(profile: profile, bottle: target,
                                                           libraryRootURL: store.rootURL, packURL: packURL)
        }
        guard result.bottleID == bottleID else { throw PortsideError.commandFailed("Compatibility setup returned a different bottle. No bottle settings were changed.") }
        try store.refresh(); sync()
        var current = try store.requireBottle(id: bottleID)
        guard current.runtime == target.runtime, try store.bottleURL(for: current) == targetURL else {
            throw PortsideError.commandFailed("This bottle’s runtime or location changed during setup. Review its settings and try again.")
        }
        guard !isRunning(current) else {
            throw PortsideError.commandFailed("Components were applied, but this bottle started running before settings could be saved. Stop it and apply setup again.")
        }
        current.settings = BottleSettings(windowsVersion: profile.windowsVersion, debugLogging: false, locale: profile.locale)
        do {
            try await processes.applySettings(bottle: current, bottleURL: targetURL)
            try store.updateSettings(bottleID: bottleID, settings: current.settings)
        } catch {
            throw PortsideError.commandFailed("Setup components were applied, but bottle settings could not be completed. \(error.localizedDescription) Stop this bottle, resolve the error, and apply setup again. Setup log: \(result.logURL.path)")
        }
        showLog(result.logURL)
        return result
    }
}

struct CompatibilitySetupSheet: View {
    @EnvironmentObject private var m: AppModel
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    var initialProfileID: String? = nil
    var pendingLaunch: CompatibilityLaunchRequest? = nil
    var onApplied: (() -> Void)? = nil
    @State private var profiles: [CompatibilityProfile] = []
    @State private var profileID: String?
    @State private var packURL: URL?
    @State private var plan: CompatibilitySetupPlan?
    @State private var checking = false
    @State private var applying = false
    @State private var status: String?
    @State private var setupError: String?
    @State private var recheckID = UUID()
    @State private var applied = false
    @State private var handledLaunch = false

    private var profile: CompatibilityProfile? {
        pendingLaunch?.profile ?? profiles.first { $0.id == profileID }
    }
    private var currentBottle: Bottle? { m.state.bottles.first { $0.id == bottle.id } }
    private var running: Bool { currentBottle.map(m.isRunning) == true }
    private var readinessID: String { "\(profile?.id ?? "")|\(packURL?.path ?? "")|\(recheckID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Compatibility Setup", systemImage: "wrench.and.screwdriver").font(.title2.bold())
            Text("Bottle: \(bottle.name)").font(.headline).lineLimit(1).truncationMode(.tail).help(bottle.name)
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            if let request = pendingLaunch {
                Text("Portside recognized \(request.executableURL.lastPathComponent). Review its optional setup before running it.")
                    .foregroundStyle(.secondary)
            } else if !profiles.isEmpty {
                Picker("Profile", selection: $profileID) {
                    ForEach(profiles) { Text($0.title).tag(Optional($0.id)) }
                }.disabled(applying)
            }
            if let profile {
                Text(profile.title).font(.headline)
                Text(profile.summary).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(profile.components, id: \.self) { component in
                        Label(component == .dxvk ? "Direct3D 10/11 graphics (DXVK)" : "Simplified Chinese font (Noto CJK)", systemImage: "checklist")
                    }
                    Text("\(profile.windowsVersion.displayName) · \(profile.locale?.displayName ?? "System default language") · Quiet Wine diagnostics")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(profile.limitations, id: \.self) { limitation in
                    Text(limitation).font(.caption).foregroundStyle(.secondary)
                }
                if let url = profile.publisherURL { Link("Publisher information", destination: url) }
            }
            GroupBox("Requirements") {
                VStack(alignment: .leading, spacing: 10) {
                    if checking {
                        HStack { ProgressView().controlSize(.small); Text("Checking Python and setup data…") }
                    } else if let plan {
                        Label("Python 3 ready", systemImage: "checkmark.circle").foregroundStyle(.green)
                            .help(plan.pythonURL.path)
                        Label("Setup data ready", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label("Python and setup data need checking", systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                    if let packURL {
                        Text(packURL.path).font(.caption).lineLimit(2).truncationMode(.middle).help(packURL.path)
                    } else {
                        Text("Uses setup data included in this app when available.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Choose Data Pack…") { choosePack() }
                        Button("Check Again") { recheckID = UUID() }.disabled(checking)
                    }.disabled(applying)
                    if plan == nil, !checking {
                        Text("A source build can create the optional pack with scripts/build-compatibility-pack.sh. Select its .build/compatibility-pack folder here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("Get Python 3 for macOS", destination: CompatibilitySetup.pythonDownloadURL)
                    }
                    Text("Portside does not install Python or download components automatically.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if running {
                Label("Stop this bottle before setup. Close this dialog and choose Stop Bottle.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.orange)
            } else if currentBottle == nil {
                Text("This bottle was removed. Close setup and select an existing bottle.").foregroundStyle(.red)
            }
            if let status { Text(status).font(.callout).foregroundStyle(.green).textSelection(.enabled) }
            if let setupError { Text(setupError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 440)
            HStack {
                Button(applied && pendingLaunch == nil ? "Done" : "Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction).disabled(applying)
                Spacer()
                if let request = pendingLaunch {
                    Button("Run Without Setup") {
                        resume(request, withoutSetup: true)
                    }.disabled(m.busy || applying)
                }
                Button(pendingLaunch == nil ? "Apply Setup" : applied ? "Run" : "Set Up & Run") { apply() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(profile == nil || plan == nil || checking || applying || m.busy || running || currentBottle == nil)
            }
        }
        .padding(26).frame(width: 650)
        .interactiveDismissDisabled(applying || m.busy)
        .task {
            do {
                profiles = try m.compatibilitySetup.loadProfiles()
                profileID = initialProfileID ?? profiles.first?.id
            } catch { setupError = error.localizedDescription }
        }
        .task(id: readinessID) { await prepare() }
        .onDisappear {
            if let request = pendingLaunch, !handledLaunch { m.cancelCompatibilityLaunch(request) }
        }
    }

    private func prepare() async {
        guard let profile else { return }
        checking = true; plan = nil; setupError = nil; status = nil; applied = false
        defer { if !Task.isCancelled { checking = false } }
        do {
            let result = try await m.compatibilitySetup.prepare(profile: profile, packURL: packURL)
            guard !Task.isCancelled else { return }
            plan = result
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            setupError = error.localizedDescription
        }
    }

    private func choosePack() {
        if let url = m.pickFile(folders: true) { packURL = url; recheckID = UUID() }
    }

    private func apply() {
        guard let profile else { return }
        if applied, let request = pendingLaunch {
            resume(request)
            return
        }
        applying = true; setupError = nil; status = nil
        Task {
            defer { applying = false }
            do {
                _ = try await m.applyCompatibilitySetup(profile: profile, bottleID: bottle.id, packURL: packURL)
                applied = true
                status = "Setup applied to “\(bottle.name)”."
                onApplied?()
                if let request = pendingLaunch { resume(request) }
            } catch { setupError = error.localizedDescription }
        }
    }

    private func resume(_ request: CompatibilityLaunchRequest, withoutSetup: Bool = false) {
        let started = withoutSetup ? m.runCompatibilityWithoutSetup(request) : m.resumeCompatibilityLaunch(request)
        if started { handledLaunch = true; dismiss() }
        else {
            setupError = m.error ?? "This pending launch is no longer available. Close setup and open the app again."
            m.error = nil
        }
    }

    private func cancel() {
        if let request = pendingLaunch { handledLaunch = true; m.cancelCompatibilityLaunch(request) }
        dismiss()
    }
}
