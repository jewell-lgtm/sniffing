# sniffing

Menu bar toggle that keeps the Mac awake, including with the lid closed, while it is on charger.

One click does two things: holds a power assertion against idle sleep, and runs
`pmset -c disablesleep 1`. Toggling off, or quitting, reverses both. On launch it
resets lid sleep in case a previous session died with it disabled.

## Build and install

    ./build.sh
    open ~/Applications/sniffing.app

## Silent lid toggle

`pmset disablesleep` needs root. Without the rule below macOS shows an admin
password prompt each time you toggle. To make it silent:

    sudo visudo -f /etc/sudoers.d/pmset

    matthew.jewell ALL=(root) NOPASSWD: /usr/bin/pmset -c disablesleep 1, /usr/bin/pmset -c disablesleep 0

## Notes

- `-c` scopes the lid override to charger power. On battery the lid sleeps as normal, so an unplugged laptop can't cook in a bag.
- Check state from a terminal with `pmset -g | grep SleepDisabled`; the line only appears when it is set to 1.
