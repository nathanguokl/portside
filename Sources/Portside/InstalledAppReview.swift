import Foundation
import SwiftUI
import PortsideCore

struct PendingInstalledDiscovery {
    let bottleID: UUID
    var userInitiated: Bool
}

enum LibraryEntryPresentation {
    static func executablePath(_ executable: URL, in bottle: Bottle?, bottlesURL: URL?) -> String {
        guard let bottle, let bottlesURL else { return executable.path }
        let drive = bottlesURL.appendingPathComponent(bottle.directoryName, isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true).standardizedFileURL.path
        let path = executable.standardizedFileURL.path
        guard path.hasPrefix(drive + "/") else { return executable.path }
        return "C:\\" + path.dropFirst(drive.count + 1).replacingOccurrences(of: "/", with: "\\")
    }

    static func isSetupTool(_ app: WindowsApp) -> Bool {
        let filename = app.executableURL.deletingPathExtension().lastPathComponent.lowercased()
        return filename.contains("downloader") || filename.contains("installer") || filename.hasPrefix("setup")
            || filename == "install" || filename == "download" || filename.contains("bootstrapper")
    }

    static func sorted(_ apps: [WindowsApp]) -> [WindowsApp] {
        apps.sorted {
            let firstSetup = isSetupTool($0), secondSetup = isSetupTool($1)
            if firstSetup != secondSetup { return !firstSetup }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}

@MainActor extension AppModel {
    func cancelInstalledAppDiscovery() {
        installedDiscoveryGeneration += 1
        installedDiscoveryTask?.cancel()
        installedDiscoveryTask = nil
        isDiscoveringInstalledApps = false
        pendingInstalledDiscovery = nil
    }

    func selectedBottleChangedForDiscovery() {
        cancelInstalledAppDiscovery()
        installedAppCandidates = []
        installedDiscoveryMessage = nil
        if automaticDiscoveryEnabled { requestInstalledAppDiscovery() }
    }

    func requestInstalledAppDiscovery(bottleID: UUID? = nil, userInitiated: Bool = false) {
        guard let id = bottleID ?? selected, id == selected else { return }
        let requestedByUser = userInitiated || pendingInstalledDiscovery?.userInitiated == true
        pendingInstalledDiscovery = PendingInstalledDiscovery(bottleID: id, userInitiated: requestedByUser)
        // File requests use the same scheduler and always get priority.
        resumeFileOpening()
    }

    func discoverAfterCompletion(_ result: ProcessResult) {
        guard automaticDiscoveryEnabled, !result.isSessionWatcher,
              ["Install ", "Launch ", "Open "].contains(where: result.kind.hasPrefix) else { return }
        requestInstalledAppDiscovery(bottleID: result.bottleID)
    }

    func discoverWhileBottleIsRunning() {
        guard automaticDiscoveryEnabled, !isDiscoveringInstalledApps, let bottle, isRunning(bottle) else { return }
        requestInstalledAppDiscovery(bottleID: bottle.id)
    }

    func startPendingInstalledDiscoveryIfPossible() {
        guard let pending = pendingInstalledDiscovery, pending.bottleID == selected,
              !isDiscoveringInstalledApps, !busy, !hasModalPresentation,
              sheet == nil, externalOpen == nil, error == nil, queuedOpenURLs.isEmpty else { return }
        pendingInstalledDiscovery = nil
        do {
            guard let store else { throw PortsideError.persistence("The Portside library is unavailable.") }
            try store.refresh(); sync()
            let bottle = try store.requireBottle(id: pending.bottleID)
            guard bottle.initialized else {
                if pending.userInitiated { installedDiscoveryMessage = "Initialize this bottle before looking for installed apps." }
                return
            }
            let directory = try store.bottleURL(for: bottle)
            let registered = state.apps
            let scanner = installedAppScanner
            installedDiscoveryGeneration += 1
            let generation = installedDiscoveryGeneration
            isDiscoveringInstalledApps = true
            installedDiscoveryMessage = nil
            let worker = Task.detached(priority: .utility) { try scanner(bottle, directory, registered) }
            installedDiscoveryTask = Task { [weak self] in
                await withTaskCancellationHandler {
                    do {
                        let candidates = try await worker.value
                        guard !Task.isCancelled else { return }
                        self?.finishInstalledDiscovery(candidates, bottleID: bottle.id, directory: directory,
                                                       generation: generation, userInitiated: pending.userInitiated)
                    } catch is CancellationError {
                        self?.finishCancelledInstalledDiscovery(bottleID: bottle.id, generation: generation)
                    } catch {
                        self?.failInstalledDiscovery(error, bottleID: bottle.id, generation: generation)
                    }
                } onCancel: { worker.cancel() }
            }
        } catch {
            installedDiscoveryMessage = "Could not look for installed apps. \(error.localizedDescription)"
        }
    }

    private func finishCancelledInstalledDiscovery(bottleID: UUID, generation: Int) {
        guard generation == installedDiscoveryGeneration, selected == bottleID else { return }
        isDiscoveringInstalledApps = false
        installedDiscoveryTask = nil
        resumeFileOpening()
    }

    private func finishInstalledDiscovery(_ candidates: [InstalledAppCandidate], bottleID: UUID, directory: URL,
                                         generation: Int, userInitiated: Bool) {
        guard generation == installedDiscoveryGeneration, selected == bottleID else { return }
        defer {
            isDiscoveringInstalledApps = false
            installedDiscoveryTask = nil
            resumeFileOpening()
        }
        do {
            guard let store else { return }
            try store.refresh(); sync()
            let current = try store.requireBottle(id: bottleID)
            guard current.initialized, canonical(try store.bottleURL(for: current)) == canonical(directory) else { return }
            installedAppCandidates = candidates.filter { $0.bottleID == bottleID }
            pruneRegisteredDiscoveryCandidates()
            if userInitiated, installedAppCandidates.isEmpty {
                installedDiscoveryMessage = "No new app launchers found. If installation is still running, wait and try again, or choose its installed .exe with Add Manually."
            }
        } catch {
            installedAppCandidates = []
            installedDiscoveryMessage = "Could not review the apps found. \(error.localizedDescription)"
        }
    }

    private func failInstalledDiscovery(_ failure: Error, bottleID: UUID, generation: Int) {
        guard generation == installedDiscoveryGeneration, selected == bottleID else { return }
        isDiscoveringInstalledApps = false
        installedDiscoveryTask = nil
        installedDiscoveryMessage = "Could not look for installed apps. \(failure.localizedDescription)"
        resumeFileOpening()
    }

    func pruneRegisteredDiscoveryCandidates() {
        let registered = Set(state.apps.filter { $0.bottleID == selected }.map { canonical($0.executableURL) })
        installedAppCandidates.removeAll { $0.bottleID != selected || registered.contains(canonical($0.executableURL)) }
    }

    func addDiscoveredApp(_ candidate: InstalledAppCandidate, launchAfterAdding: Bool) {
        guard !busy, !hasModalPresentation, error == nil, queuedOpenURLs.isEmpty,
              selected == candidate.bottleID,
              installedAppCandidates.contains(where: { $0.id == candidate.id && $0.bottleID == candidate.bottleID }) else { return }
        do {
            guard let store else { throw PortsideError.persistence("The Portside library is unavailable.") }
            try store.refresh(); sync()
            let bottle = try store.requireBottle(id: candidate.bottleID)
            guard bottle.initialized else { throw PortsideError.commandFailed("Initialize this bottle before adding apps.") }
            let prefix = canonical(try store.bottleURL(for: bottle))
            let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
            let attributes = try Foundation.FileManager().attributesOfItem(atPath: drive.path)
            guard attributes[Foundation.FileAttributeKey.type] as? Foundation.FileAttributeType == .typeDirectory,
                  canonical(drive).path == drive.path, isInside(drive, directory: prefix) else {
                throw PortsideError.invalidExecutable("This bottle’s C: drive moved or became a symbolic link. Restore it before adding an app.")
            }
            let executable = canonical(candidate.executableURL)
            let working = canonical(candidate.workingDirectoryURL)
            guard isInside(executable, directory: drive), (working.path == drive.path || isInside(working, directory: drive)),
                  working == executable.deletingLastPathComponent() else {
                throw PortsideError.invalidExecutable("The app moved outside this bottle. Find installed apps again.")
            }
            try PEExecutable.validate(url: executable)
            let existing = state.apps.filter { $0.bottleID == bottle.id && canonical($0.executableURL) == executable }
            let app: WindowsApp
            if existing.count > 1 {
                throw PortsideError.commandFailed("This app already has multiple library entries. Choose its launch settings from Applications.")
            } else if let saved = existing.first { app = saved }
            else {
                app = try store.registerApp(name: candidate.name, executableURL: executable, bottleID: bottle.id, workingDirectory: working)
            }
            sync()
            installedAppCandidates.removeAll { $0.id == candidate.id }
            installedDiscoveryMessage = "Added \(app.name) to Applications. Open its library entry for future launches."
            if launchAfterAdding { launch(app) }
        } catch {
            installedDiscoveryMessage = "Could not add this app. \(error.localizedDescription)"
        }
    }

    private func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private func isInside(_ file: URL, directory: URL) -> Bool {
        let parent = directory.pathComponents, child = file.pathComponents
        return child.count > parent.count && child.starts(with: parent)
    }
}

struct InstalledAppReviewView: View {
    @EnvironmentObject private var m: AppModel
    @State private var showsAllCandidates = false
    private var visibleCandidates: [InstalledAppCandidate] {
        showsAllCandidates ? m.installedAppCandidates : Array(m.installedAppCandidates.prefix(3))
    }
    var body: some View {
        if m.isDiscoveringInstalledApps || !m.installedAppCandidates.isEmpty || m.installedDiscoveryMessage != nil {
            VStack(alignment: .leading, spacing: 12) {
                if m.isDiscoveringInstalledApps {
                    HStack { ProgressView().controlSize(.small); Text("Looking for installed app launchers…").foregroundStyle(.secondary) }
                }
                if !m.installedAppCandidates.isEmpty {
                    Text("Apps found in this bottle").font(.headline)
                    Text("Add a launcher to reopen it from your library. Finish the Windows installer before launching.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(visibleCandidates) { candidate in
                        HStack(spacing: 12) {
                            Image(systemName: "app.dashed").foregroundStyle(PortsideBrand.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.name).font(.headline).lineLimit(1)
                                Text(LibraryEntryPresentation.executablePath(candidate.executableURL,
                                    in: m.state.bottles.first { $0.id == candidate.bottleID }, bottlesURL: m.store?.bottlesURL))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).help(candidate.executableURL.path)
                            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            Button("Add to Library") { m.addDiscoveredApp(candidate, launchAfterAdding: false) }.fixedSize()
                            Button("Add & Launch") { m.addDiscoveredApp(candidate, launchAfterAdding: true) }
                                .buttonStyle(.borderedProminent).fixedSize()
                        }
                        .disabled(m.busy || m.hasModalPresentation || m.error != nil || !m.queuedOpenURLs.isEmpty)
                    }
                    if m.installedAppCandidates.count > 3 {
                        Button(showsAllCandidates ? "Show fewer" : "Show all \(m.installedAppCandidates.count) apps found") {
                            showsAllCandidates.toggle()
                        }.buttonStyle(.link)
                    }
                }
                if let message = m.installedDiscoveryMessage { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Searches up to six folder levels in this bottle’s C: drive. Use Add Manually for other locations.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PortsideBrand.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: m.selected) { _, _ in showsAllCandidates = false }
        }
    }
}
