import XCTest
import FOHCore
@testable import FOHMacKit

final class AudioOutputTapPlanTests: XCTestCase {
    let scarlett = OutputDeviceInfo(uid: "AppleUSBAudioEngine:Focusrite:Scarlett 18i20 USB:X:1,2", name: "Scarlett 18i20 USB",
                                    streamChannels: [18])
    let speakers = OutputDeviceInfo(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", streamChannels: [2])
    let multiStream = OutputDeviceInfo(uid: "dante", name: "Dante Virtual Soundcard", streamChannels: [2, 8, 8])
    let inputOnly = OutputDeviceInfo(uid: "mic", name: "MacBook Pro Microphone", streamChannels: [])

    func testUsesMainStagesDevicePerChannel() {
        let plan = OutputTapPlan.choose(preferredUID: scarlett.uid, preferredName: "Scarlett 18i20 USB",
                                        defaultOutputUID: speakers.uid, devices: [speakers, scarlett])
        XCTAssertEqual(plan.mode, .perChannel)
        XCTAssertEqual(plan.deviceUID, scarlett.uid)
        XCTAssertEqual(plan.channelCount, 18)
        XCTAssertNil(plan.note)
        XCTAssertEqual(plan.summary, "per-channel 18 ch on Scarlett 18i20 USB")
    }

    func testMatchesByNameWhenTheUIDChanged() {
        let plan = OutputTapPlan.choose(preferredUID: "old-uid", preferredName: "Scarlett 18i20 USB",
                                        defaultOutputUID: speakers.uid, devices: [speakers, scarlett])
        XCTAssertEqual(plan.deviceUID, scarlett.uid)
    }

    func testFallsBackToTheSystemOutputWhenMainStagesDeviceIsMissing() {
        // Today on this Mac: MainStage prefers a Scarlett 2i2 that isn't plugged in.
        let plan = OutputTapPlan.choose(preferredUID: "AppleUSBAudioEngine:Focusrite:Scarlett 2i2 USB:P5K8HZW9300993:1,2",
                                        preferredName: "Scarlett 2i2 USB", defaultOutputUID: speakers.uid,
                                        devices: [inputOnly, speakers])
        XCTAssertEqual(plan.mode, .perChannel)
        XCTAssertEqual(plan.deviceName, "MacBook Pro Speakers")
        XCTAssertEqual(plan.channelCount, 2)
        XCTAssertEqual(plan.note, "MainStage's device Scarlett 2i2 USB isn't connected — using the system output MacBook Pro Speakers")
    }

    func testMixdownAfterAPerChannelFailure() {
        let plan = OutputTapPlan.choose(preferredUID: scarlett.uid, preferredName: nil, defaultOutputUID: nil,
                                        devices: [scarlett], perChannelFailed: [scarlett.uid])
        XCTAssertEqual(plan.mode, .mixdown)
        XCTAssertEqual(plan.deviceName, "Scarlett 18i20 USB")
        XCTAssertEqual(plan.channelCount, 2)
        XCTAssertTrue(plan.summary.hasPrefix("stereo mixdown"))
    }

    func testNoOutputDevice() {
        let plan = OutputTapPlan.choose(preferredUID: nil, preferredName: nil, defaultOutputUID: nil, devices: [inputOnly])
        XCTAssertEqual(plan.mode, .mixdown)
        XCTAssertNil(plan.deviceUID)
    }

    func testMultiStreamChannelMapping() {
        let plan = OutputTapPlan.choose(preferredUID: multiStream.uid, preferredName: nil, defaultOutputUID: nil, devices: [multiStream])
        XCTAssertEqual(plan.streams, [2, 8, 8])
        XCTAssertEqual(plan.streamOffsets, [0, 2, 10])
        XCTAssertEqual(plan.channelCount, 18)
    }

    func testAsMixdownKeepsTheDevice() {
        let plan = OutputTapPlan.choose(preferredUID: scarlett.uid, preferredName: nil, defaultOutputUID: nil, devices: [scarlett])
        let fallback = plan.asMixdown(reason: "per-channel tap failed")
        XCTAssertEqual(fallback.mode, .mixdown)
        XCTAssertEqual(fallback.deviceUID, scarlett.uid)
        XCTAssertEqual(fallback.note, "per-channel tap failed")
    }

    func testMainStagePreferencesParsing() {
        let parsed = MainStagePreferences.parse(
            hardware: ["CurrentCoreAudioDeviceUID": "AppleUSBAudioEngine:Focusrite:Scarlett 2i2 USB:P5K8HZW9300993:1,2",
                       "CurrentCoreAudioInputDeviceUID": "other"],
            outputDriverName: "Scarlett 2i2 USB")
        XCTAssertEqual(parsed.outputUID, "AppleUSBAudioEngine:Focusrite:Scarlett 2i2 USB:P5K8HZW9300993:1,2")
        XCTAssertEqual(parsed.outputName, "Scarlett 2i2 USB")
        XCTAssertEqual(MainStagePreferences.parse(hardware: nil, outputDriverName: "").outputName, nil)
    }

    /// Per-channel frames line up with output strips: "Out 3-4" reads tap channels 2 and 3.
    func testFrameChannelsMapToOutputStrips() {
        let frame = MeterFrame(outputPeak: [10, 20, 30, 40], outputRMS: [1, 2, 3, 4])
        let output1 = Strip(ref: .output(2), name: "Output 1", color: .white, stereo: true, hardwareIO: "Out 3-4")
        let output2 = Strip(ref: .output(3), name: "Output 2", color: .white, hardwareIO: "Out 2")
        XCTAssertEqual(frame.peak(for: output1), [30, 40])
        XCTAssertEqual(frame.peak(for: output2), [20])
    }
}
