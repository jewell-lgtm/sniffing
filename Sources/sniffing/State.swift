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

/// Executables the CLI shells out to. Overridable so tests can substitute recording fakes
/// without root or touching the machine's real sleep setting.
enum Tools {
    static let pmset = ProcessInfo.processInfo.environment["SNIFFING_PMSET"] ?? "/usr/bin/pmset"
    static let sudo = ProcessInfo.processInfo.environment["SNIFFING_SUDO"] ?? "/usr/bin/sudo"
    static let osascript = ProcessInfo.processInfo.environment["SNIFFING_OSASCRIPT"] ?? "/usr/bin/osascript"
}

/// Lid-close sleep is controlled by `pmset disablesleep`, which needs root.
/// A sudoers NOPASSWD rule makes it silent; otherwise the user is asked for a password.
@MainActor
enum Lid {
    enum Prompt {
        /// Ask on the controlling terminal via plain `sudo`. Falls back to the dialog when
        /// stdin is not a terminal, because a password typed anywhere else would be echoed.
        case terminal
        /// Ask with the macOS administrator dialog.
        case dialog
    }

    static var isDisabled: Bool {
        let out = run(Tools.pmset, ["-g"]).output
        return out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    @discardableResult
    static func set(disabled: Bool, prompt: Prompt) -> Bool {
        let value = disabled ? "1" : "0"
        if run(Tools.sudo, ["-n", Tools.pmset, "-c", "disablesleep", value]).status == 0 {
            return true
        }
        switch prompt {
        case .terminal where isatty(STDIN_FILENO) == 1:
            return runInForeground(Tools.sudo, [Tools.pmset, "-c", "disablesleep", value]) == 0
        case .terminal, .dialog:
            let script = "do shell script \"\(Tools.pmset) -c disablesleep \(value)\" with administrator privileges"
            return run(Tools.osascript, ["-e", script]).status == 0
        }
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Spawn a child that shares our process group and terminal. `Process` puts children in
    /// their own group, which leaves a password prompt unable to turn off echo on the TTY.
    private static func runInForeground(_ path: String, _ args: [String]) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid = pid_t(0)
        guard posix_spawn(&pid, path, nil, nil, argv, environ) == 0 else { return -1 }
        var status = Int32(0)
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        guard status & 0x7f == 0 else { return -1 }
        return (status >> 8) & 0xff
    }
}
