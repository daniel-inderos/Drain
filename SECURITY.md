# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through GitHub: on the repository page, go to **Security > Report a vulnerability**. Include the macOS version, what you found, and steps to reproduce it.

Only the latest commit on `main` is supported.

## What Drain does with privileges

Drain runs as an ordinary user process with no network access, and it collects and sends nothing. Three things are worth knowing when you review it:

- **A sudoers rule.** Switching Low Power Mode needs root. The first time you use the toggle, macOS asks for your administrator password and Drain installs `/etc/sudoers.d/drain-lowpowermode`, which lets your user run exactly `/usr/bin/pmset -a lowpowermode 0` and `/usr/bin/pmset -a lowpowermode 1` without a password. The file is checked with `visudo`, owned by root with mode 0440, and moved into place atomically. The code is `LowPowerMode` in `Sources/Drain/Sampling.swift`. Remove the rule with `sudo rm /etc/sudoers.d/drain-lowpowermode`.
- **Quitting other apps.** Dragging a slice out of the menu sends that app the same quit Apple event Cmd-Q does, falling back to the system terminate request. Drain never force-quits.
- **Private interfaces.** Per-app energy comes from `coalition_info_resource_usage` and the charge hold from the `PowerUI` framework, both looked up at runtime and read-only apart from "Charge to Full Now".

A report is in scope if it shows Drain doing more with these than described here, for example a way to widen the sudoers rule or to run something else as root.
