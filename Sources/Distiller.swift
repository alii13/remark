// Turns a finished meeting's full transcript into one structured record. Runs a separate
// one-shot `claude` (not the warm question session, whose prompt forces the gap|question
// format). Synchronous — call it off the main thread.
import Foundation

enum Distiller {
    private struct Raw: Codable { let type: String?; let topics: [String]?; let decisions: [String]?; let open_threads: [String]? }

    static func distill(transcript: String, finalCount: Int) -> MeetingRecord? {
        guard finalCount >= 8, !transcript.isEmpty else { return nil }   // too thin to tell

        let system = """
        You read a meeting transcript — rough speech-to-text, no speaker labels, missing the
        note-taker's own voice — and return ONLY a compact JSON object describing it. Shape:
        {"type":"...","topics":["..."],"decisions":["..."],"open_threads":["..."]}
        - type: a short label for the meeting, e.g. "architecture review", "1:1", "incident",
          "planning", "sales call", "demo", "standup". Best guess from the content.
        - topics: 2 to 6 concrete things discussed, in plain words.
        - decisions: things decided or agreed. Empty if none were clear.
        - open_threads: questions left hanging or things deferred — each a short sentence
          someone could follow up on next time. Empty if none.
        Keep each string under 15 words. Never include names of people — speech-to-text guesses
        them. If the transcript is too thin to tell, return
        {"type":"unknown","topics":[],"decisions":[],"open_threads":[]}.
        Output the JSON on one line. Nothing before it, nothing after it.
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: QuestionEngine.claudePath())
        proc.arguments = ["-p", "--model", "sonnet", "--no-session-persistence",
                          "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                          "--system-prompt", system]
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe; proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        try? inPipe.fileHandleForWriting.write(contentsOf: transcript.data(using: .utf8) ?? Data())
        try? inPipe.fileHandleForWriting.close()

        // Bound the wait — a hung claude must not park the thread or orphan the child. Dropping
        // this one meeting's record is fine for best-effort memory.
        let sem = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global().async { data = outPipe.fileHandleForReading.readDataToEndOfFile(); sem.signal() }
        if sem.wait(timeout: .now() + 60) == .timedOut { proc.terminate(); return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text, finalCount: finalCount)
    }

    private static func parse(_ text: String, finalCount: Int) -> MeetingRecord? {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e else { return nil }
        let json = String(text[s...e])
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return nil }
        let type = String((raw.type ?? "unknown").replacingOccurrences(of: "\n", with: " ").prefix(40))
        let topics = clean(raw.topics, max: 8)
        if type == "unknown" && topics.isEmpty { return nil }   // nothing worth remembering
        return MeetingRecord(at: ISO8601DateFormatter().string(from: Date()),
                             type: type, topics: topics,
                             decisions: clean(raw.decisions, max: 8), openThreads: clean(raw.open_threads, max: 8),
                             finalCount: finalCount)
    }

    // The strings come from the model distilling an untrusted transcript, so cap length and count
    // before they are stored and replayed into later meetings.
    private static func clean(_ xs: [String]?, max: Int) -> [String] {
        (xs ?? []).prefix(max).map {
            String($0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(160))
        }.filter { !$0.isEmpty }
    }
}
