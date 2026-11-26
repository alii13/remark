import SwiftUI

struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

struct PanelView: View {
    @ObservedObject var state: AppState
    var corner: Alignment = .topTrailing
    var onDragChange: (CGSize) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    var onSize: (CGSize) -> Void = { _ in }
    @State private var breathe = false
    @State private var spin = false
    @State private var copied = false

    var body: some View {
        current
            .padding(14)
            .background(GeometryReader { p in Color.clear.preference(key: ContentSizeKey.self, value: p.size) })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
            .animation(.easeInOut(duration: 0.34), value: state.phase)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { onDragChange($0.translation) }
                    .onEnded { _ in onDragEnd() }
            )
            .contextMenu {
                Button(state.listening ? "Stop listening" : "Start listening") { state.toggleListening() }
                Toggle("Auto-start in meetings", isOn: Binding(get: { state.autoStart }, set: { state.autoStart = $0 }))
                Toggle("Auto suggestions", isOn: Binding(get: { state.autoSuggest }, set: { state.setAutoSuggest($0) }))
                Divider()
                Button("Quit Remark") { NSApp.terminate(nil) }
            }
            .onPreferenceChange(ContentSizeKey.self) { onSize($0) }
            .onAppear { breathe = true; spin = true }
    }

    @ViewBuilder var current: some View {
        switch state.phase {
        case .hidden:  Color.clear.frame(width: 1, height: 1)
        case .resting: resting.transition(.opacity)
        case .thinking: thinking.transition(.opacity)
        case .active:  panel.transition(.opacity)
        }
    }

    // RESTING — a small pill with the mark, breathing.
    var resting: some View {
        ZStack {
            GlassBG(radius: 999)
            if state.listening && state.health == .ok {
                Equalizer(active: true)   // audio wiggle: Remark is hearing the room
                    .shadow(color: Ink.amber.opacity(0.5), radius: breathe ? 6 : 3)
                    .animation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true), value: breathe)
            } else if state.listening {
                Image(systemName: "exclamationmark.triangle.fill")   // listening but not producing transcript/questions
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Ink.amber)
            } else {
                RemarkMark(line: 7).frame(width: 15, height: 15)
                    .opacity(0.5).scaleEffect(0.94)
            }
        }
        .frame(width: 42, height: 26)
        .onTapGesture { state.pillTapped() }
        .help(healthHelp)
    }

    var healthHelp: String {
        if !state.listening { return "Tap to start listening" }
        switch state.health {
        case .ok: return "Listening — tap for the question"
        case .silent: return "Hearing audio but not transcribing — check the sidecar (see ~/remark/remark.log)"
        case .error: return "A part stopped — see ~/remark/remark.log"
        }
    }

    // THINKING — a small pill with a spinner.
    var thinking: some View {
        ZStack {
            GlassBG(radius: 999)
            HStack(spacing: 10) {
                Circle().trim(from: 0, to: 0.7)
                    .stroke(Ink.amber, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 15, height: 15)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                Text("Thinking").font(geist(13, .medium)).foregroundColor(Ink.text)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
        }
        .fixedSize()
    }

    // 👍/👎 on a question — teaches the next meeting via ~/remark/learnings.md
    func thumb(_ s: Suggestion, up: Bool) -> some View {
        Button(action: { state.rate(s, up: up) }) {
            Image(systemName: up ? "hand.thumbsup" : "hand.thumbsdown")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Ink.faint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .help(up ? "Good question — teach it" : "Not useful — avoid these")
    }

    // Copy a question to the clipboard (flash a check on success)
    func copyBtn(_ s: Suggestion) -> some View {
        Button(action: { copyQ(s) }) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(copied ? Ink.amber : Ink.faint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .help("Copy the question")
    }

    func copyQ(_ s: Suggestion) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.question, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    // ACTIVE — the question panel.
    var panel: some View {
        ZStack(alignment: .topLeading) {
            GlassBG(radius: 20)
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    RemarkMark().frame(width: 19, height: 19)
                    Text("Remark").font(geist(15, .semibold)).foregroundColor(Ink.text)
                    Spacer()
                    Text(state.elapsed).font(geistMono(11)).foregroundColor(Ink.faint)
                    Button(action: { state.collapse() }) {
                        Image(systemName: "minus").font(.system(size: 10, weight: .bold))
                            .foregroundColor(Ink.muted).frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.06)))
                    }.buttonStyle(.plain).help("Minimize")
                }
                if let hero = state.suggestions.first {
                    VStack(alignment: .leading, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(Ink.amber).frame(width: 30, height: 3)
                            .shadow(color: Ink.amber.opacity(0.5), radius: 8)
                        HStack(alignment: .firstTextBaseline) {
                            Text(hero.kicker).font(geist(12, .medium)).foregroundColor(Ink.amber)
                            Spacer()
                            copyBtn(hero)
                            thumb(hero, up: true)
                            thumb(hero, up: false)
                        }
                        Text(hero.question).font(geist(22, .medium)).foregroundColor(Ink.text)
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
                    }
                }
                if state.suggestions.count > 1 {
                    Divider().overlay(Ink.edge)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(state.suggestions.dropFirst().enumerated()), id: \.offset) { _, s in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.kicker).font(geist(11, .medium)).foregroundColor(Ink.amber.opacity(0.8))
                                Text(s.question).font(geist(15)).foregroundColor(Ink.muted)
                                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { copyQ(s) }
                            .help("Tap to copy")
                        }
                    }
                }
                Divider().overlay(Ink.edge)
                HStack {
                    Equalizer(active: true)
                    Text(state.autoSuggest ? "Auto" : "Manual").font(geist(12)).foregroundColor(Ink.muted)
                    Spacer()
                    Button(action: { state.ask() }) {
                        Text("⌥Q ").font(geistMono(11)).foregroundColor(Ink.text)
                        + Text("ask now").font(geist(12)).foregroundColor(Ink.muted)
                    }.buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .frame(width: 392)
        .fixedSize(horizontal: true, vertical: true)
    }
}
