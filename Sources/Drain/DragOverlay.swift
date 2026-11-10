import AppKit
import SwiftUI

/// Owns the pulled-out tile. The tile lives in its own transparent, click-through
/// window spanning the screen, so it can travel anywhere outside the menu.
@MainActor
final class DragController: ObservableObject {
    enum Phase { case idle, dragging, poof, returning }

    @Published private(set) var app: AppDrain?
    @Published private(set) var position: CGPoint = .zero   // overlay coordinates
    @Published private(set) var armed = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var poofID = 0
    /// The slice a plain click just explained; the status line shows it for a moment.
    @Published private(set) var hintID: String?
    private var hintToken = 0

    var closeMenu: (() -> Void)?
    private let model: DrainModel
    private var window: NSPanel?
    private var origin: NSPoint = .zero
    private var screenFrame: NSRect = .zero

    /// How far the tile has to travel before letting go quits the app.
    private let quitDistance: CGFloat = 64

    init(model: DrainModel) { self.model = model }

    func changed(_ app: AppDrain, translation: CGSize) {
        let mouse = NSEvent.mouseLocation
        if phase != .dragging || self.app?.id != app.id {
            guard phase == .idle else { return }
            begin(app, mouse: mouse, translation: translation)
        }
        position = local(mouse)
        let isArmed = hypot(translation.width, translation.height) > quitDistance
        if isArmed != armed {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { armed = isArmed }
        }
    }

    /// A click that didn't become a drag. Clears itself, and `clearHint` is also
    /// called when the menu opens or closes, so it can't stay on.
    func hint(_ app: AppDrain) {
        guard phase == .idle else { return }
        hintToken += 1
        let token = hintToken
        withAnimation(.easeOut(duration: 0.15)) { hintID = app.id }
        onMainRunLoop(after: 3.5) { [weak self] in
            if self?.hintToken == token { self?.clearHint() }
        }
    }

    func clearHint() {
        hintToken += 1
        if hintID != nil { withAnimation(.easeOut(duration: 0.15)) { hintID = nil } }
    }

    func ended() {
        guard phase == .dragging, let app else { return }
        if armed {
            phase = .poof
            poofID += 1
            model.quit(app)
            finish(after: 0.6)
        } else {
            phase = .returning
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                position = local(origin)
                armed = false
            }
            onMainRunLoop(after: 0.28) { [weak self] in
                withAnimation(.easeOut(duration: 0.15)) { self?.model.draggingID = nil }
                self?.finish(after: 0.05)
            }
        }
    }

    private func begin(_ app: AppDrain, mouse: NSPoint, translation: CGSize) {
        clearHint()
        origin = NSPoint(x: mouse.x - translation.width, y: mouse.y + translation.height)
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        screenFrame = screen?.frame ?? .zero

        let w = window ?? makeWindow()
        w.setFrame(screenFrame, display: false)
        w.orderFrontRegardless()

        self.app = app
        armed = false
        phase = .dragging
        position = local(mouse)
        withAnimation(.easeOut(duration: 0.12)) { model.draggingID = app.id }
    }

    private func finish(after delay: TimeInterval) {
        onMainRunLoop(after: delay) { [weak self] in
            guard let self, self.phase == .poof || self.phase == .returning else { return }
            self.window?.orderOut(nil)
            self.app = nil
            self.armed = false
            self.phase = .idle
        }
    }

    private func local(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y)
    }

    private func makeWindow() -> NSPanel {
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: DragOverlayView(controller: self))
        window = w
        return w
    }
}

struct DragOverlayView: View {
    @ObservedObject var controller: DragController

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let app = controller.app {
                let gone = controller.phase == .poof
                Tile(app: app)
                    .rotationEffect(.degrees(controller.armed ? -6 : 0))
                    .scaleEffect(gone ? 0.15 : (controller.phase == .returning ? 0.7 : 1))
                    .opacity(gone ? 0 : 1)
                    .animation(.easeIn(duration: 0.18), value: gone)
                    .position(controller.position)

                if controller.armed && controller.phase == .dragging {
                    Text("Quit \(app.name) · \(app.gainTag)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 0.93, green: 0.2, blue: 0.27)))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        .fixedSize()
                        .rotationEffect(.degrees(-4))
                        .position(x: controller.position.x, y: controller.position.y + 50)
                        .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
                }

                if gone {
                    Poof(color: app.color)
                        .id(controller.poofID)
                        .position(controller.position)
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct Tile: View {
    let app: AppDrain

    var body: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(app.color)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .overlay(
                Image(nsImage: app.icon).resizable().interpolation(.high)
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1))
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
    }
}

/// A small burst of dust where the app used to be.
private struct Poof: View {
    let color: Color
    @State private var out = false

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let angle = Double(i) / 14 * 2 * .pi + (i.isMultiple(of: 2) ? 0.15 : -0.1)
                let reach: CGFloat = i.isMultiple(of: 3) ? 46 : 34
                Circle()
                    .fill(i.isMultiple(of: 2) ? Color.white.opacity(0.9) : color)
                    .frame(width: out ? 2 : 7, height: out ? 2 : 7)
                    .offset(x: out ? cos(angle) * reach : cos(angle) * 8,
                            y: out ? sin(angle) * reach : sin(angle) * 8)
                    .opacity(out ? 0 : 1)
            }
        }
        .frame(width: 120, height: 120)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { out = true } }
    }
}
