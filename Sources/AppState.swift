import SwiftUI
import Combine
import AppKit

enum Phase { case hidden, resting, thinking, active }
enum Engine: String { case claude = "Claude", codex = "ChatGPT" }
enum Health { case ok, error, silent }   // ok | a part broke | hearing audio but no transcript

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var phase: Phase = .hidden
    @Published var suggestions: [Suggestion] = []
    @Published var listening = false
    @Published var health: Health = .ok
    @Published var autoStart = true
    @Published var autoSuggest = true          // Auto vs Manual
    @Published var engine: Engine = .claude
    @Published var inMeeting = false
    @Published var systemOn = true
    @Published var micOn = false   // off by default: our own mic use would keep auto-detect stuck "in a meeting"
    @Published var elapsed = "0:00"
    @Published var onboarded = UserDefaults.standard.bool(forKey: "onboarded")

    private let detector = MeetingDetector()
    private var capture: AudioCapture?
    private var transcriber: Recognizer?
    private var qengine: QuestionEngine?
    private var startedAt: Date?
    private var ticker: Timer?
    private var collapseTimer: Timer?
    private var meetingLines: [String] = []   // full transcript of the meeting, distilled on stop
    private let idleLimit: TimeInterval = 150   // stop an orphan (manual) session after this much silence
    private var lastTranscriptAt = Date()       // when a partial/final last arrived, for the health check

    func boot() {
        detector.onChange = { [weak self] inMeeting in
            guard let self else { return }
            self.inMeeting = inMeeting
            if self.autoStart {
                if inMeeting { self.startListening() } else { self.stopListening() }
            }
        }
        detector.start()
        phase = .hidden   // invisible until a meeting starts; appears on its own
    }

    func pillTapped() {
        if !listening { startListening() }
        else if !suggestions.isEmpty { phase = .active }
    }

    func startListening() {
        guard !listening else { return }
        listening = true
        phase = .resting
        health = .ok
        suggestions = []
        meetingLines = []
        startedAt = Date()
        lastTranscriptAt = Date()
        startTicker()
        log("session start")

        let t = Recognizer(modelDir: Paths.parakeet)
        let q = QuestionEngine(model: engine == .claude ? "sonnet" : "sonnet")
        q.autoSuggest = autoSuggest
        let c = AudioCapture()
        c.captureMic = micOn

        let gotText: () -> Void = { [weak self] in
            guard let self else { return }
            self.lastTranscriptAt = Date()
            if self.health == .silent { self.health = .ok }
        }
        t.onPartial = { _ in DispatchQueue.main.async { gotText() } }
        t.onFinal = { [weak self, weak q] seg in
            q?.addFinal(seg.text)
            DispatchQueue.main.async { gotText(); self?.meetingLines.append(seg.text) }
        }
        t.onFailure = { [weak self] in DispatchQueue.main.async { self?.health = .error; log("health: transcriber failed") } }
        q.onFailure = { [weak self] in DispatchQueue.main.async { self?.health = .error; log("health: question engine failed") } }
        q.onThinking = { [weak self] thinking in
            guard let self, self.listening else { return }
            if thinking {
                if self.suggestions.isEmpty { self.phase = .thinking }
            } else {
                self.phase = self.suggestions.isEmpty ? .resting : .active   // '-' is the common reply; don't stick on the spinner
            }
        }
        q.onSuggestions = { [weak self] sugs in
            guard let self, self.listening else { return }
            // newest on top, keep the last 4 distinct so earlier ones stay readable
            var list = self.suggestions
            for s in sugs.reversed() {
                list.removeAll { $0.question.caseInsensitiveCompare(s.question) == .orderedSame }
                list.insert(s, at: 0)
            }
            self.suggestions = Array(list.prefix(4))
            self.phase = .active
            self.scheduleCollapse()
        }
        c.onFrames = { [weak t] frames in t?.feed(frames) }

        t.start(); q.start()
        do { try c.start() } catch { health = .error; log("health: audio capture failed to start: \(error)") }
        transcriber = t; qengine = q; capture = c
    }

    func stopListening() {
        guard listening else { return }
        listening = false
        health = .ok
        phase = .hidden   // meeting over → widget disappears
        log("session stop")
        capture?.stop(); transcriber?.stop(); qengine?.stop()
        capture = nil; transcriber = nil; qengine = nil
        ticker?.invalidate(); ticker = nil
        collapseTimer?.invalidate(); collapseTimer = nil
        suggestions = []
        distillMeeting()
    }

    // Learn from the meeting that just ended: distill its transcript into an encrypted record
    // and fold it into the profile, off the main thread. Short meetings are skipped.
    private func distillMeeting() {
        let lines = meetingLines
        meetingLines = []
        guard lines.count >= 8 else { return }
        let transcript = lines.joined(separator: "\n")
        DispatchQueue.global(qos: .utility).async {
            if let rec = Distiller.distill(transcript: transcript, finalCount: lines.count) {
                ContextStore.save(rec)
            }
        }
    }

    private func scheduleCollapse() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.listening else { return }
                self.phase = .resting   // tuck to the pill but keep the questions to re-open
            }
        }
    }

    func toggleListening() { listening ? stopListening() : startListening() }

    func ask() {
        if !listening { startListening() }
        if suggestions.isEmpty { phase = .thinking }
        qengine?.ask()
    }

    func setAutoSuggest(_ on: Bool) { autoSuggest = on; qengine?.autoSuggest = on }

    // 👍/👎 on a question: teach the next meeting + keep a journal, then clear it.
    func rate(_ s: Suggestion, up: Bool) {
        appendLearning(s, up: up)
        suggestions.removeAll { $0.question.caseInsensitiveCompare(s.question) == .orderedSame }
        if suggestions.isEmpty { phase = .resting }
    }

    private func appendLearning(_ s: Suggestion, up: Bool) {
        appendFile(Paths.learnings, "- [\(up ? "like" : "avoid")] \(s.kicker) | \(s.question)\n")
        let jdir = Paths.journal
        try? FileManager.default.createDirectory(atPath: jdir, withIntermediateDirectories: true)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let obj: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "up": up, "gap": s.kicker, "q": s.question]
        if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
            appendFile("\(jdir)/\(day.string(from: Date())).jsonl", line + "\n")
        }
    }

    private func appendFile(_ path: String, _ text: String) {
        if let h = FileHandle(forWritingAtPath: path) {
            try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8)); try? h.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func dismiss() { if listening { phase = .resting; suggestions = [] } }

    func collapse() { if listening { phase = .resting } }          // minimize to the mark, keep questions
    func expand() {                                                 // tap the mark to bring them back
        guard listening else { return }
        if !suggestions.isEmpty { phase = .active } else { ask() }
    }

    func demo() {
        listening = true
        phase = .resting
        startedAt = Date(); startTicker()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.phase = .thinking }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            self.suggestions = [
                Suggestion(kicker: "number has no source", question: "Where did the eight percent come from, and who verified it?", at: "32:40"),
                Suggestion(kicker: "decision unmade", question: "Is the free tier kept, or cut to three seats?", at: "31:58"),
                Suggestion(kicker: "no rollback plan", question: "If prices go wrong mid-migration, how do we roll back?", at: "30:12"),
            ]
            self.phase = .active
        }
    }

    func completeOnboarding() {
        onboarded = true
        UserDefaults.standard.set(true, forKey: "onboarded")
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                // orphan-session watchdog: a manual start with no detected meeting,
                // silent too long, was left on by accident — stop it.
                if self.listening, !self.inMeeting, let c = self.capture, c.secondsSinceAudio() > self.idleLimit {
                    self.stopListening(); return
                }
                // hearing real audio but no transcript for 30s -> transcription is stuck, not silence
                if self.listening, self.health != .error, let c = self.capture,
                   c.secondsSinceAudio() < 4, Date().timeIntervalSince(self.lastTranscriptAt) > 30 {
                    if self.health != .silent { log("health: audio but no transcript for 30s"); self.health = .silent }
                }
                let t = Int(Date().timeIntervalSince(s))
                self.elapsed = String(format: "%d:%02d", t / 60, t % 60)
            }
        }
    }
}
