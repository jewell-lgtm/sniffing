import Foundation

/// What the machine will actually do when the lid closes, from the system's own settings,
/// plus the session that explains why.
struct State {
    let active: Bool
    let onCharger: Bool
    let batteryPercent: Int?
    let session: Session
    let now: Date

    /// True when the lid override is both armed and in effect.
    var effective: Bool { active && onCharger }

    var summary: String {
        switch (active, onCharger) {
        case (true, true): return "Lid closed: stays awake"
        case (true, false): return "Lid closed: sleeps (on battery)"
        case (false, _): return "Lid closed: sleeps"
        }
    }

    /// Why the session will end, when it will end on its own.
    var detail: String? {
        guard active else { return nil }
        if let until = session.until {
            let clock = until.formatted(date: .omitted, time: .shortened)
            return "Ends in \(Duration.describe(until.timeIntervalSince(now))) (\(clock))"
        }
        if let app = session.startedByApp {
            return "While \(Apps.name(for: app)) is running"
        }
        return nil
    }

    @MainActor
    static var current: State {
        State(active: Lid.isDisabled, onCharger: Power.onCharger, batteryPercent: Power.batteryPercent,
              session: Store.session, now: Date())
    }
}

/// The user-initiated transitions, shared by the CLI and the menu.
@MainActor
enum Controller {
    static func turnOn(until: Date?, prompt: Lid.Prompt) -> Bool {
        guard Lid.set(disabled: true, prompt: prompt) else { return false }
        Store.session = Session(until: until)
        return true
    }

    static func turnOff(prompt: Lid.Prompt) -> Bool {
        guard Lid.set(disabled: false, prompt: prompt) else { return false }
        var session = Session.none
        session.dismissedApps = Set(Store.settings.triggerApps).intersection(Apps.runningBundleIDs())
        Store.session = session
        return true
    }
}
