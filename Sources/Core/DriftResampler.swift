import Foundation

/// Stereo, linear-interpolating resampler with a slow ratio trim. It keeps the
/// monitoring ring near a target fill so that the virtual device clock and the
/// physical output clock can drift without growing latency or underrunning.
public final class DriftResampler {
    public var targetFillFrames: Int
    public var minimumFillFrames: Int
    public var maximumFillFrames: Int
    public var maximumRatioTrim: Double = 0.01

    private var phase: Double = 0
    private var ratio: Double = 1
    private var scratch: [Float]
    private let channels = 2

    public private(set) var lastRatio: Double = 1
    public private(set) var underrunFrames: UInt64 = 0

    public init(maxFrames: Int = 8_192, sampleRate: Double = 48_000) {
        targetFillFrames = Int(sampleRate * 0.15)
        minimumFillFrames = Int(sampleRate * 0.06)
        maximumFillFrames = Int(sampleRate * 0.30)
        scratch = [Float](repeating: 0, count: maxFrames * channels)
    }

    public func reset() {
        phase = 0
        ratio = 1
        lastRatio = 1
    }

    public func process(ring: OpaquePointer, out: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let available = Int(fr_sample_ring_available(ring))
        updateRatio(available: available)

        let needed = Int(ceil(phase + Double(frames) * ratio)) + 2
        let peekable = min(needed, scratch.count / channels)
        var got = 0
        scratch.withUnsafeMutableBufferPointer { pointer in
            got = Int(fr_sample_ring_peek(ring, 0, pointer.baseAddress!,
                                          UInt32(peekable)))
        }
        if got < needed {
            underrunFrames += UInt64(needed - got)
            for index in got..<peekable {
                scratch[index * 2] = 0
                scratch[index * 2 + 1] = 0
            }
        }

        var position = phase
        let lastIndex = max(peekable - 2, 0)
        for frame in 0..<frames {
            let base = min(Int(position), lastIndex)
            let frac = Float(position - Double(base))
            let l0 = scratch[base * 2]
            let l1 = scratch[(base + 1) * 2]
            let r0 = scratch[base * 2 + 1]
            let r1 = scratch[(base + 1) * 2 + 1]
            out[frame * 2] = l0 + (l1 - l0) * frac
            out[frame * 2 + 1] = r0 + (r1 - r0) * frac
            position += ratio
        }
        let consumed = Int(position)
        if consumed > 0 {
            fr_sample_ring_advance(ring, UInt32(min(consumed, got)))
            position -= Double(consumed)
        }
        phase = position
    }

    private func updateRatio(available: Int) {
        let error = Double(available - targetFillFrames) / Double(max(targetFillFrames, 1))
        let desired = 1 + max(-maximumRatioTrim, min(maximumRatioTrim, error * 0.05))
        ratio += (desired - ratio) * 0.02
        lastRatio = ratio
    }
}
