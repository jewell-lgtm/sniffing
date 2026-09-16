import Foundation

/// Everything the engine needs to know about the machine right now.
struct Snapshot {
    var lidDisabled: Bool
    var now: Date
    var onCharger: Bool
    var batteryPercent: Int?
    var runningApps: Set<String>
}

enum Action: Equatable {
    case none
    case turnOff(reason: String)
    case turnOn(app: String)
}

/// Pure rules for when a session should start or end on its own. No I/O.
enum Engine {
    static func decide(_ s: Snapshot, session: Session, settings: Settings) -> (Action, Session) {
        var session = session
        session.dismissedApps = session.dismissedApps.intersection(s.runningApps)
        if s.onCharger { session.batteryCutoff = false }
        let runningTriggers = Set(settings.triggerApps).intersection(s.runningApps)

        guard s.lidDisabled else {
            session.until = nil
            session.startedByApp = nil
            if !session.batteryCutoff,
               let app = runningTriggers.subtracting(session.dismissedApps).sorted().first {
                session.startedByApp = app
                return (.turnOn(app: app), session)
            }
            return (.none, session)
        }

        if let until = session.until, s.now >= until {
            session.until = nil
            session.startedByApp = nil
            return (.turnOff(reason: "timer ended"), session)
        }
        if !s.onCharger, settings.batteryStopPercent > 0,
           let pct = s.batteryPercent, pct <= settings.batteryStopPercent {
            session.until = nil
            session.startedByApp = nil
            session.batteryCutoff = true
            return (.turnOff(reason: "battery at \(pct)%"), session)
        }
        if let app = session.startedByApp, !s.runningApps.contains(app) {
            session.startedByApp = nil
            return (.turnOff(reason: "\(Apps.name(for: app)) quit"), session)
        }
        return (.none, session)
    }
}
