import Foundation

public enum WAVWriterError: Error, CustomStringConvertible {
    case cannotCreate(String)
    case writeFailed(String)
    case closed

    public var description: String {
        switch self {
        case let .cannotCreate(path): return "cannot create WAV at \(path)"
        case let .writeFailed(reason): return "WAV write failed: \(reason)"
        case .closed: return "WAV writer is closed"
        }
    }
}

/// Streaming 32-bit float WAV writer. The header is written up-front and the
/// two size fields are patched on close. All calls are made from one worker
/// thread; a lock keeps accidental concurrent use from corrupting the file.
public final class WAVWriter {
    public let url: URL
    public let sampleRate: Double
    public let channels: Int
    public private(set) var framesWritten: UInt64 = 0

    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    public init(url: URL, sampleRate: Double, channels: Int) throws {
        guard channels > 0, channels <= 32, sampleRate > 0 else {
            throw WAVWriterError.cannotCreate(url.path)
        }
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        guard manager.createFile(atPath: url.path, contents: nil) else {
            throw WAVWriterError.cannotCreate(url.path)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw WAVWriterError.cannotCreate(url.path)
        }
        self.handle = handle
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate,
                                                 channels: channels,
                                                 dataBytes: 0))
    }

    public func write(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            try write(base, frames: pointer.count / channels)
        }
    }

    public func write(_ samples: [Float], frames: Int) throws {
        try samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            try write(base, frames: frames)
        }
    }

    public func write(_ samples: UnsafePointer<Float>, frames: Int) throws {
        guard frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw WAVWriterError.closed }
        let bytes = frames * channels * MemoryLayout<Float>.size
        let data = Data(bytes: samples, count: bytes)
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw WAVWriterError.writeFailed(error.localizedDescription)
        }
        framesWritten += UInt64(frames)
    }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(framesWritten) / sampleRate : 0
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let dataBytes = framesWritten * UInt64(channels) * 4
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(sampleRate: sampleRate,
                                                     channels: channels,
                                                     dataBytes: dataBytes))
            try handle.synchronize()
            try handle.close()
        } catch {
            throw WAVWriterError.writeFailed(error.localizedDescription)
        }
    }

    deinit { try? close() }

    static func header(sampleRate: Double, channels: Int, dataBytes: UInt64) -> Data {
        let byteRate = UInt32(sampleRate) * UInt32(channels) * 4
        let blockAlign = UInt16(channels * 4)
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func appendU32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendU16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let riffSize = UInt32(min(dataBytes + 36, UInt64(UInt32.max)))
        let dataSize = UInt32(min(dataBytes, UInt64(UInt32.max)))
        appendASCII("RIFF")
        appendU32(riffSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(3)                       // WAVE_FORMAT_IEEE_FLOAT
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(32)
        appendASCII("data")
        appendU32(dataSize)
        return data
    }
}

public struct WAVHeaderInfo: Codable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerSample: Int
    public let dataBytes: UInt64

    public var durationSeconds: Double {
        let bytesPerFrame = max(channels * bitsPerSample / 8, 1)
        return Double(dataBytes) / (sampleRate * Double(bytesPerFrame))
    }
}

public enum WAVReader {
    public static func info(url: URL) throws -> WAVHeaderInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 12) ?? Data()
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw WAVWriterError.writeFailed("not a RIFF/WAVE file")
        }
        var sampleRate = 0.0
        var channels = 0
        var bits = 0
        var dataBytes: UInt64 = 0
        while true {
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            let id = String(data: header[0..<4], encoding: .ascii) ?? ""
            let size = header[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if id == "fmt " {
                guard let chunk = try handle.read(upToCount: Int(size)), chunk.count >= 16 else { break }
                channels = Int(chunk[2..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
                sampleRate = Double(chunk[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                bits = Int(chunk[14..<16].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
                if Int(size) > 16 { try handle.seek(toOffset: handle.offsetInFile + UInt64(Int(size) - 16)) }
            } else if id == "data" {
                dataBytes = UInt64(size)
                break
            } else {
                try handle.seek(toOffset: handle.offsetInFile + UInt64(size))
            }
        }
        return WAVHeaderInfo(sampleRate: sampleRate, channels: channels,
                             bitsPerSample: bits, dataBytes: dataBytes)
    }
}
