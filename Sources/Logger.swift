import Foundation

// Appends events to ~/remark/remark.log so a failed session can be diagnosed after the fact.
// Never writes transcript text. Trims itself so it can't grow without bound.
enum Log {
    private static let path = "\(NSHomeDirectory())/remark/remark.log"
    private static let q = DispatchQueue(label: "remark.log")
    private static let iso = ISO8601DateFormatter()

    static func event(_ m: String) {
        FileHandle.standardError.write(Data(("[remark] " + m + "\n").utf8))
        let line = "\(iso.string(from: Date())) \(m)\n"
        q.async {
            let url = URL(fileURLWithPath: path)
            if let h = try? FileHandle(forWritingTo: url) {
                try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
            } else {
                try? FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
               size > 1_000_000, let data = try? Data(contentsOf: url) {
                try? data.suffix(500_000).write(to: url)
            }
        }
    }
}

// The pipeline logs through this. Routed to the file + stderr.
func log(_ m: String) { Log.event(m) }
