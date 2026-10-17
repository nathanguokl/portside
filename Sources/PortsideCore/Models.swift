import Foundation

public enum PortsideError: LocalizedError {
    case invalidRuntime(String)
    case invalidExecutable(String)
    case unsafeBottle(String)
    case missingBottle
    case invalidName
    case commandFailed(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRuntime(let detail): return "Wine runtime unavailable. \(detail)"
        case .invalidExecutable(let detail): return "Invalid Windows executable. \(detail)"
        case .unsafeBottle(let detail): return "Bottle operation refused. \(detail)"
        case .missingBottle: return "This bottle no longer exists. Select an existing bottle."
        case .invalidName: return "Enter a name containing at least one non-space character."
        case .commandFailed(let detail): return detail
        case .persistence(let detail): return "Could not save the Portside library. \(detail)"
        }
    }
}

public struct WineRuntime: Codable, Equatable, Sendable {
    public var wineURL: URL
    public var version: String
    public var source: String
    public var validatedAt: Date
    public var wineServerURL: URL { wineURL.deletingLastPathComponent().appendingPathComponent("wineserver") }
    public var wineBootURL: URL { wineURL.deletingLastPathComponent().appendingPathComponent("wineboot") }
    public init(wineURL: URL, version: String, source: String, validatedAt: Date = Date()) {
        self.wineURL = wineURL.standardizedFileURL
        self.version = version
        self.source = source
        self.validatedAt = validatedAt
    }
}

public enum WindowsVersion: String, Codable, CaseIterable, Identifiable, Sendable {
    case win10, win11, win7
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .win10: return "Windows 10"; case .win11: return "Windows 11"; case .win7: return "Windows 7" }
    }
}

public enum WineLocale: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en_US.UTF-8"
    case simplifiedChinese = "zh_CN.UTF-8"
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        }
    }
}

public struct BottleSettings: Codable, Equatable, Sendable {
    public var windowsVersion: WindowsVersion
    public var debugLogging: Bool
    public var locale: WineLocale?
    public init(windowsVersion: WindowsVersion = .win10, debugLogging: Bool = false, locale: WineLocale? = nil) {
        self.windowsVersion = windowsVersion
        self.debugLogging = debugLogging
        self.locale = locale
    }
}

public struct Bottle: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var directoryName: String
    public var createdAt: Date
    public var settings: BottleSettings
    public var runtime: WineRuntime
    public var initialized: Bool
    public var initializationError: String?
    public var runtimeVersion: String { runtime.version }
    public init(id: UUID = UUID(), name: String, runtime: WineRuntime, settings: BottleSettings = BottleSettings()) {
        self.id = id
        self.name = name
        self.directoryName = id.uuidString
        self.createdAt = Date()
        self.settings = settings
        self.runtime = runtime
        self.initialized = false
        self.initializationError = nil
    }
}

public struct WindowsApp: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var executablePath: String
    public var workingDirectory: String
    public var arguments: [String]
    public var bottleID: UUID
    public var executableURL: URL { URL(fileURLWithPath: executablePath, isDirectory: false) }
    public var workingDirectoryURL: URL { URL(fileURLWithPath: workingDirectory, isDirectory: true) }
    public init(id: UUID = UUID(), name: String, executablePath: String, workingDirectory: String, arguments: [String] = [], bottleID: UUID) {
        self.id = id; self.name = name; self.executablePath = executablePath
        self.workingDirectory = workingDirectory; self.arguments = arguments; self.bottleID = bottleID
    }
}

public struct LibraryState: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = LibraryState.currentSchemaVersion
    public var runtime: WineRuntime?
    public var bottles: [Bottle] = []
    public var apps: [WindowsApp] = []
    public init() {}
}

public struct RunningWineProcess: Identifiable, Sendable {
    public let id: UUID
    public let bottleID: UUID
    public let kind: String
    public let logURL: URL
    public let startedAt: Date
    public let pid: Int32
}

public struct ProcessResult: Identifiable, Sendable {
    public let id: UUID
    public let bottleID: UUID
    public let kind: String
    public let logURL: URL
    public let startedAt: Date
    public let finishedAt: Date
    public let exitCode: Int32
    public let timedOut: Bool
    public let summary: String
    /// True for the `wineserver -w` processes that watch a bottle's Windows session, not for user-requested work.
    public let isSessionWatcher: Bool
    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// Throws the failure that the app and CLI report: the summary plus the log to inspect.
    public func requireSuccess() throws {
        guard succeeded else { throw PortsideError.commandFailed("\(summary) Log: \(logURL.path)") }
    }
}
