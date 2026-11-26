// First-run setup for a downloaded app. Checks what actually exists (not an onboarded flag):
// the Parakeet model and the Claude CLI. Downloads the model on demand, verified by checksum.
import Foundation
import CryptoKit

enum Setup {
    // The transcription model. Pinned to the exact release the app was built and tested against.
    static let modelURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8.tar.bz2")!
    static let modelSHA256 = "f628312e9fdf8686374cb01a69425c41732529d540860311f16f37cbc32cfe9b"
    static let modelFiles = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]

    static func modelReady() -> Bool {
        modelFiles.allSatisfy { FileManager.default.fileExists(atPath: "\(Paths.parakeet)/\($0)") }
    }

    // Resolve the claude binary once. A Finder-launched app inherits no shell PATH, so after the
    // common install locations, fall back to a login shell that sources the user's profile.
    private static var cachedClaude: String?
    static func claudePath() -> String? {
        if let c = cachedClaude { return c }   // cached only on success, so a re-check after install works
        var found: String?
        for p in ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            if FileManager.default.isExecutableFile(atPath: p) { found = p; break }
        }
        if found == nil {
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "command -v claude"]
            let out = Pipe(); proc.standardOutput = out; proc.standardError = FileHandle.nullDevice
            if (try? proc.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile(); proc.waitUntilExit()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { found = path }
            }
        }
        if let found { cachedClaude = found }
        return found
    }

    static func claudeReady() -> Bool { claudePath() != nil }
    static func ready() -> Bool { modelReady() && claudeReady() }
}

// Downloads and installs the model, verified by SHA-256, reporting progress for the setup screen.
@MainActor
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum Phase: Equatable { case idle, downloading, verifying, extracting, done, failed(String) }
    @Published var phase: Phase = .idle
    @Published var fraction: Double = 0

    private var session: URLSession?

    func start() {
        guard phase != .downloading else { return }
        phase = .downloading; fraction = 0
        let cfg = URLSessionConfiguration.default
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session?.downloadTask(with: Setup.modelURL).resume()
        log("model download started")
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytes: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let f = Double(written) / Double(total)
        Task { @MainActor in self.fraction = f }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Work on a copy; the temp file is removed when this returns.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("remark-model-\(UUID().uuidString).tar.bz2")
        try? FileManager.default.moveItem(at: location, to: tmp)
        Task { @MainActor in self.install(tmp) }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { Task { @MainActor in self.fail("download failed: \(error.localizedDescription)") } }
    }

    private func install(_ tarball: URL) {
        phase = .verifying
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: tarball) else { return self.hop { self.fail("could not read download") } }
            if Self.sha256(data) != Setup.modelSHA256 { return self.hop { self.fail("checksum mismatch — download corrupted") } }
            self.hop { self.phase = .extracting }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("remark-model-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["xf", tarball.path, "-C", work.path]
            try? tar.run(); tar.waitUntilExit()
            // the files sit one directory down; find and move the four we need
            try? FileManager.default.createDirectory(atPath: Paths.parakeet, withIntermediateDirectories: true)
            var moved = 0
            if let root = try? FileManager.default.contentsOfDirectory(atPath: work.path).first(where: { $0.contains("parakeet") }) {
                for f in Setup.modelFiles {
                    let src = "\(work.path)/\(root)/\(f)", dst = "\(Paths.parakeet)/\(f)"
                    try? FileManager.default.removeItem(atPath: dst)
                    if (try? FileManager.default.moveItem(atPath: src, toPath: dst)) != nil { moved += 1 }
                }
            }
            try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: tarball)
            if moved == Setup.modelFiles.count { log("model installed"); self.hop { self.phase = .done } }
            else { self.hop { self.fail("could not unpack the model") } }
        }
    }

    private func hop(_ block: @escaping () -> Void) { Task { @MainActor in block() } }
    private func fail(_ m: String) { log("model download: \(m)"); phase = .failed(m) }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
