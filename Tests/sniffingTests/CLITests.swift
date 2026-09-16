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
