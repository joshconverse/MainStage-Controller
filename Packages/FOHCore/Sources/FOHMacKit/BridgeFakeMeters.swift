#if os(macOS)
import Foundation
import FOHCore

/// Synthetic meters for tests and demos (`fohctl bridge --fake-meters`): moving levels on every input and output
/// and a pink-ish RTA, so the iPad's meters can be exercised without an audio interface or microphone permission.
public final class FakeMeterSource: MeterSource, @unchecked Sendable {
    public var onFrame: (@Sendable (MeterFrame) -> Void)?
    public var onRTA: (@Sendable ([Int], [UInt8]) -> Void)?
    public var inputDeviceName: String? { "Fake meters" }
    public var inputChannelCount: Int? { inputs }
    public var outputTapName: String? { "Fake MainStage" }

    private let inputs: Int
    private let outputs: Int
    private var timer: DispatchSourceTimer?
    private var rtaChannels: [Int] = []
    private var phase = 0.0
    private let queue = DispatchQueue(label: "foh.fake-meters")

    public init(inputs: Int = 18, outputs: Int = 4) {
        self.inputs = inputs
        self.outputs = outputs
    }

    public func start(inputDeviceUID: String?, log: @escaping @Sendable (String) -> Void) {
        log("fake meters: \(inputs) inputs, \(outputs) outputs")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(40))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func setRTAChannels(_ channels: [Int]) {
        queue.async { self.rtaChannels = channels }
    }

    private func tick() {
        phase += 0.04
        func level(_ i: Int, offset: Double) -> UInt8 {
            let db = -30 + 18 * sin(phase * (0.7 + Double(i % 5) * 0.23) + Double(i)) - offset - Double(i % 3) * 4
            return MeterScale.byte(fromDB: db)
        }
        let inPeak = (0..<inputs).map { level($0, offset: 0) }
        let inRMS = (0..<inputs).map { level($0, offset: 9) }
        let outPeak = (0..<outputs).map { level($0 + 7, offset: -6) }
        let outRMS = (0..<outputs).map { level($0 + 7, offset: 3) }
        onFrame?(MeterFrame(inputPeak: inPeak, inputRMS: inRMS, outputPeak: outPeak, outputRMS: outRMS))
        if !rtaChannels.isEmpty, Int(phase * 25) % 2 == 0 {
            let bands = RTAFrame.bandCenters.enumerated().map { i, f -> UInt8 in
                let tilt = -3 * log2(f / 1000)                                  // pink-ish slope
                let wobble = 4 * sin(phase * 2 + Double(i) * 0.4)
                return MeterScale.byte(fromDB: -36 + tilt + wobble)
            }
            onRTA?(rtaChannels, bands)
        }
    }
}
#endif
