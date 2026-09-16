import Foundation
import Testing
@testable import sniffing

@Suite("session engine")
struct EngineTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func snapshot(lid: Bool = true, charger: Bool = true, battery: Int? = 80, running: Set<String> = []) -> Snapshot {
        Snapshot(lidDisabled: lid, now: now, onCharger: charger, batteryPercent: battery, runningApps: running)
    }

    @Test("nothing happens while an open-ended session runs on charger")
    func steady() {
        let (action, session) = Engine.decide(snapshot(), session: .none, settings: Settings())
        #expect(action == .none)
        #expect(session == .none)
    }

    @Test("a timed session ends at its deadline and not before")
    func timer() {
        var session = Session()
        session.until = now.addingTimeInterval(60)
        #expect(Engine.decide(snapshot(), session: session, settings: Settings()).0 == .none)
        let late = Snapshot(lidDisabled: true, now: now.addingTimeInterval(60), onCharger: true, batteryPercent: 80, runningApps: [])
        let (action, after) = Engine.decide(late, session: session, settings: Settings())
        #expect(action == .turnOff(reason: "timer ended"))
        #expect(after.until == nil)
    }

    @Test("low battery ends the session only when unplugged, and blocks restarts until plugged in")
    func battery() {
        var settings = Settings()
        settings.batteryStopPercent = 20
        settings.triggerApps = ["com.example.app"]
        #expect(Engine.decide(snapshot(charger: true, battery: 5), session: .none, settings: settings).0 == .none)

        let (action, cut) = Engine.decide(snapshot(charger: false, battery: 20), session: .none, settings: settings)
        #expect(action == .turnOff(reason: "battery at 20%"))
        #expect(cut.batteryCutoff)

        let stillLow = Engine.decide(snapshot(lid: false, charger: false, battery: 15, running: ["com.example.app"]), session: cut, settings: settings)
        #expect(stillLow.0 == .none, "a trigger app must not restart the session on low battery")

        let plugged = Engine.decide(snapshot(lid: false, charger: true, battery: 15, running: ["com.example.app"]), session: cut, settings: settings)
        #expect(plugged.0 == .turnOn(app: "com.example.app"))
        #expect(!plugged.1.batteryCutoff)
    }

    @Test("battery check off means the session survives a flat battery")
    func batteryOff() {
        var settings = Settings()
        settings.batteryStopPercent = 0
        #expect(Engine.decide(snapshot(charger: false, battery: 3), session: .none, settings: settings).0 == .none)
    }

    @Test("a trigger app starts a session when running and ends it when it quits")
    func triggerLifecycle() {
        var settings = Settings()
        settings.triggerApps = ["com.example.app"]
        let (start, started) = Engine.decide(snapshot(lid: false, running: ["com.example.app", "com.apple.finder"]), session: .none, settings: settings)
        #expect(start == .turnOn(app: "com.example.app"))
        #expect(started.startedByApp == "com.example.app")

        #expect(Engine.decide(snapshot(lid: true, running: ["com.example.app"]), session: started, settings: settings).0 == .none)

        let (stop, stopped) = Engine.decide(snapshot(lid: true, running: ["com.apple.finder"]), session: started, settings: settings)
        #expect(stop == .turnOff(reason: "com.example.app quit"))
        #expect(stopped.startedByApp == nil)
    }

    @Test("a session the user started by hand is not ended by a trigger app quitting")
    func manualOutlivesTrigger() {
        var settings = Settings()
        settings.triggerApps = ["com.example.app"]
        let manual = Session()
        #expect(Engine.decide(snapshot(lid: true, running: []), session: manual, settings: settings).0 == .none)
    }

    @Test("turning off under a running trigger app dismisses it until it relaunches")
    func dismissed() {
        var settings = Settings()
        settings.triggerApps = ["com.example.app"]
        var session = Session()
        session.dismissedApps = ["com.example.app"]
        #expect(Engine.decide(snapshot(lid: false, running: ["com.example.app"]), session: session, settings: settings).0 == .none)

        let (_, afterQuit) = Engine.decide(snapshot(lid: false, running: []), session: session, settings: settings)
        #expect(afterQuit.dismissedApps.isEmpty)
        #expect(Engine.decide(snapshot(lid: false, running: ["com.example.app"]), session: afterQuit, settings: settings).0 == .turnOn(app: "com.example.app"))
    }

    @Test("a stale timer is dropped when the lid override is found off")
    func staleTimer() {
        var session = Session()
        session.until = now.addingTimeInterval(600)
        let (action, after) = Engine.decide(snapshot(lid: false), session: session, settings: Settings())
        #expect(action == .none)
        #expect(after.until == nil)
    }
}

@Suite("durations")
struct DurationTests {
    @Test("parses minutes, hours and combinations", arguments: [
        ("30m", 1800.0), ("2h", 7200.0), ("1h30m", 5400.0), ("45", 2700.0), ("1H", 3600.0), ("1h 5m", 3900.0),
    ])
    func parses(text: String, seconds: Double) {
        #expect(Duration.parse(text) == seconds)
    }

    @Test("rejects nonsense", arguments: ["", "0", "0m", "-5", "h", "5s", "later", "1h30"])
    func rejects(text: String) {
        #expect(Duration.parse(text) == nil)
    }

    @Test("describes remaining time the way a person would say it")
    func describes() {
        #expect(Duration.describe(45) == "45 s")
        #expect(Duration.describe(1800) == "30 min")
        #expect(Duration.describe(7200) == "2 h")
        #expect(Duration.describe(5400) == "1 h 30 min")
        #expect(Duration.describe(1798.6) == "30 min", "a second or two into a 30 minute session is still 30 minutes")
        #expect(Duration.describe(89) == "1 min")
        #expect(Duration.describe(91) == "2 min")
    }
}
