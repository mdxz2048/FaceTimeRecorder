import Foundation
import CoreMedia
import AudioToolbox

/// Consumes ScreenCaptureKit's system-audio sample buffers and writes a
/// 48 kHz stereo Float32 WAV. SCK audio is captured before the output device,
/// so it records FaceTime even when the call plays through the Mac speakers.
public final class SystemAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: WAVWriter
    private var frames: UInt64 = 0
    private var silentFrames: UInt64 = 0
    private var sumSquares: Double = 0
    private var peak: Float = 0
    private var formatDescription: String = "unknown"
    private var lastError: String?

    public init(url: URL) throws {
        writer = try WAVWriter(url: url, sampleRate: 48_000, channels: 2)
    }

    public func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return
        }
        let asbd = asbdPointer.pointee
        lock.lock()
        formatDescription = "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, flags=\(asbd.mFormatFlags)"
        lock.unlock()

        var blockBuffer: CMBlockBuffer?
        let bufferListPointer = AudioBufferList.allocate(maximumBuffers: 8)
        defer { free(bufferListPointer.unsafeMutablePointer) }
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 8),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, bufferListPointer.count > 0 else {
            lock.lock(); lastError = "audio buffer list \(status)"; lock.unlock()
            return
        }
        let buffers = bufferListPointer
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels == 2 || channels == 1 else {
            lock.lock(); lastError = "unsupported channels \(channels)"; lock.unlock()
            return
        }
        let frameCount = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * max(Int(buffers[0].mNumberChannels), 1))
        guard frameCount > 0 else { return }

        var stereo = [Float](repeating: 0, count: frameCount * 2)
        if buffers.count == 1, let raw = buffers[0].mData {
            let source = raw.assumingMemoryBound(to: Float.self)
            let sourceChannels = Int(buffers[0].mNumberChannels)
            for frame in 0..<frameCount {
                let left = source[frame * sourceChannels]
                let right = sourceChannels > 1 ? source[frame * sourceChannels + 1] : left
                stereo[frame * 2] = left
                stereo[frame * 2 + 1] = right
            }
        } else if buffers.count >= 2,
                  let leftRaw = buffers[0].mData,
                  let rightRaw = buffers[1].mData {
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                stereo[frame * 2] = left[frame]
                stereo[frame * 2 + 1] = right[frame]
            }
        } else {
            return
        }

        var localPeak: Float = 0
        var nonzero = false
        for value in stereo {
            if value != 0 { nonzero = true }
            sumSquares += Double(value * value)
            localPeak = max(localPeak, abs(value))
        }
        lock.lock()
        frames += UInt64(frameCount)
        if !nonzero { silentFrames += UInt64(frameCount) }
        peak = max(peak, localPeak)
        try? writer.write(stereo, frames: frameCount)
        lock.unlock()
    }

    public func stop() -> RemoteRecorderStats {
        try? writer.close()
        lock.lock()
        var result = RemoteRecorderStats()
        result.frames = frames
        result.silentFrames = silentFrames
        result.wavFrames = writer.framesWritten
        result.channelRMS = frames > 0
            ? [Float(sqrt(sumSquares / Double(frames * 2))),
               Float(sqrt(sumSquares / Double(frames * 2)))]
            : []
        result.channelPeak = [peak, peak]
        result.captureFormat = "ScreenCaptureKit system audio: \(formatDescription)"
        if let lastError { result.captureFormat += " (\(lastError))" }
        lock.unlock()
        return result
    }

    public var snapshot: RemoteRecorderStats {
        lock.lock()
        defer { lock.unlock() }
        var result = RemoteRecorderStats()
        result.frames = frames
        result.silentFrames = silentFrames
        result.wavFrames = writer.framesWritten
        result.channelRMS = frames > 0
            ? [Float(sqrt(sumSquares / Double(frames * 2))),
               Float(sqrt(sumSquares / Double(frames * 2)))]
            : []
        result.channelPeak = [peak, peak]
        result.captureFormat = "ScreenCaptureKit system audio: \(formatDescription)"
        return result
    }
}
