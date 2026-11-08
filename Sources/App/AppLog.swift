import Foundation
import Combine

/// Main-actor event ring used by the app shell.
///
/// This is deliberately independent from `RecorderEngine`'s internal event
/// array: the Core layer does not expose its events, so the shell records the
/// actions it takes and the diagnostics it observes from `LiveSnapshot`.
@MainActor
final class AppLog: ObservableObject {
    enum Level: String, Codable {
        case info
        case success
        case warning
        case error
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    static let capacity = 200

    @Published private(set) var entries: [Entry] = []

    func add(_ message: String, level: Level = .info) {
        entries.append(Entry(date: Date(), level: level, message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return entries.map {
            "\(formatter.string(from: $0.date)) [\($0.level.rawValue.uppercased())] \($0.message)"
        }
        .joined(separator: "\n")
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let text = exportText() + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
