# sniffing

A tiny macOS menu bar app and CLI that keeps your Mac awake with the lid closed.

Closing the lid always puts a MacBook to sleep, and the usual keep-awake apps
(KeepingYouAwake, Caffeine, `caffeinate`) can't stop it: they only block *idle*
sleep. Lid sleep is a separate trigger that needs a root-only power setting.
sniffing flips that setting and the idle-sleep assertion together behind one
toggle, and reverses both when you turn it off or quit.

The override only applies while the Mac is on a charger. On battery the lid
sleeps as normal, so an unplugged laptop can't cook in a bag.

## Requirements

- macOS 13 or later, Apple silicon or Intel.
- To build: Swift 6 toolchain. Xcode Command Line Tools are enough.
- An admin account, since changing lid sleep needs root.

## Install

    git clone https://github.com/jewell-lgtm/sniffing
    cd sniffing
    ./build.sh
    open ~/Applications/sniffing.app

`build.sh` runs in four steps: compile a release build, run the whole test
suite, wrap the binary as `~/Applications/sniffing.app`, and symlink it to
`~/.local/bin/sniffing`. A failing test stops the build before anything is
installed. The same executable serves both modes. The app is ad-hoc signed,
which is fine for a local tool.

## Menu bar mode

Launch `sniffing.app`. An eye appears in the menu bar: open when the Mac will
stay awake, slashed when it will sleep. The menu shows:

- **What closing the lid will do right now.** "Stays awake", "sleeps", or
  "sleeps (on battery)" when the override is armed but not in effect because
  you're unplugged. The icon dims in that last case. Under it, when the session
  will end on its own: a live countdown for a timed session, or the app it is
  waiting on.
- **Stay awake.** The open-ended toggle.
- **Stay awake for.** 5 minutes to 5 hours. The session ends on its own.
- **Stay awake while running.** Pick from the apps currently running. While any
  chosen app runs the Mac stays awake, and when the last one quits it ends.
  Turning the session off by hand under a running trigger app dismisses that
  app until it relaunches, so the toggle always wins.
- **Settings.** Allow display to sleep, end the session on battery below a
  threshold, the global keyboard shortcut, and launch at login.
- **Quit.** Quitting restores normal sleep if it was on.

The keyboard shortcut is ⌃⌥⌘S and toggles the session from anywhere. It uses
the Carbon hotkey API, so it needs no accessibility permission.

The first time you toggle it, macOS asks for your password. See
[Silent toggling](#silent-toggling) to skip that. Automatic changes such as a
timer ending or a trigger app quitting never prompt: they only work through
the sudoers rule. Without it the app still drops its own idle-sleep hold, shows
in the menu why the lid override is still on, and waits for you.

## CLI mode

    sniffing on              # keep awake, lid closed included, while on charger
    sniffing on 30m          # ...and end after 30 minutes (also 2h, 1h30m, or minutes)
    sniffing off             # restore normal sleep
    sniffing toggle
    sniffing status          # what closing the lid will do right now, and why it will end

    sniffing trigger list
    sniffing trigger add Docker        # by name or bundle identifier
    sniffing trigger remove Docker

    sniffing config                    # show settings
    sniffing config display-sleep on|off
    sniffing config battery-stop 20    # percent, or off
    sniffing config hotkey on|off

With no arguments the binary runs as the menu bar app instead. Timers and
triggers are enforced by the menu bar app, so `sniffing on <duration>` launches
it if it isn't already running.

When the CLI needs your password it asks in the terminal via `sudo`, in your
shell's process group so the prompt can turn echo off. If stdin isn't a
terminal, for example when run from a script or another tool, it falls back to
the macOS administrator dialog rather than risk echoing a password.

## How it tracks state

The system setting is the source of truth, not the app's memory of what it
did. On launch the menu bar app adopts whatever `pmset -g` reports, re-reads it
every five seconds and whenever the menu opens, and follows changes made from
the CLI, a terminal, or anything else. It also listens for power source changes
so the battery hint is live.

Settings and the current session (its deadline, or the app it is waiting on)
live in one JSON file under `~/Library/Application Support/sniffing/`, read
fresh on every access so the CLI and the app always agree.

Under the hood:

- Lid sleep: `pmset -c disablesleep 1` / `0`. The `-c` scopes it to charger
  power.
- Idle and display sleep: an `IOPMAssertion` held while active, so the Mac
  also stays awake with the lid open. "Allow display to sleep" switches it to
  a system-sleep-only assertion.
- Power source and battery level: IOKit's power source API and change
  notifications.
- Trigger apps: NSWorkspace launch and quit notifications.
- The rules for when a session starts or ends on its own are one pure
  function, `Engine.decide`, with unit tests.

Check the raw setting from any terminal with `pmset -g | grep SleepDisabled`.
The line only appears when it is set to 1.

## Silent toggling

`pmset disablesleep` needs root. Without the rule below you get a password
prompt on every toggle. To make it silent, run this once as an admin:

    echo "$USER ALL=(root) NOPASSWD: /usr/bin/pmset -c disablesleep 1, /usr/bin/pmset -c disablesleep 0" | sudo tee /etc/sudoers.d/pmset
    sudo chmod 440 /etc/sudoers.d/pmset
    sudo visudo -c -f /etc/sudoers.d/pmset

The rule names your user directly and matches those two exact commands and
nothing else. Check it took effect with:

    sudo -n /usr/bin/pmset -c disablesleep 0 && echo ok

On a managed Mac where admin rights are granted temporarily, the rule outlives
the admin window because it names the user rather than the `admin` group. Ask
your IT team before relying on that; persisting any privilege past a granted
window is the kind of thing endpoint policies exist to catch, however narrow
the grant. Without the rule, `sniffing on` still works whenever you do have
admin, and the setting persists after admin expires. Only changing it needs
root.

## Tests

    swift test

The CLI suite runs the built binary as a subprocess against fake `pmset`,
`sudo` and `osascript` scripts, injected through `SNIFFING_PMSET`,
`SNIFFING_SUDO` and `SNIFFING_OSASCRIPT`, with its own state directory via
`SNIFFING_STATE_DIR` and a fake battery level via `SNIFFING_BATTERY`. Nothing
needs root and the machine's real sleep setting is never touched. The engine
and duration suites are plain in-process unit tests. Assertions are on the CLI's output and exit codes, and on
what the fakes were told to do. One test runs the CLI under a pseudo-terminal
to pin that the interactive `sudo` prompt shares the caller's process group.

The Command Line Tools' Swift Testing macro plugin is occasionally not found on
a cold `swift test`. If you hit that, run `swift build --build-tests` first,
then `swift test --skip-build`.

## Project layout

    Sources/sniffing/Main.swift        picks CLI or menu bar mode from argv
    Sources/sniffing/CLI.swift         on/off/toggle/status/trigger/config
    Sources/sniffing/MenuBarApp.swift  status item, menu, assertion, polling, automatic transitions
    Sources/sniffing/HotKey.swift      global ⌃⌥⌘S via Carbon
    Sources/sniffing/Engine.swift      pure rules for timers, triggers and battery
    Sources/sniffing/Store.swift       settings and session, one shared JSON file
    Sources/sniffing/State.swift       what the lid will do now, and the user-driven transitions
    Sources/sniffing/Tools.swift       pmset, sudo, power source, battery
    Sources/sniffing/Apps.swift        bundle id lookup and running apps
    Sources/sniffing/Duration.swift    30m / 2h / 1h30m parsing and display
    Tests/sniffingTests/               CLI integration tests, engine and duration unit tests
    build.sh                           release build, .app bundle, symlink
    Info.plist                         bundle metadata (LSUIElement: no Dock icon)
