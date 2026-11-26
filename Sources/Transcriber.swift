// Runs the Python transcription sidecar, streams audio frames to it, and parses
// the JSON it prints back. onFinal fires with each completed utterance.
import Foundation

struct Segment { let text: String; let t0: Double; let t1: Double }

final class Transcriber {
    private let proc = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var buffer = Data()

    var onReady: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinal: ((Segment) -> Void)?

    private let python: String
    private let script: String
    private let model: String

    init(root: String) {
        python = "\(root)/sidecar/.venv/bin/python"
        script = "\(root)/sidecar/transcribe_server.py"
        model = "\(root)/models/parakeet"
    }

    func start() {
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script, model]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.ingest(h.availableData)
        }
        do { try proc.run() } catch { log("sidecar failed: \(error)") }
    }

    func stop() {
        inPipe.fileHandleForWriting.closeFile()
        outPipe.fileHandleForReading.readabilityHandler = nil
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

func log(_ m: String) { FileHandle.standardError.write(("[remark] " + m + "\n").data(using: .utf8)!) }
