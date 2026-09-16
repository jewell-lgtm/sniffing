import AppKit

/// `sniffing <command>` controls the same system setting and session the menu bar app follows,
/// so the two stay in step.
@MainActor
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "on":
            var until: Date?
            if args.count > 1 {
                guard let seconds = Duration.parse(args[1]) else {
                    return fail("bad duration '\(args[1])'. Use minutes, or forms like 30m, 2h, 1h30m.")
                }
                until = Date().addingTimeInterval(seconds)
            }
            guard Controller.turnOn(until: until, prompt: .terminal) else { return 1 }
            if until != nil { Launcher.ensureMenuBarAppRunning() }
            return report()
        case "off":
            return Controller.turnOff(prompt: .terminal) ? report() : 1
        case "toggle":
            return (Lid.isDisabled ? Controller.turnOff(prompt: .terminal) : Controller.turnOn(until: nil, prompt: .terminal)) ? report() : 1
        case "status":
            return report()
        case "trigger":
            return trigger(Array(args.dropFirst()))
        case "config":
            return config(Array(args.dropFirst()))
        case "-h", "--help", "help":
            print(usage)
            return 0
        default:
            return fail("unknown command '\(args.joined(separator: " "))'")
        }
    }

    private static func report() -> Int32 {
        let state = State.current
        print(state.summary)
        if let detail = state.detail { print(detail) }
        print("power source: \(state.onCharger ? "charger" : "battery")")
        if let pct = state.batteryPercent { print("battery: \(pct)%") }
        print("stay awake: \(state.active ? "on" : "off")")
        return 0
    }

    private static func trigger(_ args: [String]) -> Int32 {
        var settings = Store.settings
        switch args.first {
        case "list", nil:
            if settings.triggerApps.isEmpty { print("no trigger apps") }
            for id in settings.triggerApps { print("\(Apps.name(for: id)) (\(id))") }
            return 0
        case "add" where args.count == 2:
            guard let id = Apps.resolve(args[1]) else { return fail("no installed app matches '\(args[1])'") }
            if !settings.triggerApps.contains(id) { settings.triggerApps.append(id) }
            Store.settings = settings
            print("stay awake while \(Apps.name(for: id)) (\(id)) is running")
            return 0
        case "remove" where args.count == 2:
            let id = Apps.resolve(args[1]) ?? args[1]
            guard settings.triggerApps.contains(id) else { return fail("'\(args[1])' is not a trigger app") }
            settings.triggerApps.removeAll { $0 == id }
            Store.settings = settings
            print("removed \(Apps.name(for: id))")
            return 0
        default:
            return fail("usage: sniffing trigger [list|add <app>|remove <app>]")
        }
    }

    private static func config(_ args: [String]) -> Int32 {
        var settings = Store.settings
        func onOff(_ s: String) -> Bool? { ["on": true, "off": false][s.lowercased()] }
        switch (args.first, args.count) {
        case (nil, _):
            print("display-sleep: \(settings.allowDisplaySleep ? "on" : "off")")
            print("battery-stop: \(settings.batteryStopPercent > 0 ? "\(settings.batteryStopPercent)%" : "off")")
            print("hotkey: \(settings.hotkeyEnabled ? "on (⌃⌥⌘S)" : "off")")
            return 0
        case ("display-sleep", 2):
            guard let v = onOff(args[1]) else { return fail("display-sleep takes on or off") }
            settings.allowDisplaySleep = v
        case ("battery-stop", 2):
            if args[1].lowercased() == "off" {
                settings.batteryStopPercent = 0
            } else if let pct = Int(args[1].trimmingCharacters(in: CharacterSet(charactersIn: "%"))), (1...99).contains(pct) {
                settings.batteryStopPercent = pct
            } else {
                return fail("battery-stop takes a percentage from 1 to 99, or off")
            }
        case ("hotkey", 2):
            guard let v = onOff(args[1]) else { return fail("hotkey takes on or off") }
            settings.hotkeyEnabled = v
        default:
            return fail("usage: sniffing config [display-sleep on|off | battery-stop <percent>|off | hotkey on|off]")
        }
        Store.settings = settings
        return config([])
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("sniffing: \(message)\n\(usage)\n".utf8))
        return 2
    }

    private static let usage = """
    usage: sniffing <command>

    With no command, runs as the menu bar app.
      on [duration]           keep the Mac awake, lid closed included, while on charger;
                              duration like 30m, 2h, 1h30m ends it automatically
      off                     restore normal sleep
      toggle                  flip between the two
      status                  what closing the lid will do right now
      trigger list            apps whose running keeps the Mac awake
      trigger add <app>       add by name or bundle identifier
      trigger remove <app>
      config                  show settings
      config display-sleep on|off
      config battery-stop <percent>|off
      config hotkey on|off    global ⌃⌥⌘S toggle
    """
}

enum Launcher {
    static let bundleID = "dev.mattjewell.sniffing"

    /// Timers and triggers are enforced by the menu bar app, so make sure it is up.
    @MainActor
    static func ensureMenuBarAppRunning() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { return }
        _ = Lid.run("/usr/bin/open", [bundle.path])
        print("menu bar app launched to end the session on time")
    }
}
