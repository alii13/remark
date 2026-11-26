// Headless end-to-end test of Remark's engine:
// system audio -> transcribe -> questions, all printed. No UI.
import Foundation

let root = "\(NSHomeDirectory())/remark"
setbuf(stdout, nil)

let transcriber = Transcriber(root: root)
let engine = QuestionEngine(model: CommandLine.arguments.dropFirst().first ?? "haiku")
let capture = AudioCapture()
capture.captureMic = false   // test uses system audio only

func out(_ s: String) { print(s); fflush(stdout) }

transcriber.onReady = { out("● transcriber ready") }
transcriber.onPartial = { t in out("  … \(t)") }
transcriber.onFinal = { seg in
    out("▸ [\(seg.t0)-\(seg.t1)] \(seg.text)")
    engine.addFinal(seg.text)
}
engine.onSuggestions = { sugs in
    out("\n  ┌─ QUESTIONS ─────────────────────")
    for s in sugs { out("  │ (\(s.kicker))  \(s.question)") }
    out("  └─────────────────────────────────\n")
}

capture.onFrames = { frames in transcriber.feed(frames) }

transcriber.start()
engine.start()
Task {
    do { try await capture.start(); out("● capturing system audio") }
    catch { out("capture error: \(error)") }
}

signal(SIGINT) { _ in exit(0) }
RunLoop.main.run()
