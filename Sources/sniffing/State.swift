import Foundation
import IOKit.ps

/// What the machine will actually do when the lid closes, from the system's own settings.
struct State {
    let active: Bool
    let onCharger: Bool

    /// True when the lid override is both armed and in effect.
    var effective: Bool { active && onCharger }

    var summary: String {
        switch (active, onCharger) {
        case (true, true): return "Lid closed: stays awake"
        case (true, false): return "Lid closed: sleeps (on battery)"
        case (false, _): return "Lid closed: sleeps"
        }
    }

    @MainActor
    static var current: State {
        State(active: Lid.isDisabled, onCharger: Power.onCharger)
    }
}

enum Power {
    /// The lid override is scoped to charger power, so on battery it has no effect.
    static var onCharger: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return String(type) == kIOPMACPowerKey
    }
}

/// Lid-close sleep is controlled by `pmset disablesleep`, which needs root.
/// A sudoers NOPASSWD rule makes it silent; otherwise the user is asked for a password.
@MainActor
enum Lid {
    enum Prompt {
        /// Ask on the controlling terminal via plain `sudo`.
        case terminal
        /// Ask with the macOS administrator dialog.
        case dialog
    }

    static var isDisabled: Bool {
        let out = run("/usr/bin/pmset", ["-g"]).output
        return out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    @discardableResult
    static func set(disabled: Bool, prompt: Prompt) -> Bool {
        let value = disabled ? "1" : "0"
        if run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-c", "disablesleep", value]).status == 0 {
            return true
        }
        switch prompt {
        case .terminal:
            return run("/usr/bin/sudo", ["/usr/bin/pmset", "-c", "disablesleep", value], inheritIO: true).status == 0
        case .dialog:
            let script = "do shell script \"/usr/bin/pmset -c disablesleep \(value)\" with administrator privileges"
            return run("/usr/bin/osascript", ["-e", script]).status == 0
        }
    }

    private static func run(_ path: String, _ args: [String], inheritIO: Bool = false) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        if !inheritIO {
            process.standardOutput = pipe
            process.standardError = pipe
        }
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = inheritIO ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
