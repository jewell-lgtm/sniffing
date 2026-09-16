import AppKit
import IOKit.ps
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
    private var poll: Timer?
    private var powerSource: CFRunLoopSource?
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Stay awake", action: #selector(toggle), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        toggleItem.target = self
        loginItem.target = self
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit sniffing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu

        // The system setting is the source of truth: adopt it, and keep following it
        // so changes made from a terminal or another tool show up here too.
        sync()
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        observePowerSource()
    }

    func applicationWillTerminate(_ note: Notification) {
        if active { deactivate() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        sync()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggle() {
        active ? deactivate() : activate()
    }

    private func activate() {
        guard Lid.set(disabled: true) else { return }
        sync()
    }

    private func deactivate() {
        Lid.set(disabled: false)
        sync()
    }

    /// Bring the assertion and UI in line with the system's lid-sleep setting.
    private func sync() {
        let lidDisabled = Lid.isDisabled
        if lidDisabled && assertion == 0 {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "sniffing: stay awake requested from the menu bar" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertion = id }
        }
        if !lidDisabled && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        active = lidDisabled
        render()
    }

    private func render() {
        let onCharger = Power.onCharger
        let effective = active && onCharger
        let symbol = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let state: String
        switch (active, onCharger) {
        case (true, true): state = "Lid closed: stays awake"
        case (true, false): state = "Lid closed: sleeps (on battery)"
        case (false, _): state = "Lid closed: sleeps"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state)
        statusItem.button?.appearsDisabled = active && !effective
        statusItem.button?.toolTip = state
        stateItem.title = state
        toggleItem.state = active ? .on : .off
    }

    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let app = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { app.render() }
        }, context)?.takeRetainedValue() else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
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

enum Power {
    /// The lid override is scoped to charger power, so on battery it has no effect.
    static var onCharger: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return String(type) == kIOPMACPowerKey
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
