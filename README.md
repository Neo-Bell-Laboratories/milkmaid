# milkmaid

A macOS menu-bar battery indicator shaped like a cat's milk bowl. Current release: **v0.3**. The milk level tracks
battery charge with a slow, subtle ripple. The menu shows the charge percentage, charging state, and the
operating system's estimated battery life or time until full while charging. See
[CHANGELOG.md](CHANGELOG.md) for release notes.

## Build and run

Requires macOS 13 or newer and Xcode Command Line Tools.

```sh
make build
make run
```

The app is built for Apple silicon and runs as a menu-bar accessory without a Dock icon.
Battery status and energy mode refresh every 30 seconds; the milk surface animation is independent of
battery polling. The Energy Mode submenu offers Balanced, Performance, and Battery Saver for the
current power source. macOS may ask for administrator authorization when a mode is changed. Performance
is disabled when the current Mac or power source does not support High Power Mode.
