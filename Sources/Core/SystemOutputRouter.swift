import Foundation
import CoreAudio
import os

public enum OutputRouterError: Error, CustomStringConvertible {
    case cannotPersistLease(String)
    case restoreFailed(String)

    public var description: String {
        switch self {
        case let .cannotPersistLease(message): return "无法写入默认输出租约：\(message)"
        case let .restoreFailed(message): return "恢复默认输出失败：\(message)"
        }
    }
}

/// Optional, reversible takeover of the system default output. FaceTime renders
/// to the system default, so this is required for its audio to reach the
/// virtual device. The original UID is persisted before the change; restore
/// happens on stop, on termination, and on the next launch after a crash.
public final class SystemOutputRouter: @unchecked Sendable {
    private let log = Logger(subsystem: "com.mdxz.facetime.recorder", category: "output")
    private let lock = NSLock()
    private var activeLease: OutputLease?

    public init() {}

    public var currentDefaultUID: String? {
        AudioDeviceCatalog.defaultOutputUID()
    }

    @discardableResult
    public func takeOver(virtualDeviceUID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = currentDefaultUID
        if current == virtualDeviceUID {
            // Already routed by the user: do not claim ownership.
            return false
        }
        let lease = OutputLease(createdAt: Date(),
                                virtualDeviceUID: virtualDeviceUID,
                                originalDefaultOutputUID: current,
                                didChangeDefaultOutput: true,
                                processIdentifier: ProcessInfo.processInfo.processIdentifier)
        do {
            try persist(lease)
        } catch {
            throw OutputRouterError.cannotPersistLease(error.localizedDescription)
        }
        do {
            try AudioDeviceCatalog.setDefaultOutput(uid: virtualDeviceUID)
        } catch {
            try? FileManager.default.removeItem(at: RecorderPaths.leaseURL)
            throw OutputRouterError.restoreFailed("切换默认输出失败：\(error)")
        }
        activeLease = lease
        log.info("took over default output, original=\(lease.originalDefaultOutputUID ?? "nil", privacy: .public)")
        return true
    }

    public func restoreIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        try restoreLocked()
    }

    /// Called at launch. Restores only when the recorded process is gone.
    public func recoverStaleLease() {
        lock.lock()
        defer { lock.unlock() }
        guard let lease = loadLease() else { return }
        if lease.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           kill(lease.processIdentifier, 0) != 0 {
            log.warning("recovering stale output lease from pid \(lease.processIdentifier)")
            do { try restoreLocked() } catch {
                log.error("stale lease restore failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func restoreLocked() throws {
        guard let lease = activeLease ?? loadLease() else { return }
        guard lease.didChangeDefaultOutput, let original = lease.originalDefaultOutputUID else {
            activeLease = nil
            try? FileManager.default.removeItem(at: RecorderPaths.leaseURL)
            return
        }
        let current = currentDefaultUID
        if current == lease.virtualDeviceUID {
            do {
                try AudioDeviceCatalog.setDefaultOutput(uid: original)
            } catch {
                throw OutputRouterError.restoreFailed("\(error)")
            }
        } else if current != original {
            log.warning("default output changed by user to \(current ?? "nil", privacy: .public); not overriding")
        }
        activeLease = nil
        try? FileManager.default.removeItem(at: RecorderPaths.leaseURL)
    }

    private func persist(_ lease: OutputLease) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: RecorderPaths.supportDirectory,
                                    withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(lease)
        try data.write(to: RecorderPaths.leaseURL, options: .atomic)
    }

    private func loadLease() -> OutputLease? {
        guard let data = try? Data(contentsOf: RecorderPaths.leaseURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OutputLease.self, from: data)
    }
}
