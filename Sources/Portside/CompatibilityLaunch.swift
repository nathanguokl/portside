import Foundation
import PortsideCore

/// Captures a complete launch before asynchronous recognition or a setup dialog.
/// Changing sidebar selection cannot retarget the pending Windows application.
struct WindowsLaunchRequest: Equatable {
    let bottle: Bottle
    let executableURL: URL
    var arguments: [String] = []
    var workingDirectory: URL? = nil
    let kind: String
    var remember = false
    var appID: UUID? = nil
}

struct CompatibilityLaunchRequest: Identifiable, Equatable {
    let id = UUID()
    let launch: WindowsLaunchRequest
    let profile: CompatibilityProfile
    var bottle: Bottle { launch.bottle }
    var executableURL: URL { launch.executableURL }
    var arguments: [String] { launch.arguments }
    var workingDirectory: URL? { launch.workingDirectory }
    var kind: String { launch.kind }
    var remember: Bool { launch.remember }
    var appID: UUID? { launch.appID }
}

@MainActor extension AppModel {
    /// Starts one serialized recognition task. Unknown executables use generic Wine.
    func requestWindowsLaunch(_ request: WindowsLaunchRequest) {
        guard !busy, compatibilityLaunch == nil else { return }
        perform("Checking application…") {
            try PEExecutable.validate(url: request.executableURL)
            if let profile = try await self.compatibilitySetup.detectProfile(executableURL: request.executableURL),
               let store = self.store {
                try store.refresh()
                let bottle = try store.requireBottle(id: request.bottle.id)
                let status = try await self.compatibilitySetup.bottleStatus(profile: profile, bottle: bottle,
                                                                           libraryRootURL: store.rootURL)
                if !status.isConfigured {
                    self.compatibilityLaunch = CompatibilityLaunchRequest(launch: request, profile: profile)
                    self.presentPendingCompatibilityLaunch()
                    return
                }
            }
            try self.executeWindowsLaunch(request)
        }
    }

    func presentPendingCompatibilityLaunch() {
        guard let request = compatibilityLaunch, error == nil, !hasModalPresentation, sheet == nil else { return }
        presentedCompatibilityLaunchID = request.id
        sheet = .compatibilityLaunch
    }

    func cancelCompatibilityLaunch(_ request: CompatibilityLaunchRequest) {
        guard compatibilityLaunch?.id == request.id else { return }
        compatibilityLaunch = nil
    }

    @discardableResult func resumeCompatibilityLaunch(_ request: CompatibilityLaunchRequest) -> Bool {
        guard compatibilityLaunch?.id == request.id, !busy else { return false }
        do {
            try executeWindowsLaunch(request.launch)
            compatibilityLaunch = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult func runCompatibilityWithoutSetup(_ request: CompatibilityLaunchRequest) -> Bool {
        resumeCompatibilityLaunch(request)
    }

    /// Revalidates ownership and any saved entry after a potentially long setup.
    /// Process arguments remain individual values throughout the workflow.
    private func executeWindowsLaunch(_ request: WindowsLaunchRequest) throws {
        guard let store, let processes else { throw PortsideError.persistence("The library is unavailable.") }
        try store.refresh()
        let bottle = try store.requireBottle(id: request.bottle.id)
        guard bottle.initialized else { throw PortsideError.commandFailed("Initialize this bottle before opening a Windows app.") }
        if let appID = request.appID {
            guard let current = store.state.apps.first(where: { $0.id == appID }) else {
                throw PortsideError.commandFailed("This application was removed from the library. Select an existing application.")
            }
            guard current.bottleID == bottle.id, current.executableURL == request.executableURL,
                  current.arguments == request.arguments, current.workingDirectoryURL == request.workingDirectory else {
                throw PortsideError.commandFailed("This application's launch settings changed while setup was open. Launch it again to review the current settings.")
            }
        }
        let run = try processes.run(bottle: bottle, bottleURL: store.bottleURL(for: bottle),
                                    executableURL: request.executableURL, arguments: request.arguments,
                                    workingDirectory: request.workingDirectory, kind: request.kind)
        selected = bottle.id
        showLog(run.logURL)
        if request.remember {
            do {
                try store.registerApp(name: request.executableURL.deletingPathExtension().lastPathComponent,
                                      executableURL: request.executableURL, bottleID: bottle.id,
                                      workingDirectory: request.workingDirectory, arguments: request.arguments)
            } catch {
                self.error = "The app started, but its library entry could not be saved. \(error.localizedDescription)"
            }
        }
        sync()
    }
}
