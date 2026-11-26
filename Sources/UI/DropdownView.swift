import SwiftUI

struct DropdownView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RemarkMark().frame(width: 18, height: 18)
                Text("Remark").font(geist(15, .semibold)).foregroundColor(Ink.text)
                Spacer()
                if state.listening { Equalizer(active: true); Text(state.elapsed).font(geistMono(11)).foregroundColor(Ink.muted) }
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            toggleRow("Listening", state.listening ? (state.inMeeting ? "Hearing this meeting" : "On") : "Off",
                      isOn: Binding(get: { state.listening }, set: { _ in state.toggleListening() }))
            toggleRow("Auto-start in meetings", "Wakes when your mic goes live",
                      isOn: $state.autoStart)
            sectionLabel("SOURCES")
            sourceRow("System audio", "the meeting", isOn: $state.systemOn)
            sourceRow("Microphone", "your voice", isOn: $state.micOn)
            divider
            toggleRow("Auto suggestions", "Pop up as it listens",
                      isOn: Binding(get: { state.autoSuggest }, set: { state.setAutoSuggest($0) }))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Engine").font(geist(14)).foregroundColor(Ink.text)
                    Text("Who writes the questions").font(geist(12)).foregroundColor(Ink.muted)
                }
                Spacer()
                Picker("", selection: $state.engine) {
                    Text("Claude").tag(Engine.claude); Text("ChatGPT").tag(Engine.codex)
                }.pickerStyle(.segmented).frame(width: 160).labelsHidden()
            }.padding(.horizontal, 16).padding(.vertical, 12)
            divider
            HStack {
                Button("Quit Remark") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(geist(13)).foregroundColor(Ink.faint)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 11)
        }
        .frame(width: 320)
        .background(Color(white: 0.06))
    }

    var divider: some View { Rectangle().fill(Ink.edge).frame(height: 1) }

    func sectionLabel(_ t: String) -> some View {
        HStack { Text(t).font(geistMono(10)).tracking(1.4).foregroundColor(Ink.faint); Spacer() }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    func toggleRow(_ title: String, _ sub: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(geist(14, .medium)).foregroundColor(Ink.text)
                Text(sub).font(geist(12)).foregroundColor(Ink.muted)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(Ink.amber)
        }.padding(.horizontal, 16).padding(.vertical, 11)
    }

    func sourceRow(_ title: String, _ sub: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(geist(14)).foregroundColor(Ink.text)
                Text(sub).font(geist(12)).foregroundColor(Ink.muted)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(Ink.amber)
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
}
