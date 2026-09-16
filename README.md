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

`build.sh` compiles a release build, wraps it as `~/Applications/sniffing.app`
and symlinks the binary to `~/.local/bin/sniffing`. The same executable serves
both modes. The app is ad-hoc signed, which is fine for a local tool.

## Menu bar mode

Launch `sniffing.app`. An eye appears in the menu bar: open when the Mac will
stay awake, slashed when it will sleep. The menu shows:

- **What closing the lid will do right now.** "Stays awake", "sleeps", or
  "sleeps (on battery)" when the override is armed but not in effect because
  you're unplugged. The icon dims in that last case.
- **Stay awake.** The toggle.
- **Launch at login.**
- **Quit.** Quitting restores normal sleep if it was on.

The first time you toggle it, macOS asks for your password. See
[Silent toggling](#silent-toggling) to skip that.

## CLI mode

    sniffing on      # keep awake, lid closed included, while on charger
    sniffing off     # restore normal sleep
    sniffing toggle
    sniffing status  # what closing the lid will do right now

With no arguments the binary runs as the menu bar app instead.

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

Under the hood:

- Lid sleep: `pmset -c disablesleep 1` / `0`. The `-c` scopes it to charger
  power.
- Idle and display sleep: an `IOPMAssertion` held while active, so the Mac
  also stays awake with the lid open.
- Power source: IOKit's power source API and change notifications.

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

The suite runs the built binary as a subprocess against fake `pmset`, `sudo`
and `osascript` scripts, injected through `SNIFFING_PMSET`, `SNIFFING_SUDO` and
`SNIFFING_OSASCRIPT`. Nothing needs root and the machine's real sleep setting
is never touched. Assertions are on the CLI's output and exit codes, and on
what the fakes were told to do. One test runs the CLI under a pseudo-terminal
to pin that the interactive `sudo` prompt shares the caller's process group.

The Command Line Tools' Swift Testing macro plugin is occasionally not found on
a cold `swift test`. If you hit that, run `swift build --build-tests` first,
then `swift test --skip-build`.

## Project layout

    Sources/sniffing/Main.swift        picks CLI or menu bar mode from argv
    Sources/sniffing/CLI.swift         on/off/toggle/status
    Sources/sniffing/MenuBarApp.swift  status item, menu, assertion, polling
    Sources/sniffing/State.swift       pmset, sudo, power source
    Tests/sniffingTests/               CLI integration tests and their harness
    build.sh                           release build, .app bundle, symlink
    Info.plist                         bundle metadata (LSUIElement: no Dock icon)
