# Contributing to Drain

Bug reports and pull requests are welcome.

## Reporting a bug

Open an issue and include:

- your macOS version and Mac model (Apple silicon or Intel, laptop or desktop);
- what you did, what you expected, and what happened instead;
- the output of a debug run, if the bug is about numbers or quitting apps:

      DRAIN_DEBUG=1 Drain.app/Contents/MacOS/Drain --open

Drain reads private macOS interfaces (see "Caveats" in the README), so a new macOS release is the most likely thing to break it. If something stopped working after an update, say which version you updated from and to.

For anything touching the sudoers rule or another security matter, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Building and testing

You need macOS 15 or later and a Swift 6 toolchain. There are no dependencies.

    swift build            # debug build of the bare binary
    swift test             # unit tests
    ./build.sh             # release build of ./Drain.app
    ./build.sh --install   # also replaces /Applications/Drain.app and relaunches it

To try the drag-to-quit gesture without risking a real app, limit it to one bundle identifier:

    DRAIN_DEBUG=1 DRAIN_ONLY_QUIT=com.apple.TextEdit Drain.app/Contents/MacOS/Drain --open

A bare binary run from `.build/` does not register a login item and never posts notifications; use the app bundle to test those.

## Pull requests

- Keep each pull request to one change, and say in the description what you tested and on which macOS version.
- Run `swift test` before you push. The arithmetic and formatting live in `BatteryMath.swift`, `Format.swift` and `HogWatcher.swift` so they can be tested without a battery; new logic of that kind should come with tests.
- Drain has no third-party dependencies. Please keep it that way unless there is a strong reason.
- Any text the user sees should be checked in the running app, in both light and dark menu bars.
- If a change uses a private or undocumented macOS interface, look it up at runtime, fall back cleanly when it is missing, and add it to "Caveats" in the README.
- Changes to the privileged path (`LowPowerMode` in `Sampling.swift`) get extra scrutiny: the rule must stay limited to the two `pmset` commands for the current user.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
