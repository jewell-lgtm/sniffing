import Testing

@Suite("sniffing CLI")
struct CLITests {
    @Test("status reports normal sleep and reads without escalating")
    func statusOff() throws {
        let h = try Harness(lidDisabled: false)
        let r = try h.run("status")
        #expect(r.status == 0)
        #expect(r.stdout.contains("Lid closed: sleeps\n"))
        #expect(r.stdout.contains("stay awake: off"))
        #expect(try h.calls == ["pmset -g"])
    }

    @Test("status reflects a lid override set outside the app")
    func statusOn() throws {
        let h = try Harness(lidDisabled: true)
        let r = try h.run("status")
        #expect(r.status == 0)
        #expect(r.stdout.contains("stay awake: on"))
        let expected = Harness.machineOnCharger ? "Lid closed: stays awake" : "Lid closed: sleeps (on battery)"
        #expect(r.stdout.contains(expected))
    }

    @Test("status reports the machine's real power source")
    func statusPowerSource() throws {
        let h = try Harness()
        let r = try h.run("status")
        let expected = Harness.machineOnCharger ? "power source: charger" : "power source: battery"
        #expect(r.stdout.contains(expected))
    }

    @Test("on disables lid sleep on charger power via passwordless sudo")
    func on() throws {
        let h = try Harness()
        let r = try h.run("on")
        #expect(r.status == 0)
        #expect(try h.lidDisabled)
        #expect(r.stdout.contains("stay awake: on"))
        #expect(try h.calls.contains("sudo -n \(h.fakePmset) -c disablesleep 1"))
    }

    @Test("off restores lid sleep")
    func off() throws {
        let h = try Harness(lidDisabled: true)
        let r = try h.run("off")
        #expect(r.status == 0)
        #expect(try !h.lidDisabled)
        #expect(r.stdout.contains("stay awake: off"))
        #expect(try h.calls.contains("sudo -n \(h.fakePmset) -c disablesleep 0"))
    }

    @Test("toggle flips the setting each time")
    func toggle() throws {
        let h = try Harness()
        try h.run("toggle")
        #expect(try h.lidDisabled)
        try h.run("toggle")
        #expect(try !h.lidDisabled)
    }

    @Test("on and off are idempotent")
    func idempotent() throws {
        let h = try Harness(lidDisabled: true)
        #expect(try h.run("on").status == 0)
        #expect(try h.lidDisabled)
        let off = try Harness(lidDisabled: false)
        #expect(try off.run("off").status == 0)
        #expect(try !off.lidDisabled)
    }

    @Test("without a sudoers rule and without a terminal, the admin dialog is used, never an echoing prompt")
    func fallsBackToDialogWhenNoTTY() throws {
        let h = try Harness(denyPasswordlessSudo: true)
        let r = try h.run("on")
        #expect(r.status == 0)
        #expect(try h.lidDisabled)
        let calls = try h.calls
        #expect(calls.contains("sudo -n \(h.fakePmset) -c disablesleep 1"))
        #expect(calls.contains { $0.hasPrefix("osascript -e do shell script") })
        #expect(!calls.contains("sudo \(h.fakePmset) -c disablesleep 1"), "interactive sudo must not run without a TTY")
    }

    @Test("from a terminal without a sudoers rule, sudo prompts in the caller's process group so the password is not echoed")
    func interactiveSudoSharesProcessGroup() throws {
        let h = try Harness(denyPasswordlessSudo: true)
        let r = try h.runFromTerminal("on")
        #expect(r.status == 0)
        #expect(try h.lidDisabled)
        let calls = try h.calls
        #expect(calls.contains("sudo \(h.fakePmset) -c disablesleep 1"))
        #expect(!calls.contains { $0.hasPrefix("osascript") }, "a terminal user gets a terminal prompt, not a dialog")
        let pgids = try #require(calls.first { $0.hasPrefix("pgid ") })
        let parts = pgids.split(separator: " ").dropFirst().map { $0.split(separator: "=").last.map(String.init) ?? "" }
        #expect(parts.count == 2 && parts[0] == parts[1], "sudo ran in \(pgids)")
    }

    @Test("when escalation fails the setting is untouched and the exit code says so")
    func escalationDenied() throws {
        let h = try Harness(denySudo: true)
        // The dialog path is a separate fake; make it fail too so nothing can succeed.
        try "#!/bin/sh\nexit 1\n".write(to: h.dir.appendingPathComponent("osascript"), atomically: true, encoding: .utf8)
        let r = try h.run("on")
        #expect(r.status == 1)
        #expect(try !h.lidDisabled)
        #expect(r.stdout.isEmpty)
    }

    @Test("unknown commands exit 2 with usage on stderr")
    func unknown() throws {
        let h = try Harness()
        let r = try h.run("bogus")
        #expect(r.status == 2)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.contains("unknown command 'bogus'"))
        #expect(r.stderr.contains("usage: sniffing"))
        #expect(try h.calls.isEmpty, "a bad command must not touch the system")
    }

    @Test("on with a duration records when the session ends and says so")
    func onTimed() throws {
        let h = try Harness()
        let r = try h.run("on", "30m")
        #expect(r.status == 0)
        #expect(try h.lidDisabled)
        #expect(r.stdout.contains("Ends in 30 min ("))
        #expect(try h.stateJSON.contains("\"until\""))
        let again = try h.run("status")
        #expect(again.stdout.contains("Ends in 30 min ("))
    }

    @Test("on without a duration is open-ended")
    func onIndefinite() throws {
        let h = try Harness()
        let r = try h.run("on")
        #expect(!r.stdout.contains("Ends in"))
        #expect(try !h.stateJSON.contains("\"until\""))
    }

    @Test("bad durations are rejected before anything is changed")
    func badDuration() throws {
        let h = try Harness()
        for bad in ["90x", "0", "-5", "h", "later"] {
            let r = try h.run("on", bad)
            #expect(r.status == 2, "\(bad)")
            #expect(r.stderr.contains("bad duration '\(bad)'"))
        }
        #expect(try !h.lidDisabled)
        #expect(try h.calls.isEmpty)
    }

    @Test("off clears the session")
    func offClearsSession() throws {
        let h = try Harness()
        try h.run("on", "2h")
        try h.run("off")
        #expect(try !h.stateJSON.contains("\"until\""))
        #expect(!(try h.run("status")).stdout.contains("Ends in"))
    }

    @Test("status reports battery when the machine has one")
    func statusBattery() throws {
        let h = try Harness(batteryPercent: 42)
        #expect(try h.run("status").stdout.contains("battery: 42%"))
    }

    @Test("config shows defaults, and each setting round-trips")
    func config() throws {
        let h = try Harness()
        let defaults = try h.run("config")
        #expect(defaults.status == 0)
        #expect(defaults.stdout.contains("display-sleep: off"))
        #expect(defaults.stdout.contains("battery-stop: 20%"))
        #expect(defaults.stdout.contains("hotkey: on"))

        #expect(try h.run("config", "display-sleep", "on").stdout.contains("display-sleep: on"))
        #expect(try h.run("config", "battery-stop", "35").stdout.contains("battery-stop: 35%"))
        #expect(try h.run("config", "battery-stop", "off").stdout.contains("battery-stop: off"))
        #expect(try h.run("config", "hotkey", "off").stdout.contains("hotkey: off"))
        let after = try h.run("config")
        #expect(after.stdout.contains("display-sleep: on"))
        #expect(after.stdout.contains("hotkey: off"))
    }

    @Test("config rejects bad values")
    func configBad() throws {
        let h = try Harness()
        #expect(try h.run("config", "display-sleep", "maybe").status == 2)
        #expect(try h.run("config", "battery-stop", "150").status == 2)
        #expect(try h.run("config", "battery-stop", "0").status == 2)
        #expect(try h.run("config", "nonsense").status == 2)
        #expect(try h.run("config").stdout.contains("battery-stop: 20%"), "a rejected value must not be stored")
    }

    @Test("trigger apps can be added by name or bundle id, listed and removed")
    func triggers() throws {
        let h = try Harness()
        #expect(try h.run("trigger", "list").stdout.contains("no trigger apps"))
        let byName = try h.run("trigger", "add", "TextEdit")
        #expect(byName.status == 0)
        #expect(byName.stdout.contains("(com.apple.TextEdit)"))
        let byID = try h.run("trigger", "add", "com.apple.finder")
        #expect(byID.status == 0)
        #expect(byID.stdout.contains("Finder"))
        let list = try h.run("trigger", "list").stdout
        #expect(list.contains("TextEdit (com.apple.TextEdit)"))
        #expect(list.contains("Finder (com.apple.finder)"))
        #expect(try h.run("trigger", "add", "TextEdit").status == 0, "adding twice is fine")
        let lines = try h.run("trigger", "list").stdout.split(separator: "\n").filter { $0.hasPrefix("TextEdit (") }
        #expect(lines.count == 1, "but not stored twice")

        #expect(try h.run("trigger", "remove", "TextEdit").status == 0)
        #expect(!(try h.run("trigger", "list")).stdout.contains("TextEdit"))
        #expect(try h.run("trigger", "remove", "TextEdit").status == 2)
        #expect(try h.run("trigger", "add", "NoSuchAppAnywhere").status == 2)
    }

    @Test("help exits 0")
    func help() throws {
        let h = try Harness()
        for flag in ["--help", "-h", "help"] {
            let r = try h.run(flag)
            #expect(r.status == 0)
            #expect(r.stdout.contains("usage: sniffing"))
        }
    }
}
