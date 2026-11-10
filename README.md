# Drain

Drain is a small macOS menu bar app that replaces the system battery menu. It shows the time left on battery, and under it a bar with one colored slice for each app that is using noticeable power. Each slice is labeled with how many minutes of battery you would get back by quitting that app.

## Using it

- Click the menu bar item to open the menu.
- Drag a slice out of the menu to quit that app. The request is the same one Cmd-Q sends, so the app shuts down normally and can ask to save. If the app refuses Apple events from Drain, it falls back to the system terminate request.
- The Low Power toggle in the menu switches macOS Low Power Mode.
- Hold Option while the menu is open to turn the last item into "Quit Drain".
- On first launch Drain registers itself as a login item once. If you turn that off in System Settings > General > Login Items, it stays off.

Plugged in, the headline is how long the battery would last if you unplugged now, and the minutes per slice are measured against that.

## Requirements

macOS 15 or later and a Swift 6 toolchain (Xcode or the command line tools). It is a plain Swift package with no dependencies.

## Build and install

    ./build.sh             # builds ./Drain.app
    ./build.sh --install   # also replaces /Applications/Drain.app and relaunches it
    ./build.sh --help

`--install` quits a running Drain, so run it from somewhere other than Drain's own menu if you care about the session. The app bundle's Info.plist lives in `Resources/Info.plist`; the bundle identifier is `local.drain.menubar`, and changing it loses the login item and saved defaults.

### Signing

An ad hoc signature changes with every build, so macOS sees each build as a different app and the login item and any granted permissions are lost. `build.sh` therefore prefers a stable identity:

1. the one named in the `DRAIN_SIGN_IDENTITY` environment variable, if set (`-` means ad hoc);
2. otherwise the first "Apple Development" identity listed by `security find-identity -v -p codesigning`;
3. otherwise, or if signing with that identity fails, ad hoc, with a line saying so.

The script prints which kind of signature it used, never the identity name.

## Debug aids

- `DRAIN_DEBUG=1` makes Drain write debug messages to stderr (run the binary from a terminal to see them).
- `DRAIN_ONLY_QUIT=<bundle id>` makes dragging a slice quit only the app with that bundle identifier; for any other app the slice disappears but nothing is quit. For testing the drag without risking a real app.
- `--open` as a launch argument opens the menu by itself a few seconds after launch.

Example: `DRAIN_DEBUG=1 DRAIN_ONLY_QUIT=com.apple.TextEdit Drain.app/Contents/MacOS/Drain --open`

## How the numbers are made

Per-app energy comes from macOS coalitions, the groups the system puts an app and everything it launches into (helpers, XPC services, GPU work), the way Activity Monitor counts them. Drain reads each coalition's cumulative CPU and GPU energy counters and divides the difference between samples by the elapsed time to get watts. If the coalition call cannot be found, it falls back to per-process energy counters (`proc_pid_rusage`), attributing each process to the outermost `.app` bundle it lives in. Readings are smoothed: they rise quickly and fall slowly so a heavy app shows up fast and does not vanish the moment it pauses.

Whole-machine power draw and the energy left in the battery (capacity times voltage) are read from the battery's IORegistry entry (`AppleSmartBattery`). Percentage, charging state and macOS's own time estimates come from the power sources API.

On battery, the time left is macOS's own estimate scaled by the ratio of the current draw to the draw it would have without a given app, so the headline matches the system's number and each slice shows a proportional change. Plugged in, or when macOS has no estimate, it is the remaining watt-hours divided by the draw. Quitting one app is never assumed to take the machine below a floor of a quarter of its current draw, since the display and system keep running. These are estimates: they assume the draw stays what it is now.

## Caveats

- The coalition energy counters come from a private kernel interface (`coalition_info_resource_usage`, looked up at runtime). It is undocumented and may change or disappear in a future macOS release; the per-process fallback is less accurate. The IORegistry battery keys are likewise not a public contract.
- Switching Low Power Mode needs root. The first time you use the toggle, macOS asks for your administrator password and Drain installs a sudoers rule at `/etc/sudoers.d/drain-lowpowermode`. The rule is for your user only and allows exactly two commands, `pmset -a lowpowermode 0` and `pmset -a lowpowermode 1`, without a password. To remove it:

      sudo rm /etc/sudoers.d/drain-lowpowermode
