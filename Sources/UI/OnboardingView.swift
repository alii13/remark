import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject var state: AppState
    var onDone: () -> Void
    @State private var step = 0
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        ZStack(alignment: .top) {
            Ink.backdrop.ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: access
                    default: engine
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 380)
            .padding(.horizontal, 40)
            .padding(.top, 54)
        }
        .frame(width: 460, height: 560)
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHead("01 / 03", "WELCOME")
            RemarkMark().frame(width: 40, height: 40).shadow(color: Ink.amber.opacity(0.45), radius: 10)
            VStack(alignment: .leading, spacing: 12) {
                Text("Catch the question\nyou'd think of too late.")
                    .font(geist(24, .semibold)).foregroundColor(Ink.text).lineSpacing(4)
                Text("Remark listens to your meeting and whispers the sharp question to ask — in plain words, right when it matters.")
                    .font(geist(14)).foregroundColor(Ink.muted).lineSpacing(3)
            }
            primary("Get started") { step = 1 }
        }
    }

    var access: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHead("02 / 03", "ACCESS")
            Text("One quick grant").font(geist(21, .semibold)).foregroundColor(Ink.text)
            Text("So Remark can add your own voice. The meeting's audio is captured on your Mac with no extra permission — macOS may ask once the first time.").font(geist(13)).foregroundColor(Ink.muted).lineSpacing(2)
            permRow("Microphone", "to hear your voice", ok: micOK) {
                AVCaptureDevice.requestAccess(for: .audio) { g in DispatchQueue.main.async { micOK = g } }
            }
            primary("Continue") { step = 2 }
        }
    }

    var engine: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHead("03 / 03", "ENGINE")
            Text("Who writes the questions?").font(geist(21, .semibold)).foregroundColor(Ink.text)
            Text("Remark uses a subscription you already pay for.").font(geist(13)).foregroundColor(Ink.muted)
            engineRow(.claude, "Claude Code")
            engineRow(.codex, "Codex")
            Text("Audio and transcript stay on your Mac. Only the moment's text is sent — to write one question.")
                .font(geist(12)).foregroundColor(Ink.faint).lineSpacing(2)
            primary("Start listening") { state.completeOnboarding(); onDone() }
        }
    }

    func stepHead(_ n: String, _ label: String) -> some View {
        HStack {
            Text(n).font(geistMono(11)).foregroundColor(Ink.faint)
            Spacer()
            Text(label).font(geistMono(11)).tracking(1.2).foregroundColor(Ink.muted)
        }
    }

    func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(geist(14, .semibold)).foregroundColor(Color(red: 0.1, green: 0.08, blue: 0.06))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Ink.amber, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain)
    }

    func permRow(_ title: String, _ sub: String, ok: Bool, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(geist(14)).foregroundColor(Ink.text)
                Text(sub).font(geist(12)).foregroundColor(Ink.muted)
            }
            Spacer()
            if ok {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(Ink.amber)
                    Text("Granted").font(geist(13)).foregroundColor(Ink.amber)
                }
            } else {
                Button("Allow", action: action).buttonStyle(.plain)
                    .font(geist(13, .semibold)).foregroundColor(Color(red: 0.1, green: 0.08, blue: 0.06))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Ink.amber, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.edge)))
    }

    func engineRow(_ e: Engine, _ sub: String) -> some View {
        Button(action: { state.engine = e }) {
            HStack(spacing: 13) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.rawValue).font(geist(15, .medium)).foregroundColor(Ink.text)
                    Text("\(sub) · signed in").font(geist(12)).foregroundColor(Ink.muted)
                }
                Spacer()
                ZStack {
                    Circle().strokeBorder(state.engine == e ? Ink.amber : Ink.faint, lineWidth: 1.5).frame(width: 20, height: 20)
                    if state.engine == e { Circle().fill(Ink.amber).frame(width: 10, height: 10) }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(state.engine == e ? Ink.amber.opacity(0.09) : Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(state.engine == e ? Ink.amber : Ink.edge, lineWidth: state.engine == e ? 1.5 : 1)))
        }.buttonStyle(.plain)
    }
}
