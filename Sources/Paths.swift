import Foundation

// Every file Remark reads or writes at runtime lives under one root. Centralized here so the
// location can change in one place (e.g. to ~/Library/Application Support/Remark) without
// hunting through the code.
enum Paths {
    static let root = "\(NSHomeDirectory())/remark"
    static var models = "\(root)/models"
    static var parakeet = "\(root)/models/parakeet"
    static var context = "\(root)/context"
    static var log = "\(root)/remark.log"
    static var learnings = "\(root)/learnings.md"
    static var journal = "\(root)/journal"
    static var sidecar = "\(root)/sidecar"
}
