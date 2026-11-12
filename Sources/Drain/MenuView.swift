import AppKit
import SwiftUI

/// The custom top of the menu: title, power source, the battery and its status line.
/// Low Power Mode and Battery Settings… are ordinary menu items below it.
struct MenuView: View {
    @ObservedObject var model: DrainModel
    let drag: DragController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Battery").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.state == .noBattery ? "" : "\(model.percent) %")
                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }

            Text("Power Source: \(model.state.onAC ? "Power Adapter" : "Battery")")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.top, 3)

            if let charge = Format.chargeLine(model.state, percent: model.percent, timeToFull: model.timeToFull,
                                                 batteryWatts: model.batteryWatts, policy: model.chargePolicy) {
                Text(charge)
                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.top, 1)
            }

            BatteryPill(model: model, drag: drag)
                .padding(.top, 12)

            StatusRow(model: model, drag: drag)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6).padding(.bottom, 4)
        .frame(width: 300)
    }
}

/// "Time left 3:40 +1:10" on battery; charging status on power.
private struct StatusRow: View {
    @ObservedObject var model: DrainModel
    @ObservedObject var drag: DragController

    var body: some View {
        if let app = model.apps.first(where: { $0.id == drag.hintID }) {
            hint(app)
        } else {
            status
        }
    }

    /// After a click on a slice: what it is and what to do. Gone after a moment.
    private func hint(_ app: AppDrain) -> some View {
        let win = app.hasEstimate && app.gainMinutes >= 0.05 ? Format.gain(app.gainMinutes) : Format.watts(app.watts)
        return HStack(spacing: 0) {
            Text(app.name).lineLimit(1).truncationMode(.tail)
            Text(" · drag out to quit · \(win)")
                .foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .font(.system(size: 13)).monospacedDigit()
        .frame(height: 18)
        .transition(.opacity)
    }

    private var status: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(value).contentTransition(.numericText(value: model.headline ?? 0))
            }
            if let saved {
                Text(saved)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .contentTransition(.numericText(value: model.sessionMinutes))
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
            }
        }
        .font(.system(size: 13)).monospacedDigit()
        .frame(height: 18)
    }

    private var title: String {
        switch model.state {
        case .battery: "Time left"
        case .noBattery: "No battery"
        default: "Time left on battery"
        }
    }

    private var value: String? {
        guard model.state != .noBattery else { return nil }
        return model.headline.map(Format.clock) ?? "Calculating…"
    }

    private var saved: String? {
        model.sessionMinutes >= 0.5 ? "+" + Format.clock(model.sessionMinutes) : nil
    }
}

/// The battery itself: white is what you have, each colored slice is an app
/// eating into it. Grab a slice and pull it out to quit that app.
struct BatteryPill: View {
    @ObservedObject var model: DrainModel
    let drag: DragController

    private let pillWidth: CGFloat = 258
    private let pillHeight: CGFloat = 74

    var body: some View {
        let widths = segmentWidths()
        HStack(alignment: .top, spacing: 4) {
            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    ZStack {
                        Color.white
                        center
                    }
                    .frame(maxWidth: .infinity)

                    ForEach(model.apps) { app in
                        Segment(app: app, width: widths[app.id] ?? 24,
                                lifted: model.draggingID == app.id, drag: drag)
                            .transition(.asymmetric(insertion: .opacity,
                                                    removal: .scale(scale: 0.2).combined(with: .opacity)))
                    }
                }
                .frame(width: pillWidth, height: pillHeight)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                HStack(spacing: 0) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    ForEach(model.apps) { app in
                        let w = widths[app.id] ?? 24
                        // Only when it fits under its own slice, so neighbours never collide.
                        let label = app.costLabel
                        Text(CGFloat(label.count) * 6.4 <= w - 4 ? label : "")
                            .accessibilityHidden(true)   // the slice itself says it
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                            .frame(width: w)
                            .opacity(model.draggingID == app.id ? 0 : 1)
                    }
                }
                .frame(width: pillWidth, height: 12)
            }

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 4, height: 24)
                .padding(.top, (pillHeight - 24) / 2)
        }
    }

    /// Always the time left on battery. Plugged in, that's what you'd get if you
    /// unplugged now, which is what the slices take away from.
    @ViewBuilder private var center: some View {
        if model.state == .noBattery {
            HStack(spacing: 3) {
                Image(systemName: "powerplug.fill").font(.system(size: 14, weight: .bold))
                Text("AC").font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.black)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    if model.state.onAC {
                        Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold))
                    }
                    Text(model.headline.map(Format.clock) ?? "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText(value: model.headline ?? 0))
                }
                if model.state.onAC {
                    Text("if unplugged")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.black.opacity(0.45))
                }
            }
            .monospacedDigit()
            .foregroundStyle(.black)
        }
    }

    /// Slices are sized by their share of the apps' power, with a floor so small
    /// ones stay grabbable. Real gains are minutes against hours, so a strictly
    /// to-scale battery would show hairlines.
    private func segmentWidths() -> [String: CGFloat] {
        let apps = model.apps
        guard !apps.isEmpty else { return [:] }
        let n = CGFloat(apps.count)
        let floor: CGFloat = apps.count >= 5 ? 20 : 26
        let budget = max(floor * n, min(pillWidth * 0.5, n * 64))
        let extra = budget - floor * n
        let sum = apps.reduce(0) { $0 + $1.layoutWatts }
        return Dictionary(apps.map {
            ($0.id, floor + (sum > 0 ? extra * CGFloat($0.layoutWatts / sum) : extra / n))
        }, uniquingKeysWith: { first, _ in first })
    }
}

private struct Segment: View {
    let app: AppDrain
    let width: CGFloat
    let lifted: Bool
    let drag: DragController
    @State private var hovering = false

    var body: some View {
        ZStack {
            app.color.brightness(hovering && !lifted ? 0.07 : 0)
            if width >= 18 {
                Image(nsImage: app.icon)
                    .resizable().interpolation(.high)
                    .frame(width: min(26, width - 4), height: min(26, width - 4))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .scaleEffect(hovering && !lifted ? 1.12 : 1)
            }
        }
        .frame(width: width)
        .overlay(alignment: .leading) { Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1) }
        // Read as one item. No "quit" action here: a custom action inside a menu's
        // hosted view is unverified, and the native list below does that reliably.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.spokenSummary)
        .accessibilityHint(app.spokenGain + (app.spokenGain.isEmpty ? "" : ". ") + "Use Quit an App to Save Power below to quit it.")
        .opacity(lifted ? 0.2 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help("\(app.name) · \(Format.watts(app.watts))")
        .overlay {
            DragCatcher(
                onChange: { drag.changed(app, translation: $0) },
                onEnd: { drag.ended() },
                onClick: { drag.hint(app) })
        }
    }
}

/// Catches the grab on a slice. Menus route mouse events to their own tracking,
/// so this follows the mouse itself until you let go, the same way a slider
/// inside a menu does. That keeps the drag alive outside the menu and keeps the
/// menu open after you drop.
private struct DragCatcher: NSViewRepresentable {
    let onChange: (CGSize) -> Void
    let onEnd: () -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onChange = onChange
        view.onEnd = onEnd
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
        view.onClick = onClick
    }

    final class CatcherView: NSView {
        var onChange: ((CGSize) -> Void)?
        var onEnd: (() -> Void)?
        var onClick: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            let start = NSEvent.mouseLocation
            var moving = false
            NSCursor.closedHand.push()
            defer { NSCursor.pop() }

            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let now = NSEvent.mouseLocation
                // Same convention as SwiftUI: x to the right, y downward.
                let translation = CGSize(width: now.x - start.x, height: start.y - now.y)
                if next.type == .leftMouseUp {
                    if moving { onEnd?() } else { onClick?() }
                    return
                }
                if moving || hypot(translation.width, translation.height) >= 3 {
                    moving = true
                    onChange?(translation)
                }
            }
        }
    }
}
