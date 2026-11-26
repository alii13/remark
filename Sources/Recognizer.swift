// On-device transcription, in-process. Replaces the Python sidecar: holds a sherpa-onnx offline
// Parakeet recognizer and runs the same RMS segmentation the sidecar did, emitting a partial
// while someone speaks and a final when they pause. All work runs on one serial queue off the
// audio thread. No audio leaves the machine.
import Foundation

struct Segment { let text: String; let t0: Double; let t1: Double }

final class Recognizer {
    var onReady: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinal: ((Segment) -> Void)?
    var onFailure: (() -> Void)?

    private let modelDir: String
    private let queue = DispatchQueue(label: "remark.asr")
    private var rec: SherpaOnnxOfflineRecognizer?

    // Segmentation, matching the former sidecar.
    private let sr = 16000
    private let frame = 320                      // 20 ms
    private let startRMS: Float = 0.015
    private let silenceRMS: Float = 0.008
    private let hangover = Int(0.6 * 16000)
    private let maxSeg = 14 * 16000
    private let partialEvery = Int(1.2 * 16000)
    private let preroll = Int(0.25 * 16000)

    private var pending: [Float] = []            // leftover samples not yet a full frame
    private var ring: [Float] = []               // pre-roll of recent audio before speech
    private var seg: [Float] = []                // current speech segment
    private var inSpeech = false
    private var silence = 0
    private var lastPartial = 0
    private var total = 0
    private var segStart = 0.0

    init(modelDir: String) { self.modelDir = modelDir }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let rec = Self.makeRecognizer(self.modelDir) else {
                log("recognizer: failed to load model from \(self.modelDir)")
                DispatchQueue.main.async { self.onFailure?() }
                return
            }
            self.rec = rec
            _ = self.decode([Float](repeating: 0, count: self.sr / 2))   // warm up
            log("recognizer ready")
            DispatchQueue.main.async { self.onReady?() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.inSpeech, self.seg.count > self.frame {   // flush a segment still open at teardown
                let txt = self.decode(self.seg)
                if !txt.isEmpty {
                    let s = Segment(text: txt, t0: self.segStart, t1: self.segStart + Double(self.seg.count) / Double(self.sr))
                    DispatchQueue.main.async { self.onFinal?(s) }
                }
            }
            self.rec = nil; self.reset()
        }
    }

    func feed(_ frames: [Float]) {
        queue.async { [weak self] in self?.process(frames) }
    }

    // MARK: segmentation (ported from the sidecar)

    private func process(_ incoming: [Float]) {
        guard rec != nil else { return }
        pending += incoming
        while pending.count >= frame {
            let f = Array(pending.prefix(frame))
            pending.removeFirst(frame)
            step(f)
        }
    }

    private func step(_ f: [Float]) {
        total += f.count
        let rms = rmsOf(f)

        if !inSpeech {
            ring += f
            if ring.count > preroll { ring.removeFirst(ring.count - preroll) }
            if rms >= startRMS {
                inSpeech = true
                seg = ring + f
                ring.removeAll()
                silence = 0
                segStart = Double(total - seg.count) / Double(sr)
                lastPartial = seg.count
            }
            return
        }

        seg += f
        silence = rms < silenceRMS ? silence + f.count : 0

        if seg.count - lastPartial >= partialEvery, silence == 0 {
            lastPartial = seg.count
            let txt = decode(seg)
            if !txt.isEmpty { DispatchQueue.main.async { self.onPartial?(txt) } }
        }

        if silence >= hangover || seg.count >= maxSeg {
            let speech = silence > 0 ? Array(seg.prefix(seg.count - silence)) : seg
            let txt = speech.count > frame ? decode(speech) : ""
            if !txt.isEmpty {
                let t0 = segStart, t1 = segStart + Double(speech.count) / Double(sr)
                DispatchQueue.main.async { self.onFinal?(Segment(text: txt, t0: t0, t1: t1)) }
            }
            inSpeech = false; seg.removeAll(); silence = 0
        }
    }

    private func rmsOf(_ f: [Float]) -> Float {
        var sum: Float = 0
        for x in f { sum += x * x }
        return (sum / Float(f.count)).squareRoot()
    }

    private func decode(_ samples: [Float]) -> String {
        guard let rec else { return "" }
        return rec.decode(samples: samples, sampleRate: sr).text.trimmingCharacters(in: .whitespaces)
    }

    private func reset() {
        pending.removeAll(); ring.removeAll(); seg.removeAll()
        inSpeech = false; silence = 0; lastPartial = 0; total = 0
    }

    private static func makeRecognizer(_ dir: String) -> SherpaOnnxOfflineRecognizer? {
        let enc = "\(dir)/encoder.int8.onnx", dec = "\(dir)/decoder.int8.onnx"
        let join = "\(dir)/joiner.int8.onnx", tok = "\(dir)/tokens.txt"
        guard FileManager.default.fileExists(atPath: enc), FileManager.default.fileExists(atPath: tok) else { return nil }
        var transducer = sherpaOnnxOfflineTransducerModelConfig(encoder: enc, decoder: dec, joiner: join)
        var model = sherpaOnnxOfflineModelConfig(tokens: tok, transducer: transducer, numThreads: 4, modelType: "nemo_transducer")
        var feat = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: feat, modelConfig: model, decodingMethod: "greedy_search")
        return SherpaOnnxOfflineRecognizer(config: &config)
    }
}
