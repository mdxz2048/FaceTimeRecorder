import XCTest

/// Offline tests for DriftResampler. The resampler only touches an SPSC ring,
/// so these tests run without Core Audio or TCC.
final class DriftResamplerTests: XCTestCase {

    private func makeRing(capacity: UInt32 = 48_000) throws -> OpaquePointer {
        try XCTUnwrap(fr_sample_ring_create(capacity, 2))
    }

    @discardableResult
    private func fill(_ ring: OpaquePointer,
                      frames: Int,
                      left: (Int) -> Float = { Float($0) * 0.001 },
                      right: ((Int) -> Float)? = nil) -> UInt32 {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            samples[frame * 2] = left(frame)
            samples[frame * 2 + 1] = right?(frame) ?? -left(frame)
        }
        return samples.withUnsafeBufferPointer {
            fr_sample_ring_write(ring, $0.baseAddress!, UInt32(frames))
        }
    }

    private func process(_ resampler: DriftResampler,
                         ring: OpaquePointer,
                         frames: Int) -> [Float] {
        // Keep a non-nil base address for frames == 0.
        var output = [Float](repeating: 0, count: max(frames * 2, 2))
        output.withUnsafeMutableBufferPointer {
            resampler.process(ring: ring, out: $0.baseAddress!, frames: frames)
        }
        return output
    }

    func testPassthroughAtTargetFillHasUnityRatio() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }
        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)

        XCTAssertEqual(resampler.targetFillFrames, 7_200)
        XCTAssertEqual(fill(ring, frames: 7_200), 7_200)

        let output = process(resampler, ring: ring, frames: 480)
        XCTAssertEqual(resampler.underrunFrames, 0)
        XCTAssertEqual(resampler.lastRatio, 1.0, accuracy: 1e-12)

        // Phase starts at zero and ratio is exactly one, so output frame i must
        // equal input frame i.
        for frame in 0..<480 {
            XCTAssertEqual(output[frame * 2], Float(frame) * 0.001, accuracy: 1e-7)
            XCTAssertEqual(output[frame * 2 + 1], -Float(frame) * 0.001, accuracy: 1e-7)
        }
        XCTAssertEqual(fr_sample_ring_available(ring), 7_200 - 480)
    }

    func testOverfillTrimsRatioAboveOne() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }

        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
        resampler.targetFillFrames = 1_000
        resampler.minimumFillFrames = 500
        resampler.maximumFillFrames = 3_000
        resampler.maximumRatioTrim = 0.01

        XCTAssertEqual(fill(ring, frames: 4_000), 4_000)
        let output = process(resampler, ring: ring, frames: 100)

        // error = 3.0 -> desired = 1.01 -> first smoothed ratio = 1.0002
        XCTAssertEqual(resampler.lastRatio, 1.0002, accuracy: 1e-9)
        XCTAssertEqual(output[0], 0, accuracy: 1e-12)
        // Frame 1 is interpolated at 1.0002, not exactly at 1.0.
        XCTAssertEqual(output[2], 0.0010002, accuracy: 1e-6)
        XCTAssertEqual(fr_sample_ring_available(ring), 3_900)
    }

    func testUnderfillTrimsRatioBelowOne() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }

        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
        resampler.targetFillFrames = 1_000
        resampler.maximumRatioTrim = 0.01

        XCTAssertEqual(fill(ring, frames: 100), 100)
        _ = process(resampler, ring: ring, frames: 100)

        // error = -0.9 -> desired = 0.99 -> smoothed ratio = 0.9998
        XCTAssertEqual(resampler.lastRatio, 0.9998, accuracy: 1e-9)
        XCTAssertEqual(resampler.underrunFrames, 2)
    }

    func testUnderrunFillsZerosAndCountsMissingFrames() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }

        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
        resampler.targetFillFrames = 1_000

        let output = process(resampler, ring: ring, frames: 64)
        XCTAssertEqual(fr_sample_ring_available(ring), 0)
        XCTAssertEqual(resampler.underrunFrames, 66,
                       "64 requested frames plus two guard frames")
        XCTAssertEqual(output.count, 128)
        XCTAssertTrue(output.allSatisfy { $0 == 0 }, "underrun must be filled with silence")
        XCTAssertLessThan(resampler.lastRatio, 1.0)
    }

    func testZeroFrameRequestIsNoOp() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }
        fill(ring, frames: 100)

        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
        _ = process(resampler, ring: ring, frames: 0)

        XCTAssertEqual(resampler.underrunFrames, 0)
        XCTAssertEqual(resampler.lastRatio, 1.0)
        XCTAssertEqual(fr_sample_ring_available(ring), 100)
    }

    func testHugeRequestIsClampedToScratchAndDoesNotCrash() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }
        fill(ring, frames: 20_000)

        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
        let output = process(resampler, ring: ring, frames: 100_000)

        XCTAssertEqual(output.count, 200_000)
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(resampler.underrunFrames, 90_000)
    }

    func testTinyScratchDoesNotCrash() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }
        fill(ring, frames: 100)

        let resampler = DriftResampler(maxFrames: 4, sampleRate: 48_000)
        let output = process(resampler, ring: ring, frames: 100)

        XCTAssertEqual(output.count, 200)
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
        XCTAssertEqual(resampler.underrunFrames, 98)
    }

    func testRatioNeverExceedsMaximumTrim() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }

        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
        resampler.targetFillFrames = 1_000
        resampler.maximumRatioTrim = 0.01
        fill(ring, frames: 4_000)

        for _ in 0..<200 {
            _ = process(resampler, ring: ring, frames: 100)
            // Keep the ring overfull so the trim stays saturated.
            fill(ring, frames: 100)
        }

        XCTAssertLessThanOrEqual(resampler.lastRatio, 1.0100001)
        XCTAssertGreaterThan(resampler.lastRatio, 1.005)
    }

    func testPhaseContinuesAcrossProcessCalls() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }

        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
        resampler.targetFillFrames = 1_000
        fill(ring, frames: 2_000)

        let first = process(resampler, ring: ring, frames: 100)
        XCTAssertEqual(first[0], 0, accuracy: 1e-9)

        let second = process(resampler, ring: ring, frames: 100)
        // The ramp value at input frame 100 is 0.1. The second block must
        // continue near that value, not restart at sample 0.
        XCTAssertEqual(second[0], 0.10002, accuracy: 1e-4)
    }

    func testResetRestoresUnityRatio() throws {
        let ring = try makeRing()
        defer { fr_sample_ring_destroy(ring) }

        let resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
        resampler.targetFillFrames = 1_000
        fill(ring, frames: 4_000)
        _ = process(resampler, ring: ring, frames: 100)
        XCTAssertGreaterThan(resampler.lastRatio, 1.0)

        resampler.reset()
        XCTAssertEqual(resampler.lastRatio, 1.0)
        XCTAssertEqual(resampler.underrunFrames, 0)
    }
}
