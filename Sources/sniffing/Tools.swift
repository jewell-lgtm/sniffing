import Foundation
import IOKit.ps

/// Executables the CLI shells out to. Overridable so tests can substitute recording fakes
/// without root or touching the machine's real sleep setting.
enum Tools {
    static let pmset = ProcessInfo.processInfo.environment["SNIFFING_PMSET"] ?? "/usr/bin/pmset"
    static let sudo = ProcessInfo.processInfo.environment["SNIFFING_SUDO"] ?? "/usr/bin/sudo"
    static let osascript = ProcessInfo.processInfo.environment["SNIFFING_OSASCRIPT"] ?? "/usr/bin/osascript"
}

enum Power {
    /// The lid override is scoped to charger power, so on battery it has no effect.
    static var onCharger: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return String(type) == kIOPMACPowerKey
    }

    /// Battery charge as a percentage, or nil on a Mac without one.
    static var batteryPercent: Int? {
        if let fake = ProcessInfo.processInfo.environment["SNIFFING_BATTERY"] { return Int(fake) }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }
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
        /// Never ask. For changes the user did not just request, such as a timer ending.
        case none
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
        case .none:
            return false
        case .terminal where isatty(STDIN_FILENO) == 1:
            return runInForeground(Tools.sudo, [Tools.pmset, "-c", "disablesleep", value]) == 0
        case .terminal, .dialog:
            let script = "do shell script \"\(Tools.pmset) -c disablesleep \(value)\" with administrator privileges"
            return run(Tools.osascript, ["-e", script]).status == 0
        }
    }

    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
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
