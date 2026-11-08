import XCTest

/// Tests for the public self-test contract. The audio classification itself is
/// embedded in RecorderEngine.runSelfTest and needs a real device tap; only the
/// Code semantics and the deterministic "device not found" path are unit
/// testable without TCC/hardware. See TEST_PLAN for the coverage limitation.
final class SelfTestMappingTests: XCTestCase {

    private func result(_ code: SelfTestResult.Code) -> SelfTestResult {
        SelfTestResult(code: code,
                       detail: "detail-\(code.rawValue)",
                       channelRMS: [0.1, 0.2],
                       channelPeak: [0.3, 0.4],
                       callbacks: 10,
                       frames: 1_024,
                       toneChannelIndices: [0, 1])
    }

    func testCodeRawValuesAreStable() {
        XCTAssertEqual(SelfTestResult.Code.passed.rawValue, "passed")
        XCTAssertEqual(SelfTestResult.Code.noCallbacks.rawValue, "noCallbacks")
        XCTAssertEqual(SelfTestResult.Code.allZero.rawValue, "allZero")
        XCTAssertEqual(SelfTestResult.Code.partialChannels.rawValue, "partialChannels")
        XCTAssertEqual(SelfTestResult.Code.tapError.rawValue, "tapError")
    }

    func testOnlyPassedCodeReportsPassed() {
        let codes: [SelfTestResult.Code] = [.passed, .noCallbacks, .allZero,
                                            .partialChannels, .tapError]
        for code in codes {
            XCTAssertEqual(result(code).passed, code == .passed,
                           "passed must be true only for .passed")
        }
    }

    func testResultPreservesDiagnostics() {
        let value = result(.partialChannels)
        XCTAssertEqual(value.detail, "detail-partialChannels")
        XCTAssertEqual(value.channelRMS, [0.1, 0.2])
        XCTAssertEqual(value.channelPeak, [0.3, 0.4])
        XCTAssertEqual(value.callbacks, 10)
        XCTAssertEqual(value.frames, 1_024)
        XCTAssertEqual(value.toneChannelIndices, [0, 1])
    }

    func testUnknownDeviceProducesTapErrorWithoutTCC() {
        let uid = "qa.invalid.\(UUID().uuidString)"
        let engine = RecorderEngine()
        let outcome = engine.runSelfTest(deviceUID: uid, seconds: 0.02)

        XCTAssertEqual(outcome.code, .tapError)
        XCTAssertFalse(outcome.passed)
        XCTAssertEqual(outcome.callbacks, 0)
        XCTAssertEqual(outcome.frames, 0)
        XCTAssertTrue(outcome.channelRMS.isEmpty)
        XCTAssertTrue(outcome.channelPeak.isEmpty)
        XCTAssertTrue(outcome.toneChannelIndices.isEmpty)
        XCTAssertTrue(outcome.detail.contains("audio device not found"),
                      "unexpected detail: \(outcome.detail)")
    }

    func testUnknownDeviceNeverReportsPassed() {
        let uid = "qa.invalid.\(UUID().uuidString)"
        let engine = RecorderEngine()
        let outcome = engine.runSelfTest(deviceUID: uid, seconds: 0.02)
        XCTAssertNotEqual(outcome.code, .passed)
        XCTAssertFalse(outcome.passed)
    }

    func testSelfTestErrorDescriptionIncludesCodeAndDetail() {
        let failure = RecorderEngineError.selfTestFailed(result(.allZero))
        let description = failure.description
        XCTAssertTrue(description.contains("allZero"))
        XCTAssertTrue(description.contains("detail-allZero"))
    }
}
