import AppKit
import IOKit.pwr_mgt
import ServiceManagement

@main
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var assertion = IOPMAssertionID(0)
    private var active = false
    private let toggleItem = NSMenuItem(title: "Stay awake", action: #selector(toggle), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        toggleItem.target = self
        loginItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit sniffing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // A previous session that crashed or was killed may have left lid sleep off.
        if Lid.isDisabled { Lid.set(disabled: false) }
        render()
    }

    func applicationWillTerminate(_ note: Notification) {
        deactivate()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggle() {
        active ? deactivate() : activate()
    }

    private func activate() {
        guard Lid.set(disabled: true) else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "sniffing: stay awake requested from the menu bar" as CFString,
            &id
        )
        if result == kIOReturnSuccess { assertion = id }
        active = true
        render()
    }

    private func deactivate() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        Lid.set(disabled: false)
        active = false
        render()
    }

    private func render() {
        let symbol = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let label = active ? "sniffing: on" : "sniffing: off"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        statusItem.button?.toolTip = label
        toggleItem.state = active ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Lid-close sleep is controlled by `pmset disablesleep`, which needs root.
/// A sudoers NOPASSWD rule makes it silent; otherwise macOS shows an admin prompt.
@MainActor
enum Lid {
    static var isDisabled: Bool {
        let out = run("/usr/bin/pmset", ["-g"]).output
        return out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    @discardableResult
    static func set(disabled: Bool) -> Bool {
        let value = disabled ? "1" : "0"
        if run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-c", "disablesleep", value]).status == 0 {
            return true
        }
        let script = "do shell script \"/usr/bin/pmset -c disablesleep \(value)\" with administrator privileges"
        if run("/usr/bin/osascript", ["-e", script]).status == 0 {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Couldn't change lid sleep"
        alert.informativeText = "pmset needs admin rights. Approve the prompt, or add the sudoers rule from the README."
        alert.runModal()
        return false
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
}
