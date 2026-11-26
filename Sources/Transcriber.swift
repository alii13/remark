// Runs the Python transcription sidecar, streams audio frames to it, and parses the JSON it
// prints back. onFinal fires with each completed utterance. If the sidecar dies mid-meeting it
// restarts, up to a few times, then reports failure so the app can show it.
import Foundation

struct Segment { let text: String; let t0: Double; let t1: Double }

final class Transcriber {
    private var proc = Process()
    private var inPipe = Pipe()
    private var outPipe = Pipe()
    private var buffer = Data()
    private var stopping = false
    private var restarts = 0
    private let maxRestarts = 3

    var onReady: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinal: ((Segment) -> Void)?
    var onFailure: (() -> Void)?   // fired once restarts are exhausted

    private let python: String
    private let script: String
    private let model: String

    init(root: String) {
        python = "\(root)/sidecar/.venv/bin/python"
        script = "\(root)/sidecar/transcribe_server.py"
        model = "\(root)/models/parakeet"
    }

    func start() {
        proc = Process(); inPipe = Pipe(); outPipe = Pipe()   // a Process runs once; recreate to restart
        buffer.removeAll()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script, model]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.ingest(h.availableData) }
        proc.terminationHandler = { [weak self] p in self?.handleExit(p.terminationStatus) }
        do { try proc.run(); log("sidecar started") }
        catch { log("sidecar failed to start: \(error)"); DispatchQueue.main.async { self.onFailure?() } }
    }

    private func handleExit(_ code: Int32) {
        if stopping { return }
        guard restarts < maxRestarts else {
            log("sidecar exited code=\(code); restarts exhausted")
            DispatchQueue.main.async { self.onFailure?() }
            return
        }
        restarts += 1
        log("sidecar exited code=\(code); restarting \(restarts)/\(maxRestarts)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopping else { return }
            self.start()
        }
    }

    func stop() {
        stopping = true
        proc.terminationHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        try? inPipe.fileHandleForWriting.close()
        if proc.isRunning { proc.terminate() }
    }

    func feed(_ frames: [Float]) {
        guard proc.isRunning else { return }
        frames.withUnsafeBytes { raw in
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(raw))
        }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "ready": onReady?()
            case "partial": if let t = obj["text"] as? String { onPartial?(t) }
            case "final":
                if let t = obj["text"] as? String {
                    onFinal?(Segment(text: t, t0: obj["t0"] as? Double ?? 0, t1: obj["t1"] as? Double ?? 0))
                }
            default: break
            }
        }
    }
}
