// Auto-detect: a meeting is on when a known meeting app OR a browser is actively
// using the mic (Core Audio per-process input), polled a few times a second.
// This ignores background mic users — Siri/CoreSpeech, Wispr dictation, a CLI —
// that the old device-global "mic is live" signal falsely counted, and it stops
// promptly when the call's app releases the mic. Reading process state needs no
// mic permission beyond the app's existing audio entitlement.
import AppKit
import CoreAudio

final class MeetingDetector {
    var onChange: ((Bool) -> Void)?
    private(set) var inMeeting = false
    private var startWork: DispatchWorkItem?
    private var stopWork: DispatchWorkItem?
    private var poll: Timer?
    private let onset: TimeInterval = 8     // a meeting app must hold the mic this long to count
    private let endGrace: TimeInterval = 4  // and release it this long to end

    private static let apps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "com.apple.FaceTime", "com.webex.meetingmanager",
    ]
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]

    func start() {
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.evaluate() }
        evaluate()
    }

    // Is a meeting app / browser the one actually using the mic right now?
    private func qualifies() -> Bool {
        for o in Self.procList() where Self.isRunningInput(o) {
            let b = Self.bundleID(o)
            if Self.apps.contains(b) || Self.browsers.contains(b) { return true }
        }
        return false
    }

    func evaluate() {
        if qualifies() {
            stopWork?.cancel(); stopWork = nil
            guard !inMeeting, startWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.startWork = nil
                if self.qualifies() { self.inMeeting = true; self.onChange?(true) }
            }
            startWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + onset, execute: w)
        } else {
            startWork?.cancel(); startWork = nil
            guard inMeeting, stopWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stopWork = nil
                if !self.qualifies() { self.inMeeting = false; self.onChange?(false) }
            }
            stopWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + endGrace, execute: w)
        }
    }

    private static func procList() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        let n = Int(size) / MemoryLayout<AudioObjectID>.size
        guard n > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: n)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids
    }

    private static func isRunningInput(_ o: AudioObjectID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(o, &a, 0, nil, &s, &v); return v != 0
    }

    private static func bundleID(_ o: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString? = nil; var s = UInt32(MemoryLayout<CFString?>.size)
        withUnsafeMutablePointer(to: &cf) { _ = AudioObjectGetPropertyData(o, &a, 0, nil, &s, $0) }
        return (cf as String?) ?? ""
    }
}
