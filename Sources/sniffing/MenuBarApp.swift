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
    private var assertionAllowsDisplaySleep = false
    private var active = false
    /// Why the last automatic change could not be applied. Shown until the next successful change.
    private var blocked: String?
    private var poll: Timer?
    private var countdown: Timer?
    private var powerSource: CFRunLoopSource?
    private var hotKey: HotKey?

    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let blockedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Stay awake", action: #selector(toggle), keyEquivalent: "")
    private let forMenu = NSMenu()
    private let whileMenu = NSMenu()
    private let displaySleepItem = NSMenuItem(title: "Allow display to sleep", action: #selector(toggleDisplaySleep), keyEquivalent: "")
    private let batteryMenu = NSMenu()
    private let hotkeyItem = NSMenuItem(title: "Keyboard shortcut \(HotKey.description)", action: #selector(toggleHotkey), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")

    private let durations: [(String, TimeInterval)] = [
        ("5 minutes", 5 * 60), ("15 minutes", 15 * 60), ("30 minutes", 30 * 60),
        ("1 hour", 3600), ("2 hours", 2 * 3600), ("5 hours", 5 * 3600),
    ]
    private let batteryStops = [0, 10, 20, 30, 50]

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A stable identity lets macOS and menu bar managers remember its position.
        statusItem.autosaveName = "sniffing"
        statusItem.menu = buildMenu()

        // The system setting is the source of truth: adopt it, and keep following it
        // so changes made from the CLI or another tool show up here too.
        sync()
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        observePowerSource()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
        applyHotkeySetting()
    }

    func applicationWillTerminate(_ note: Notification) {
        if active { _ = Controller.turnOff(prompt: .dialog) }
        releaseAssertion()
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for item in [stateItem, detailItem, blockedItem] { item.isEnabled = false }
        menu.addItem(stateItem)
        menu.addItem(detailItem)
        menu.addItem(blockedItem)
        menu.addItem(.separator())

        toggleItem.target = self
        menu.addItem(toggleItem)

        for (title, seconds) in durations {
            let item = NSMenuItem(title: title, action: #selector(startTimed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            forMenu.addItem(item)
        }
        let forItem = NSMenuItem(title: "Stay awake for", action: nil, keyEquivalent: "")
        forItem.submenu = forMenu
        menu.addItem(forItem)

        whileMenu.delegate = self
        let whileItem = NSMenuItem(title: "Stay awake while running", action: nil, keyEquivalent: "")
        whileItem.submenu = whileMenu
        menu.addItem(whileItem)
        menu.addItem(.separator())

        let settings = NSMenu()
        displaySleepItem.target = self
        settings.addItem(displaySleepItem)
        for stop in batteryStops {
            let item = NSMenuItem(title: stop == 0 ? "Off" : "Below \(stop)%", action: #selector(setBatteryStop(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = stop
            batteryMenu.addItem(item)
        }
        let batteryItem = NSMenuItem(title: "End session on battery", action: nil, keyEquivalent: "")
        batteryItem.submenu = batteryMenu
        settings.addItem(batteryItem)
        hotkeyItem.target = self
        settings.addItem(hotkeyItem)
        loginItem.target = self
        settings.addItem(loginItem)
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit sniffing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === whileMenu {
            rebuildWhileMenu()
            return
        }
        sync()
        let settings = Store.settings
        displaySleepItem.state = settings.allowDisplaySleep ? .on : .off
        for item in batteryMenu.items {
            item.state = (item.representedObject as? Int) == settings.batteryStopPercent ? .on : .off
        }
        hotkeyItem.state = settings.hotkeyEnabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render(State.current) }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        countdown?.invalidate()
        countdown = nil
    }

    private func rebuildWhileMenu() {
        whileMenu.removeAllItems()
        let configured = Store.settings.triggerApps
        var apps = Dictionary(uniqueKeysWithValues: configured.map { ($0, Apps.name(for: $0)) })
        for app in Apps.runningRegular() where app.id != Launcher.bundleID { apps[app.id] = app.name }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No apps running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            whileMenu.addItem(none)
        }
        for (id, name) in apps.sorted(by: { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }) {
            let item = NSMenuItem(title: name, action: #selector(toggleTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = configured.contains(id) ? .on : .off
            whileMenu.addItem(item)
        }
    }

    // MARK: Actions

    @objc private func toggle() {
        if active {
            if !Controller.turnOff(prompt: .dialog) { showLidError() }
        } else {
            if !Controller.turnOn(until: nil, prompt: .dialog) { showLidError() }
        }
        sync()
    }

    @objc private func startTimed(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        if !Controller.turnOn(until: Date().addingTimeInterval(seconds), prompt: .dialog) { showLidError() }
        sync()
    }

    @objc private func toggleTrigger(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var settings = Store.settings
        if let index = settings.triggerApps.firstIndex(of: id) {
            settings.triggerApps.remove(at: index)
        } else {
            settings.triggerApps.append(id)
        }
        Store.settings = settings
        sync()
    }

    @objc private func toggleDisplaySleep() {
        var settings = Store.settings
        settings.allowDisplaySleep.toggle()
        Store.settings = settings
        sync()
    }

    @objc private func setBatteryStop(_ sender: NSMenuItem) {
        guard let stop = sender.representedObject as? Int else { return }
        var settings = Store.settings
        settings.batteryStopPercent = stop
        Store.settings = settings
    }

    @objc private func toggleHotkey() {
        var settings = Store.settings
        settings.hotkeyEnabled.toggle()
        Store.settings = settings
        applyHotkeySetting()
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

    // MARK: State

    /// Bring the assertion, session and UI in line with the system's lid-sleep setting,
    /// applying any automatic transition the engine calls for.
    private func sync() {
        let settings = Store.settings
        let session = Store.session
        let snapshot = Snapshot(lidDisabled: Lid.isDisabled, now: Date(), onCharger: Power.onCharger,
                                batteryPercent: Power.batteryPercent, runningApps: Apps.runningBundleIDs())
        let (action, newSession) = Engine.decide(snapshot, session: session, settings: settings)
        var lidDisabled = snapshot.lidDisabled
        switch action {
        case .none:
            break
        case .turnOff(let reason):
            if Lid.set(disabled: false, prompt: .none) {
                lidDisabled = false
                blocked = nil
            } else {
                blocked = "Couldn't end session (\(reason)): needs the sudoers rule"
            }
        case .turnOn(let app):
            if Lid.set(disabled: true, prompt: .none) {
                lidDisabled = true
                blocked = nil
            } else {
                blocked = "Couldn't start session for \(Apps.name(for: app)): needs the sudoers rule"
            }
        }
        if newSession != session { Store.session = newSession }

        if lidDisabled {
            holdAssertion(allowDisplaySleep: settings.allowDisplaySleep)
        } else {
            releaseAssertion()
        }
        if !lidDisabled && !active { blocked = nil }
        active = lidDisabled
        applyHotkeySetting()
        render(State(active: lidDisabled, onCharger: snapshot.onCharger, batteryPercent: snapshot.batteryPercent,
                     session: Store.session, now: snapshot.now))
    }

    private func holdAssertion(allowDisplaySleep: Bool) {
        if assertion != 0 && assertionAllowsDisplaySleep != allowDisplaySleep { releaseAssertion() }
        guard assertion == 0 else { return }
        let type = allowDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "sniffing: stay awake requested" as CFString, &id)
        if result == kIOReturnSuccess {
            assertion = id
            assertionAllowsDisplaySleep = allowDisplaySleep
        }
    }

    private func releaseAssertion() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    private func render(_ state: State) {
        let symbol = state.active ? "eye" : "eye.slash"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.summary)
        statusItem.button?.appearsDisabled = state.active && !state.effective
        statusItem.button?.toolTip = [state.summary, state.detail].compactMap { $0 }.joined(separator: ". ")
        stateItem.title = state.summary
        detailItem.title = state.detail ?? ""
        detailItem.isHidden = state.detail == nil
        blockedItem.title = blocked ?? ""
        blockedItem.isHidden = blocked == nil
        toggleItem.state = state.active ? .on : .off
    }

    private func applyHotkeySetting() {
        let wanted = Store.settings.hotkeyEnabled
        if wanted && hotKey == nil {
            hotKey = HotKey { [weak self] in self?.toggle() }
        } else if !wanted, let existing = hotKey {
            existing.invalidate()
            hotKey = nil
        }
    }

    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let app = Unmanaged<MenuBarApp>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { app.sync() }
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
}
