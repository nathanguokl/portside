import AppKit
import UniformTypeIdentifiers

@MainActor enum FileAssociation {
    static func readDefaultHandler() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: UTType.exe)
    }

    static var isDefault: Bool {
        isDefaultApplication(readDefaultHandler(), currentApplicationURL: Bundle.main.bundleURL)
    }

    static func isDefaultApplication(_ handlerURL: URL?, currentApplicationURL: URL) -> Bool {
        guard let handlerURL,
              let currentIdentifier = Bundle(url: currentApplicationURL)?.bundleIdentifier,
              Bundle(url: handlerURL)?.bundleIdentifier == currentIdentifier else { return false }
        return handlerURL.standardizedFileURL.resolvingSymlinksInPath()
            == currentApplicationURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func setDefaultApplication() async throws {
        let applicationURL = Bundle.main.bundleURL
        guard applicationURL.pathExtension.lowercased() == "app" else {
            throw AssociationError.unbundledApplication
        }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: UTType.exe)
        } catch {
            throw AssociationError.system(error.localizedDescription)
        }
        guard isDefault else { throw AssociationError.notApplied }
    }

    private enum AssociationError: LocalizedError {
        case unbundledApplication, system(String), notApplied

        var errorDescription: String? {
            switch self {
            case .unbundledApplication:
                return "Open the installed Portside.app, then make it the default for Windows applications."
            case .system(let detail):
                return "macOS could not make Portside the default for .exe files. \(detail) You can also select an .exe in Finder, choose Get Info → Open with → Portside, and click Change All."
            case .notApplied:
                return "macOS did not change the default for .exe files. Try again and approve the macOS prompt, or use Finder’s Get Info → Open with → Portside → Change All."
            }
        }
    }
}
