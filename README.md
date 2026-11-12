# Drain

Drain is a small macOS menu bar app that replaces the system battery menu. It shows the time left on battery, and under it a bar with one colored slice for each app that is using noticeable power. Each slice is labeled with how many minutes of battery you would get back by quitting that app.

## Using it

- Click the menu bar item to open the menu.
- Drag a slice out of the menu to quit that app. The request is the same one Cmd-Q sends, so the app shuts down normally and can ask to save. If the app refuses Apple events from Drain, it falls back to the system terminate request.
- The Low Power toggle in the menu switches macOS Low Power Mode.
- Hold Option while the menu is open to turn the last item into "Quit Drain".
- On first launch Drain registers itself as a login item once. If you turn that off in System Settings > General > Login Items, it stays off.

Plugged in, the headline is how long the battery would last if you unplugged now, and the minutes per slice are measured against that.

The line under the power source says what the charger is doing: "Charging at 38 W · Full in 1:20" with the rate going into the battery, "Holding at 80%" while macOS keeps the charge below full (Optimized Battery Charging, or a charge limit), and "Not Charging · Draining at 21 W" when the Mac is plugged in but the battery is still supplying power. While macOS is holding the charge, the menu has **Charge to Full Now**. It lifts the pause or limit for this charge only, as the same item in macOS's own battery menu does, and changes nothing in Battery settings; the line then reads "Charging to Full at 38 W · 0:49 left".

## Options

Under "Settings" in the menu. All three are off until you turn them on.

- **Show Time in Menu Bar** puts a time (for example 3:40) beside the icon: the time left while on battery, the time until full while charging. Plugged in and not charging, or with no estimate yet, the icon is alone.
- **Never Suggest Quitting** is a list of apps Drain should leave alone: no slice, not in the quit list, never named in a warning. Their power still counts in the Mac's total. Check an app to ignore it, choose it again to bring it back; ignored apps that aren't running stay listed. Stored by bundle identifier.
- **Warn About Power-Hungry Apps** posts one notification when a single app has used at least 30% of the Mac's power and at least 3 W, with at least 20 minutes to be won back, continuously for 5 minutes on battery. The same app is not mentioned again for 4 hours, plugging in starts the 5 minutes over, and nothing is posted while Drain's menu is open. macOS is asked for notification permission when you turn this on, not before; if you decline, the option stays off. It needs the app bundle: a bare binary run from `.build/` never posts.

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

The time until full is macOS's own estimate. In the first minute of a charge, when macOS has none, and when charging toward a charge limit below 100%, Drain works it out from the rate going into the battery: constant up to 80%, tapering above it. That figure is rounded to 5 minutes.

## Caveats

- The coalition energy counters come from a private kernel interface (`coalition_info_resource_usage`, looked up at runtime). It is undocumented and may change or disappear in a future macOS release; the per-process fallback is less accurate. The IORegistry battery keys are likewise not a public contract.
- Reading whether macOS is holding the charge, and "Charge to Full Now", use the private `PowerUI` framework (`PowerUISmartChargeClient`, looked up at runtime). If it changes or goes away, the line falls back to "Not Charging" and the menu item does not appear.
- Switching Low Power Mode needs root. The first time you use the toggle, macOS asks for your administrator password and Drain installs a sudoers rule at `/etc/sudoers.d/drain-lowpowermode`. The rule is for your user only and allows exactly two commands, `pmset -a lowpowermode 0` and `pmset -a lowpowermode 1`, without a password. To remove it:

      sudo rm /etc/sudoers.d/drain-lowpowermode
