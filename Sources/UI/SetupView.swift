import SwiftUI

// Shown on first run until the Parakeet model and the Claude CLI are both present. Gates on what
// exists, so it reappears only when something is actually missing.
struct SetupView: View {
    @StateObject private var dl = ModelDownloader()
    @State private var claudeOK = Setup.claudeReady()
    var onReady: () -> Void

    private var modelOK: Bool { dl.phase == .done || Setup.modelReady() }
    private var allReady: Bool { modelOK && claudeOK }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                RemarkMark().frame(width: 26, height: 26)
                Text("Remark").font(geist(22, .semibold)).foregroundColor(Ink.text)
            }
            Text("Two things before your first meeting.").font(geist(13)).foregroundColor(Ink.muted)

            row("On-device transcription model", ready: modelOK) { modelDetail }
            row("Claude CLI", ready: claudeOK) { claudeDetail }

            Button(action: onReady) {
                Text("Start Remark").font(geist(14, .semibold)).foregroundColor(.black)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 10).fill(allReady ? Ink.amber : Ink.faint.opacity(0.4)))
            }
            .buttonStyle(.plain).disabled(!allReady).padding(.top, 4)
        }
        .padding(30).frame(width: 440)
        .background(Ink.backdrop)
        .onChange(of: dl.phase) { _, p in if p == .done { claudeOK = Setup.claudeReady() } }
    }

    @ViewBuilder private var modelDetail: some View {
        switch dl.phase {
        case .downloading, .verifying, .extracting:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: dl.fraction).tint(Ink.amber).frame(width: 250)
                Text(phaseLabel).font(geistMono(11)).foregroundColor(Ink.faint)
            }
        case .failed(let m):
            VStack(alignment: .leading, spacing: 6) {
                Text(m).font(geist(11)).foregroundColor(Color.red.opacity(0.85))
                pill("Retry") { dl.start() }
            }
        default:
            if !modelOK {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Parakeet runs on your Mac; no audio ever leaves it.").font(geist(11)).foregroundColor(Ink.faint)
                    pill("Download (110 MB)") { dl.start() }
                }
            }
        }
    }

    @ViewBuilder private var claudeDetail: some View {
        if !claudeOK {
            VStack(alignment: .leading, spacing: 6) {
                Text("Remark writes the questions with your own Claude subscription.").font(geist(11)).foregroundColor(Ink.faint)
                Link("Install Claude Code", destination: URL(string: "https://docs.claude.com/en/docs/claude-code")!)
                    .font(geist(12)).tint(Ink.amber)
                pill("Re-check") { claudeOK = Setup.claudeReady() }
            }
        }
    }

    private var phaseLabel: String {
        switch dl.phase {
        case .downloading: return "downloading \(Int(dl.fraction * 100))%"
        case .verifying: return "verifying checksum"
        case .extracting: return "unpacking"
        default: return ""
        }
    }

    private func row<Detail: View>(_ title: String, ready: Bool, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ready ? Ink.amber : Ink.faint).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(geist(14, .medium)).foregroundColor(Ink.text)
                detail()
            }
            Spacer()
        }
    }

    private func pill(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(geist(12, .medium)).foregroundColor(Ink.text)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }
}
