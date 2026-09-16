import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func run() {
        let app = NSApplication.shared
        let delegate = MenuBarApp()
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
        // so changes made from the CLI or another tool show up here too.
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
        if !Lid.set(disabled: true, prompt: .dialog) { showLidError() }
        sync()
    }

    private func deactivate() {
        if !Lid.set(disabled: false, prompt: .dialog) { showLidError() }
        sync()
    }

    /// Bring the assertion and UI in line with the system's lid-sleep setting.
    private func sync() {
        let state = State.current
        if state.active && assertion == 0 {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "sniffing: stay awake requested" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertion = id }
        }
        if !state.active && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        active = state.active
        render(state)
    }

    private func render(_ state: State) {
        let symbol = state.active ? "cup.and.saucer.fill" : "cup.and.saucer"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.summary)
        statusItem.button?.appearsDisabled = state.active && !state.effective
        statusItem.button?.toolTip = state.summary
        stateItem.title = state.summary
        toggleItem.state = state.active ? .on : .off
    }

    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let app = Unmanaged<MenuBarApp>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { app.render(State.current) }
        }, context)?.takeRetainedValue() else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func showLidError() {
        let alert = NSAlert()
        alert.messageText = "Couldn't change lid sleep"
        alert.informativeText = "pmset needs admin rights. Approve the prompt, or add the sudoers rule from the README."
        alert.runModal()
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
