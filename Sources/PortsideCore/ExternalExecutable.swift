import Foundation

/// Decides how a Finder-opened executable should use the existing library, without changing it.
public enum ExternalExecutable {
    public enum OpenAction: Equatable, Sendable {
        /// Launch the complete saved entry, including its working directory and arguments.
        case registered(WindowsApp)
        case chooseRegistration([WindowsApp])
        /// An unregistered executable is already inside this managed bottle.
        case bottle(Bottle)
        case chooseBottle([Bottle])
    }

    /// `bottleDirectories` contains only paths validated by `LibraryStore.bottleURL(for:)`.
    /// Passing validated paths keeps ownership checks in LibraryStore and avoids guessing a
    /// bottle from the frontend's current selection or the executable's filename.
    public static func resolve(url: URL, state: LibraryState,
                               bottleDirectories: [UUID: URL]) throws -> OpenAction {
        let executable = canonical(url)
        try PEExecutable.validate(url: executable)
        let available = state.bottles.filter { $0.initialized && bottleDirectories[$0.id] != nil }
        let saved = state.apps.filter { canonical($0.executableURL) == executable }
        let usableSaved = saved.filter { app in available.contains { $0.id == app.bottleID } }
        if usableSaved.count == 1 { return .registered(usableSaved[0]) }
        if usableSaved.count > 1 { return .chooseRegistration(usableSaved) }
        if let app = saved.first {
            guard let bottle = state.bottles.first(where: { $0.id == app.bottleID }) else {
                throw PortsideError.missingBottle
            }
            throw PortsideError.commandFailed("The saved app's bottle “\(bottle.name)” is unavailable. Open Portside and initialize or repair that bottle before launching this app.")
        }

        let containing = state.bottles.filter { bottle in
            guard let directory = bottleDirectories[bottle.id] else { return false }
            let parent = canonical(directory).pathComponents
            let child = executable.pathComponents
            return child.count > parent.count && child.starts(with: parent)
        }
        let usableContaining = containing.filter { $0.initialized }
        if usableContaining.count == 1 { return .bottle(usableContaining[0]) }
        if usableContaining.count > 1 { return .chooseBottle(usableContaining) }
        if let bottle = containing.first {
            throw PortsideError.commandFailed("The bottle “\(bottle.name)” has not finished initializing. Open Portside and initialize it before running this executable.")
        }
        return .chooseBottle(available)
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
