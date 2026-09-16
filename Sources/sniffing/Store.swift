import Foundation

/// User preferences. Persisted, shared by the CLI and the menu bar app.
struct Settings: Codable, Equatable {
    /// Hold only a system-sleep assertion so the screen can still go dark.
    var allowDisplaySleep = false
    /// End the session when on battery at or below this charge. 0 disables the check.
    var batteryStopPercent = 20
    /// Global ⌃⌥⌘S toggles the session.
    var hotkeyEnabled = true
    /// Bundle identifiers whose running keeps the Mac awake.
    var triggerApps: [String] = []
}

/// Why the Mac is currently being kept awake, and what should end it.
struct Session: Codable, Equatable {
    /// When a timed session ends. nil means until turned off.
    var until: Date?
    /// The trigger app that started this session, which also ends it by quitting.
    var startedByApp: String?
    /// Trigger apps the user turned the session off under. They do not restart it until they relaunch.
    var dismissedApps: Set<String> = []
    /// Ended for low battery. No automatic restart until back on a charger.
    var batteryCutoff = false

    static let none = Session()
}

/// JSON file holding settings and session, read fresh on every access so the two processes
/// always see each other's writes.
@MainActor
enum Store {
    private struct File: Codable {
        var settings = Settings()
        var session = Session()
    }

    static let directory: URL = {
        if let dir = ProcessInfo.processInfo.environment["SNIFFING_STATE_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sniffing", isDirectory: true)
    }()

    private static var url: URL { directory.appendingPathComponent("state.json") }

    static var settings: Settings {
        get { load().settings }
        set { var f = load(); f.settings = newValue; save(f) }
    }

    static var session: Session {
        get { load().session }
        set { var f = load(); f.session = newValue; save(f) }
    }

    private static func load() -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(File.self, from: data)) ?? File()
    }

    private static func save(_ file: File) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
