import SwiftUI
import Combine

@main
struct RemarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            DropdownView(state: state)
        } label: {
            // the mark normally; a warning when listening but not producing transcript/questions
            if state.listening && state.health != .ok {
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                Image(nsImage: Self.menuIcon)
            }
        }
        .menuBarExtraStyle(.window)
    }

    static let menuIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()           // template: color ignored, alpha is the mask
            let p = NSBezierPath()
            p.lineWidth = 2.6
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: 7.0, y: 13.4))   // left quote (AppKit y is up)
            p.curve(to: NSPoint(x: 5.6, y: 4.8), controlPoint1: NSPoint(x: 4.9, y: 10.6), controlPoint2: NSPoint(x: 4.7, y: 7.2))
            p.move(to: NSPoint(x: 12.3, y: 13.4))  // right quote
            p.curve(to: NSPoint(x: 10.9, y: 4.8), controlPoint1: NSPoint(x: 10.2, y: 10.6), controlPoint2: NSPoint(x: 10.0, y: 7.2))
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var panel: PanelController?
    private var onboarding: NSWindow?
    private var hotkey: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        signal(SIGPIPE, SIG_IGN)   // a write to a dead claude pipe must not abort us
        if ProcessInfo.processInfo.environment["REMARK_SELFCHECK"] == "1" {
            exit(state.runSelfCheck() ? 0 : 1)
        }
        NSApp.setActivationPolicy(.accessory)
        panel = PanelController(state: state)
        _ = Updater.shared   // start checking for updates in the background

        let env = ProcessInfo.processInfo.environment
        if env["REMARK_DEMO"] == "1" {
            state.demo()
        } else if env["REMARK_FORCE_LISTEN"] == "1" {
            state.startListening()   // test hook: run the real pipeline without waiting for a meeting
        } else if Setup.ready() {
            state.boot()
        } else {
            showSetup()   // model or claude missing — gate on what exists, not a stored flag
        }

        hotkey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(.option), e.keyCode == 12 { // ⌥Q
                Task { @MainActor in self?.state.ask() }
            }
        }
    }

    func showSetup() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
                         styleMask: [.titled, .fullSizeContentView, .closable],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.051, alpha: 1)
        w.center()
        w.contentView = NSHostingView(rootView: SetupView { [weak self, weak w] in
            w?.close(); self?.onboarding = nil; self?.state.completeOnboarding(); self?.state.boot()
        })
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboarding = w
        // closing setup before it's ready leaves an app that can't work, so quit instead
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in if !Setup.ready() { NSApp.terminate(nil) } }
        }
    }
}

enum Dock: String { case top, bottom, left, right }

@MainActor
final class PanelController {
    private let panel: NSPanel
    private let host: NSHostingController<PanelView>
    private var bag = Set<AnyCancellable>()
    private let pad: CGFloat = 14        // must match PanelView's padding
    private let gap: CGFloat = 10        // visible gap between the widget and the screen edge
    private var dock: Dock
    private var dragStart: NSPoint?
    private var dragMouseStart: NSPoint?
    private let state: AppState

    init(state: AppState) {
        self.state = state
        dock = Dock(rawValue: UserDefaults.standard.string(forKey: "panelDock") ?? "") ?? .right
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false

        host = NSHostingController(rootView: PanelView(state: state))
        host.sizingOptions = []                 // the controller owns the window size
        panel.contentViewController = host
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        rebuildView()

        state.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            guard let self else { return }
            if phase != .hidden { self.panel.orderFrontRegardless() } else { self.panel.orderOut(nil) }
        }.store(in: &bag)
    }

    private func edgeAlignment(_ d: Dock) -> Alignment {
        switch d {
        case .top:    return .top
        case .bottom: return .bottom
        case .left:   return .leading
        case .right:  return .trailing
        }
    }

    private func rebuildView() {
        host.rootView = PanelView(
            state: state, corner: edgeAlignment(dock),
            onDragChange: { [weak self] t in self?.dragMoved(t) },
            onDragEnd: { [weak self] in self?.dragEnded() },
            onSize: { [weak self] s in self?.contentSizeChanged(s) })
    }

    private func visibleFrame() -> NSRect { (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero }

    // Docked flush to one edge, centered on it. The window edge slips (pad - gap) past the
    // screen so the visible widget sits `gap` from the edge; the off-screen part is just shadow.
    private func frame(for d: Dock, _ size: NSSize) -> NSRect {
        let vf = visibleFrame()
        let off = pad - gap
        switch d {
        case .right:  return NSRect(x: vf.maxX + off - size.width, y: vf.midY - size.height / 2, width: size.width, height: size.height)
        case .left:   return NSRect(x: vf.minX - off, y: vf.midY - size.height / 2, width: size.width, height: size.height)
        case .bottom: return NSRect(x: vf.midX - size.width / 2, y: vf.minY - off, width: size.width, height: size.height)
        case .top:    return NSRect(x: vf.midX - size.width / 2, y: vf.maxY - gap - size.height, width: size.width, height: size.height)
        }
    }

    // Window follows the content size, docked edge pinned, in sync with the cross-fade.
    private func contentSizeChanged(_ s: CGSize) {
        guard s.width > 1, s.height > 1, dragStart == nil else { return }
        let size = NSSize(width: ceil(s.width), height: ceil(s.height))
        let target = frame(for: dock, size)
        if abs(target.width - panel.frame.width) < 0.5, abs(target.height - panel.frame.height) < 0.5,
           abs(target.minX - panel.frame.minX) < 0.5, abs(target.minY - panel.frame.minY) < 0.5 { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.3, 1)
            panel.animator().setFrame(target, display: true)
        }
    }

    func dragMoved(_ t: CGSize) {
        // Track by the real screen mouse position (fixed frame), not the gesture's
        // translation (measured inside the window, which moves as we drag -> runaway drift).
        if dragStart == nil {
            dragStart = panel.frame.origin
            dragMouseStart = NSEvent.mouseLocation
        }
        guard let ws = dragStart, let ms = dragMouseStart else { return }
        let cur = NSEvent.mouseLocation
        let vf = visibleFrame()
        let w = panel.frame.width, h = panel.frame.height
        // follow the cursor 1:1, clamped on-screen so it never clips or gets lost
        let x = min(max(ws.x + (cur.x - ms.x), vf.minX), vf.maxX - w)
        let y = min(max(ws.y + (cur.y - ms.y), vf.minY), vf.maxY - h)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func dragEnded() {
        dragStart = nil
        dragMouseStart = nil
        let vf = visibleFrame()
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let dLeft = c.x - vf.minX, dRight = vf.maxX - c.x
        let dBottom = c.y - vf.minY, dTop = vf.maxY - c.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        dock = nearest == dLeft ? .left : nearest == dRight ? .right : nearest == dTop ? .top : .bottom
        UserDefaults.standard.set(dock.rawValue, forKey: "panelDock")
        rebuildView()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.42
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1, 0.26, 1)
            panel.animator().setFrame(frame(for: dock, panel.frame.size), display: true)
        }
    }
}
