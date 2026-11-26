// Keeps a warm `claude -p` stream-json session and turns the rolling meeting
// transcript into the questions worth asking. Debounced so it doesn't fire on
// every word; manual ask() forces a fresh read.
import Foundation

struct Suggestion { let kicker: String; let question: String; let at: String }

final class QuestionEngine {
    private let proc = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var buffer = Data()

    private var transcript: [String] = []
    private var pending = false
    private var lastSend = Date.distantPast
    private let minGap: TimeInterval = 20
    private let queue = DispatchQueue(label: "remark.qe")

    var onSuggestions: (([Suggestion]) -> Void)?
    var onThinking: ((Bool) -> Void)?
    var autoSuggest = true
    var model: String
    var role: String

    private let system: String

    init(model: String = "sonnet",
         role: String = "I'm a senior engineer in deep technical and architecture reviews. I probe how the system really behaves, push back on unnecessary complexity, and surface the edge cases and tradeoffs others skip.") {
        self.model = model
        self.role = role
        let base = """
        You sit beside me in a meeting and whisper the one question I could ask right now to cut
        to clarity. You see the transcript in chunks as it goes.
        About me: \(role)

        The test is me, the asker: only give me a question I'd actually want to say out loud in
        front of these people — sharp and welcome, never pedantic, obvious, or process-y. Silence
        is the default; most chunks earn nothing, and nothing beats a so-so question. I want a
        rare, well-aimed nudge, not a stream.

        First find the single sharpest gap — the one thing that, if asked, most changes what we
        do or decide. Then say it plainly. Clean wording never replaces hitting the right target.
        The gap is usually one of:
        - an edge case or failure mode nobody handled ("what happens on logout mid-import?")
        - a simpler path nobody weighed ("why a new service instead of a scheduled job?")
        - a downside someone waved off — "we lose X but that's fine" — where the real question is whether losing X is actually fine, and what it costs us
        - a concrete fork left open ("one API key for all tenants, or one per tenant?")
        - a consequence of the plan ("if we reuse that state, what breaks?")
        - a number or result with no baseline — "up 12%", "latency dropped a lot", "it'll be fine" — ask from what to what, measured how, on what sample
        Walk a concrete scenario when it exposes the gap ("if a user deletes their account,
        do their shared links break immediately, or keep working?").

        Say it the way a sharp colleague says it out loud:
        - Plain words people use. Name the real thing and who it hits — "can a retry double-charge the customer?", not "is the endpoint idempotent?" unless they said that word.
        - One ask. Don't staple on a second question with "and...". Pick the single sharpest thing and drop the rest.
        - Say the actual point, not a label for it. No hedging, no filler, no stacked nouns, no em dashes. Under 15 words. Cut every word you can.
        - Never open with "Could you elaborate", "Can you clarify", "How do we ensure", or "Have we considered".

        OUTPUT FORMAT — follow exactly, emit nothing else:
        One line: the 3-6 word gap, then " | ", then the question.
        Example: simpler path exists | Why a new service instead of a scheduled job?
        If nothing clears the bar — most of the time — output exactly: -
        No preamble, no explanation, no self-correction, no quotes, no second line. Gap first, then the question.
        """
        // The base instructions go on the command line (not sensitive, and cached). The
        // learnings and the past-meeting brief are personal, so they ride in on stdin as the
        // first message instead — argv is visible to any local process via `ps`.
        self.system = base
    }

    // Past-meeting brief + liked/avoided exemplars. Composed lazily on the qe queue (off the main
    // thread) and re-injected every so often: it rides in the first user message instead of the
    // system prompt, so without re-injection it would lose salience deep into a long meeting.
    private func composePrimer() -> String {
        [ContextStore.brief(), Self.learnings()].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private var primer: String?
    private var sendsSincePrimer = 0
    private let primerEveryTurns = 18

    // Owner feedback from past meetings — liked/avoided questions appended by the
    // thumbs in the panel. Loaded once per session so each meeting sharpens the next.
    private static func learnings() -> String {
        let path = "\(NSHomeDirectory())/remark/learnings.md"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        var liked: [String] = [], avoid: [String] = []
        for raw in text.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("- [like]") { liked.append(String(s.dropFirst(8)).trimmingCharacters(in: .whitespaces)) }
            else if s.hasPrefix("- [avoid]") { avoid.append(String(s.dropFirst(9)).trimmingCharacters(in: .whitespaces)) }
        }
        var out = ""
        if !liked.isEmpty {
            out += "\n\nQuestions I liked before — match this taste:\n" + liked.suffix(12).map { "• \($0)" }.joined(separator: "\n")
        }
        if !avoid.isEmpty {
            out += "\n\nQuestions I did NOT want — never ask like these:\n" + avoid.suffix(8).map { "• \($0)" }.joined(separator: "\n")
        }
        return out
    }

    func start() {
        proc.executableURL = URL(fileURLWithPath: Self.claudePath())
        proc.arguments = ["-p", "--model", model,
                          "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                          "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                          "--no-session-persistence", "--system-prompt", system]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.ingest(h.availableData) }
        do { try proc.run() } catch { log("claude failed: \(error)") }
    }

    func stop() {
        inPipe.fileHandleForWriting.closeFile()
        outPipe.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
        queue.async { self.transcript.removeAll() }
    }

    func addFinal(_ text: String) {
        queue.async {
            self.transcript.append(text)
            if self.transcript.count > 40 { self.transcript.removeFirst(self.transcript.count - 40) }
            if self.autoSuggest, Date().timeIntervalSince(self.lastSend) >= self.minGap { self.send(manual: false) }
        }
    }

    func ask() { queue.async { self.send(manual: true) } }

    private func send(manual: Bool) {
        guard proc.isRunning, !transcript.isEmpty, !pending else { return }
        pending = true
        lastSend = Date()
        let stamp = lastSend
        queue.asyncAfter(deadline: .now() + 25) { [weak self] in   // never let a hung reply wedge the session
            guard let self, self.pending, self.lastSend == stamp else { return }
            self.pending = false
            DispatchQueue.main.async { self.onThinking?(false) }
        }
        DispatchQueue.main.async { self.onThinking?(true) }
        let recent = transcript.suffix(12).joined(separator: "\n")
        let note = manual ? "I'm stuck — give me the sharpest question to ask right now." : "Latest:"
        var content = "\(note)\n\(recent)"
        if primer == nil { primer = composePrimer() }   // on the qe queue, off the main thread
        if let p = primer, !p.isEmpty {
            if sendsSincePrimer == 0 { content = p + "\n\n" + content }
            sendsSincePrimer = (sendsSincePrimer + 1) % primerEveryTurns
        }
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            var line = data; line.append(0x0a)
            try? inPipe.fileHandleForWriting.write(contentsOf: line)
        }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            self.buffer.append(data)
            while let nl = self.buffer.firstIndex(of: 0x0a) {
                let line = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if obj["type"] as? String == "result", let text = obj["result"] as? String {
                    self.pending = false
                    DispatchQueue.main.async { self.onThinking?(false) }
                    self.parse(text)
                }
            }
        }
    }

    private func parse(_ text: String) {
        var out: [Suggestion] = []
        let f = DateFormatter(); f.dateFormat = "mm:ss"
        let now = f.string(from: Date())
        for raw in text.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s == "-" || s.isEmpty { continue }
            let parts = s.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { out.append(Suggestion(kicker: parts[0], question: parts[1], at: now)) }
            else { out.append(Suggestion(kicker: "worth asking", question: s, at: now)) }
        }
        if !out.isEmpty { DispatchQueue.main.async { self.onSuggestions?(out) } }
    }

    static func claudePath() -> String {
        for p in ["\(NSHomeDirectory())/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "claude"
    }
}
