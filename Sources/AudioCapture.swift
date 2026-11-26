// Captures the meeting: system audio (everyone else) via a Core Audio process
// tap + the user's mic (their own voice) via AVAudioEngine, mixed to one 16 kHz
// mono float32 stream. onFrames delivers ~50 ms blocks. The tap reads system
// output directly — no Screen Recording permission (macOS shows a small audio
// recording dot while it runs).
import AVFoundation
import CoreAudio
import AudioToolbox

final class AudioCapture {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // system audio via a global process tap wrapped in a private aggregate device
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var sysConverter: AVAudioConverter?
    private var tapBaseASBD = AudioStreamBasicDescription()
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "remark.tap.io")
    private let rateQueue = DispatchQueue(label: "remark.tap.rate")   // HAL reads, kept off the IO thread
    private var rateFrames = 0                                         // measure the real delivery rate
    private var rateWindowStart = Date().timeIntervalSinceReferenceDate
    private var lastBufferAt = Date().timeIntervalSinceReferenceDate

    // the user's own voice
    private let engine = AVAudioEngine()
    private var micConverter: AVAudioConverter?

    private let lock = NSLock()
    private var systemBuf: [Float] = []
    private var micBuf: [Float] = []
    private var timer: DispatchSourceTimer?
    private var lastAudioRef = Date().timeIntervalSinceReferenceDate

    var onFrames: (([Float]) -> Void)?
    var captureMic = true

    enum Err: Error { case tap(OSStatus) }

    func start() throws {
        try startTap()
        if captureMic { startMic() }
        lock.lock(); lastAudioRef = Date().timeIntervalSinceReferenceDate; lock.unlock()
        startMixer()
    }

    func stop() {
        timer?.cancel(); timer = nil
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        if aggID != kAudioObjectUnknown {
            if let b = rateListener {
                var rateAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(aggID, &rateAddr, rateQueue, b)
                rateListener = nil
                rateQueue.sync {}   // let any in-flight listener read finish,
                ioQueue.sync {}     // then the converter swap it dispatched, before we destroy aggID
            }
            AudioDeviceStop(aggID, procID)
            if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown); procID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        lock.lock(); systemBuf.removeAll(); micBuf.removeAll(); lock.unlock()
    }

    // seconds since the mixed signal last carried real sound (for the idle watchdog)
    func secondsSinceAudio() -> TimeInterval {
        lock.lock(); let t = lastAudioRef; lock.unlock()
        return Date().timeIntervalSinceReferenceDate - t
    }

    private func startTap() throws {
        do { try startTapInner() } catch { stop(); throw error }   // never leak a half-built tap
    }

    private func startTapInner() throws {
        let sys = AudioObjectID(kAudioObjectSystemObject)

        // our own process object, to exclude from the tap (no self-capture)
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var own = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(sys, &pidAddr, UInt32(MemoryLayout<pid_t>.size), &pid, &sz, &own)

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw Err.tap(err) }

        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &sz, &asbd)
        guard err == noErr, AVAudioFormat(streamDescription: &asbd) != nil else { throw Err.tap(err) }
        // The converter is built once the aggregate exists, from its real delivery rate —
        // not the tap's fixed 48 kHz (see adoptAggregateRate below).

        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var outDev = AudioDeviceID(kAudioObjectUnknown)
        sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(sys, &outAddr, 0, nil, &sz, &outDev)
        let outUID = Self.deviceUID(outDev)

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RemarkAudioTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard err == noErr else { throw Err.tap(err) }

        // The tap always advertises 48 kHz, but the aggregate delivers audio at the output
        // device's real rate — 24 kHz when AirPods are in call mode (HFP). Converting that as
        // 48 kHz time-compresses the sound 2x and the transcriber reads only noise, so no
        // questions ever surface. Read the aggregate's true rate, and rebuild if it changes.
        tapBaseASBD = asbd
        applyRate(readAggregateRate())
        addRateListener()

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, inData, _, _, _ in
            self?.handleTap(inData)
        }
        guard err == noErr else { throw Err.tap(err) }
        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { throw Err.tap(err) }
    }

    // The aggregate's true delivery rate (a HAL round-trip that can block). Call off the IO
    // thread. Returns 0 if the read fails.
    private func readAggregateRate() -> Double {
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nsr = Float64(0)
        var nsz = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(aggID, &rateAddr, 0, nil, &nsz, &nsr) == noErr, nsr > 0 { return nsr }
        return 0
    }

    // Build the system converter for a delivery rate. Runs serialized with handleTap — either at
    // setup before IO starts, or on ioQueue from the rate listener.
    private func applyRate(_ rate: Double) {
        var asbd = tapBaseASBD
        if rate > 0 {
            asbd.mSampleRate = rate
        } else if sysConverter != nil {
            return   // a failed read must not fall back to the tap's 48 kHz over a working converter
        } else {
            FileHandle.standardError.write("remark: aggregate rate read failed; using tap format\n".data(using: .utf8)!)
        }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        tapFormat = fmt
        sysConverter = AVAudioConverter(from: fmt, to: target)
    }

    // Best-effort: rebuild the converter if the aggregate's rate changes mid-session. Unverified
    // for a same-device AirPods call-mode flip (the rate may not republish on the aggregate); the
    // load-bearing case is the read at setup, when the device is already in its call-mode rate. A
    // mid-call output-device switch is not handled — the aggregate stays pinned to its first device.
    private func addRateListener() {
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let rate = self.readAggregateRate()            // on rateQueue, off the IO thread
            self.ioQueue.async { self.applyRate(rate) }     // swap serialized with handleTap
        }
        rateListener = block
        AudioObjectAddPropertyListenerBlock(aggID, &rateAddr, rateQueue, block)
    }

    private func handleTap(_ inData: UnsafePointer<AudioBufferList>) {
        guard let tf = tapFormat, let conv = sysConverter else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let b0 = abl.first, b0.mDataByteSize > 0 else { return }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: tf, bufferListNoCopy: inData, deallocator: nil),
              inBuf.frameLength > 0 else { return }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * target.sampleRate / tf.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        conv.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        append(out, to: \.systemBuf)
        measureRate(inBuf.frameLength, inputRate: tf.sampleRate)
    }

    // The aggregate can deliver at a rate no property reports truthfully (AirPods call mode, a
    // mid-call device switch). Count the frames it actually delivers per second; if that differs
    // from what the converter assumes, rebuild the converter at the real rate. Runs on ioQueue,
    // so the rebuild is serialized with handleTap.
    private func measureRate(_ frames: AVAudioFrameCount, inputRate: Double) {
        let now = Date().timeIntervalSinceReferenceDate
        // A tap delivers buffers only while audio plays. A gap means the room went quiet, so the
        // window would mix silence with speech and read a false rate — restart it on any gap, and
        // only trust a window of continuous audio.
        if now - lastBufferAt > 0.3 { rateFrames = 0; rateWindowStart = now }
        lastBufferAt = now
        rateFrames += Int(frames)
        let elapsed = now - rateWindowStart
        guard elapsed >= 1.5 else { return }
        let measured = Double(rateFrames) / elapsed
        rateFrames = 0; rateWindowStart = now
        let standards: [Double] = [16000, 22050, 24000, 32000, 44100, 48000]
        // Ignore a window that lands nowhere near a real rate (still silence-polluted).
        guard let snapped = standards.min(by: { abs($0 - measured) < abs($1 - measured) }),
              abs(snapped - measured) / snapped < 0.1 else { return }
        if abs(snapped - inputRate) / inputRate > 0.05 {
            log("tap delivering ~\(Int(measured))/s (\(Int(snapped))); converter was \(Int(inputRate)), rebuilding")
            applyRate(snapped)
        }
    }

    private func startMic() {
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { captureMic = false; return }   // fall back to system-only
        micConverter = AVAudioConverter(from: inFmt, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            guard let self, let conv = self.micConverter else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFmt.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: cap) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return buf
            }
            self.append(out, to: \.micBuf)
        }
        do { try engine.start() } catch { captureMic = false; FileHandle.standardError.write("mic start failed: \(error)\n".data(using: .utf8)!) }
    }

    private func append(_ pcm: AVAudioPCMBuffer, to key: ReferenceWritableKeyPath<AudioCapture, [Float]>) {
        guard let ch = pcm.floatChannelData?[0] else { return }
        let n = Int(pcm.frameLength)
        guard n > 0 else { return }
        lock.lock(); self[keyPath: key].append(contentsOf: UnsafeBufferPointer(start: ch, count: n)); lock.unlock()
    }

    // Mix the two buffers in lockstep, track loudness, and emit.
    private func startMixer() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let n = self.captureMic ? min(self.systemBuf.count, self.micBuf.count) : self.systemBuf.count
            guard n > 0 else { self.lock.unlock(); return }
            var out = [Float](repeating: 0, count: n)
            var sumsq: Float = 0
            for i in 0..<n {
                var v = self.systemBuf[i]
                if self.captureMic && i < self.micBuf.count { v += self.micBuf[i] }
                v = max(-1, min(1, v))
                out[i] = v
                sumsq += v * v
            }
            self.systemBuf.removeFirst(n)
            if self.captureMic { self.micBuf.removeFirst(min(n, self.micBuf.count)) }
            if (sumsq / Float(n)).squareRoot() > 0.004 { self.lastAudioRef = Date().timeIntervalSinceReferenceDate }
            self.lock.unlock()
            self.onFrames?(out)
        }
        t.resume(); timer = t
    }

    private static func deviceUID(_ dev: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        withUnsafeMutablePointer(to: &uid) { _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        return (uid as String?) ?? ""
    }
}
