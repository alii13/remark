// Encrypted, on-device memory of past meetings. Each meeting is one immutable, encrypted
// record. The profile (recurring topics, open threads) is derived from those records on
// demand — never stored — so there is nothing to corrupt and it rebuilds itself. The AES-GCM
// key lives in the login Keychain and survives re-signed rebuilds. Raw audio never leaves the
// machine; distilled text does, via the question model.
import Foundation
import Security
import CryptoKit

struct MeetingRecord: Codable {
    var v = 1
    let at: String              // ISO8601, also the file name
    let type: String            // "architecture review", "1:1", "incident", ...
    let topics: [String]
    let decisions: [String]
    let openThreads: [String]
    let finalCount: Int
}

struct ContextThread: Codable { let text: String; var firstSeen: String; var lastSeen: String }

struct Profile {
    var topics: [String] = []
    var decisions: [String] = []
    var typesSeen: [String] = []
    var threads: [ContextThread] = []
}

enum ContextStore {
    static var root = Paths.context
    static var meetingsDir: String { "\(root)/meetings" }
    private static let threadTTL: TimeInterval = 14 * 86400   // open threads expire after two weeks
    private static let service = "com.shekh.remark"
    private static let account = "context-key"
    private static let queue = DispatchQueue(label: "remark.context")

    private static var keyCache: SymmetricKey?
    private static let keyLock = NSLock()

    // Get-or-create a 256-bit key in the login keychain. A read that fails for any reason other
    // than "not found" returns nil (store disabled for now) WITHOUT caching, so a transient
    // failure doesn't disable memory for the whole run. A new key is never minted over a failed
    // read — that would make every existing record undecryptable.
    private static func key() -> SymmetricKey? {
        keyLock.lock(); defer { keyLock.unlock() }
        if let k = keyCache { return k }
        let read: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecReturnData as String: true]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(read as CFDictionary, &out)
        if st == errSecSuccess, let d = out as? Data { let k = SymmetricKey(data: d); keyCache = k; return k }
        guard st == errSecItemNotFound else { return nil }
        let k = SymmetricKey(size: .bits256)
        let raw = k.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account,
                                  kSecValueData as String: raw,
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        keyCache = k; return k
    }

    private static func seal(_ data: Data) -> Data? {
        guard let key = key() else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }
    private static func open(_ data: Data) -> Data? {
        guard let key = key(), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    // One immutable encrypted file per meeting.
    static func save(_ r: MeetingRecord) {
        queue.sync {
            guard let json = try? JSONEncoder().encode(r), let enc = seal(json) else { return }
            try? FileManager.default.createDirectory(atPath: meetingsDir, withIntermediateDirectories: true)
            let name = r.at.replacingOccurrences(of: ":", with: "-")
            try? enc.write(to: URL(fileURLWithPath: "\(meetingsDir)/\(name).json.enc"), options: .atomic)
        }
    }

    // Derive the profile by folding every record oldest-to-newest. Cheap (tens of small files),
    // called once per meeting. Threads carry dates and expire by age.
    static func loadProfile() -> Profile {
        var p = Profile()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: meetingsDir) else { return p }
        // ISO filenames sort chronologically; fold only the most recent records (threads expire
        // at 14 days and topics are recency-capped, so older files can't change the brief).
        let recent = files.filter { $0.hasSuffix(".json.enc") }.sorted().suffix(80)
        let records: [MeetingRecord] = recent.compactMap { f in
            guard let enc = try? Data(contentsOf: URL(fileURLWithPath: "\(meetingsDir)/\(f)")),
                  let dec = open(enc) else { return nil }
            return try? JSONDecoder().decode(MeetingRecord.self, from: dec)
        }
        var threads: [ContextThread] = []
        for r in records {
            p.topics = dedupeCap(r.topics + p.topics, 24)
            p.decisions = dedupeCap(r.decisions + p.decisions, 10)
            p.typesSeen = dedupeCap([r.type] + p.typesSeen, 12)
            for t in r.openThreads where !t.isEmpty {
                if let i = threads.firstIndex(where: { $0.text.caseInsensitiveCompare(t) == .orderedSame }) {
                    threads[i].lastSeen = r.at
                } else {
                    threads.append(ContextThread(text: t, firstSeen: r.at, lastSeen: r.at))
                }
            }
        }
        let cutoff = Date().addingTimeInterval(-threadTTL)
        let iso = ISO8601DateFormatter()
        p.threads = Array(threads.filter { (iso.date(from: $0.lastSeen) ?? Date()) >= cutoff }.suffix(24))
        return p
    }

    private static func dedupeCap(_ xs: [String], _ cap: Int) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs {
            let s = x.trimmingCharacters(in: .whitespaces)
            let k = s.lowercased()
            if s.isEmpty || seen.contains(k) { continue }
            seen.insert(k); out.append(s)
            if out.count >= cap { break }
        }
        return out
    }

    // The compact memory handed to the question model, over stdin (never argv).
    static func brief() -> String {
        let p = loadProfile()
        if p.topics.isEmpty && p.threads.isEmpty { return "" }
        var s = "What I know from past meetings (use only if it fits what's being said now, never force it):\n"
        if !p.topics.isEmpty { s += "Recurring topics: " + p.topics.prefix(12).joined(separator: ", ") + "\n" }
        if !p.decisions.isEmpty { s += "Decided earlier: " + p.decisions.prefix(5).joined(separator: "; ") + "\n" }
        if !p.typesSeen.isEmpty { s += "Meeting types seen before: " + p.typesSeen.prefix(6).joined(separator: ", ") + "\n" }
        if !p.threads.isEmpty {
            s += "Open threads from earlier meetings (ask a follow-up only if the same thing resurfaces now):\n"
            s += p.threads.suffix(8).map { "- \($0.text) (last came up \(shortDate($0.lastSeen)))" }.joined(separator: "\n")
        }
        return s
    }

    private static func shortDate(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return "recently" }
        let out = DateFormatter(); out.dateFormat = "MMM d"
        return out.string(from: d)
    }
}
