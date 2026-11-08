import XCTest
import CoreAudio

/// Offline tests for the label-based FL/FR selection used by the remote
/// downmix. The actual sample-copy loop lives in a private method that needs a
/// live tap, so this file tests the public, pure mapping plus the Core Audio
/// label-to-name conversion.
final class DownmixTests: XCTestCase {

    func testHomePodFlowEightChannelLayoutSelectsFirstTwo() {
        let labels = ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"]
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: labels, channels: 8)
        XCTAssertEqual(indices.0, 0)
        XCTAssertEqual(indices.1, 1)
        XCTAssertNotEqual(indices.0, 4, "BL must not be treated as left")
        XCTAssertNotEqual(indices.1, 5, "BR must not be treated as right")
    }

    func testCanonicalSevenOneOrderStillSelectsFLFR() {
        let labels = ["FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"]
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: labels, channels: 8)
        XCTAssertEqual(indices.0, 0)
        XCTAssertEqual(indices.1, 1)
    }

    func testSelectionFollowsLabelsWhenFLFRAreNotFirst() {
        let labels = ["FC", "LFE", "FL", "FR", "BL", "BR", "SL", "SR"]
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: labels, channels: 8)
        XCTAssertEqual(indices.0, 2)
        XCTAssertEqual(indices.1, 3)
    }

    func testSelectionFindsFLFRAtTheEnd() {
        let labels = ["SL", "SR", "BL", "BR", "FC", "LFE", "FL", "FR"]
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: labels, channels: 8)
        XCTAssertEqual(indices.0, 6)
        XCTAssertEqual(indices.1, 7)
    }

    func testSelectionIsCaseInsensitive() {
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: ["fl", "fr", "fc"],
                                                             channels: 3)
        XCTAssertEqual(indices.0, 0)
        XCTAssertEqual(indices.1, 1)
    }

    func testSelectionAcceptsLongNames() {
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: ["Left", "Right"],
                                                             channels: 2)
        XCTAssertEqual(indices.0, 0)
        XCTAssertEqual(indices.1, 1)
    }

    func testMonoDuplicatesChannelZero() {
        let withLabel = RemoteAudioRecorder.frontStereoIndices(labels: ["M"], channels: 1)
        XCTAssertEqual(withLabel.0, 0)
        XCTAssertEqual(withLabel.1, 0)

        let withoutLabel = RemoteAudioRecorder.frontStereoIndices(labels: [], channels: 1)
        XCTAssertEqual(withoutLabel.0, 0)
        XCTAssertEqual(withoutLabel.1, 0)
    }

    func testMissingLabelsFallBackToFirstTwoChannels() {
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: [], channels: 8)
        XCTAssertEqual(indices.0, 0)
        XCTAssertEqual(indices.1, 1)
    }

    func testSwappedLabelsAreHonoured() {
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: ["FR", "FL"], channels: 2)
        XCTAssertEqual(indices.0, 1)
        XCTAssertEqual(indices.1, 0)
    }

    func testIndicesAreClampedToChannelCount() {
        let indices = RemoteAudioRecorder.frontStereoIndices(labels: ["FC", "FL", "FR"],
                                                             channels: 2)
        XCTAssertEqual(indices.0, 1)
        XCTAssertEqual(indices.1, 1, "FR is at index 2 but only two channels exist")

        let mono = RemoteAudioRecorder.frontStereoIndices(labels: ["FL", "FR"], channels: 1)
        XCTAssertEqual(mono.0, 0)
        XCTAssertEqual(mono.1, 0)
    }

    func testCoreAudioLabelNamesMatchDeviceVocabulary() {
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_Left), "FL")
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_Right), "FR")
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_Center), "FC")
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_LFEScreen), "LFE")
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_LeftSurroundDirect), "BL")
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_RightSurroundDirect), "BR")
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_LeftSurround), "SL")
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_RightSurround), "SR")
        XCTAssertEqual(AudioDeviceCatalog.labelName(kAudioChannelLabel_Mono), "M")
    }
}
