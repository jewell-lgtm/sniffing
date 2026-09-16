# sniffing

Menu bar toggle that keeps the Mac awake, including with the lid closed, while it is on charger.

One click does two things: holds a power assertion against idle sleep, and runs
`pmset -c disablesleep 1`. Toggling off, or quitting, reverses both.

The system setting is the source of truth. On launch the app adopts whatever
`pmset -g` reports, re-reads it every five seconds and whenever the menu opens,
and follows changes made from a terminal or another tool. The menu's first line
says what closing the lid will actually do right now, including "sleeps (on
battery)" when the override is armed but not in effect; the icon dims in that
case.

## Build and install

    ./build.sh
    open ~/Applications/sniffing.app

This installs `~/Applications/sniffing.app` and symlinks the binary to
`~/.local/bin/sniffing`, so the same executable serves both modes.

## Two modes

With no arguments it runs as the menu bar app. With a command it acts on the
system setting and exits:

    sniffing on      # keep awake, lid closed included, while on charger
    sniffing off     # restore normal sleep
    sniffing toggle
    sniffing status  # what closing the lid will do right now

The CLI asks for your password in the terminal when it needs one; the menu bar
app uses the macOS admin dialog. Either way the running menu bar app follows
the change within a few seconds.

## Silent lid toggle

`pmset disablesleep` needs root. Without the rule below macOS shows an admin
password prompt each time you toggle. To make it silent:

    sudo visudo -f /etc/sudoers.d/pmset

    matthew.jewell ALL=(root) NOPASSWD: /usr/bin/pmset -c disablesleep 1, /usr/bin/pmset -c disablesleep 0

## Notes

- `-c` scopes the lid override to charger power. On battery the lid sleeps as normal, so an unplugged laptop can't cook in a bag.
- Check state from a terminal with `pmset -g | grep SleepDisabled`; the line only appears when it is set to 1.
