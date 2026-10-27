import XCTest

/// Real touches through XCUITest. Runs offline in demo mode by default; set `TEST_RUNNER_FOH_HOST=127.0.0.1:9124`
/// on `xcodebuild test` to drive a live bridge, and watch the MIDI with `fohctl monitor all`.
final class FOHRemoteUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        if let host = ProcessInfo.processInfo.environment["FOH_HOST"], !host.isEmpty {
            app.launchArguments = ["-host", host]
        } else {
            app.launchArguments = ["-demo"]
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
    }

    private var isLive: Bool { app.launchArguments.contains("-host") }

    /// In live mode, wait for the bridge's config so the strips are the bridge's, not the demo show.
    private func waitForConnection() {
        guard isLive else { return }
        let pill = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Bridge ·'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "never connected to the bridge")
    }

    func testMuteToggleAndFaderDrag() {
        waitForConnection()
        let mute = app.buttons["mute.in/1"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        let wasOn = mute.isSelected
        mute.tap()
        XCTAssertNotEqual(mute.isSelected, wasOn, "mute didn't toggle")
        mute.tap()
        XCTAssertEqual(mute.isSelected, wasOn, "mute didn't toggle back")

        let fader = app.descendants(matching: .any)["fader.in/1"]
        XCTAssertTrue(fader.exists)
        let before = fader.value as? String
        let start = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)))
        let after = fader.value as? String
        XCTAssertNotEqual(before, after, "fader value didn't change (\(before ?? "nil") → \(after ?? "nil"))")
        // Put it back so a live mix isn't left changed.
        let back = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        back.press(forDuration: 0.1, thenDragTo: back.withOffset(CGVector(dx: 0, dy: 90)))
    }

    func testChannelEQAndSetupFlow() {
        waitForConnection()
        app.buttons["Open Lead vox"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 · Lead vox"].waitForExistence(timeout: 5))
        app.buttons["Setup"].firstMatch.tap()
        for section in ["Channels & I/O", "Processing", "MainStage learn", "Verify"] {
            app.buttons[section].firstMatch.tap()
            XCTAssertTrue(app.staticTexts[section == "Channels & I/O" ? "Channels & I/O" : section].firstMatch.waitForExistence(timeout: 5),
                          "\(section) screen didn't open")
        }
        XCTAssertTrue(app.buttons["✓ MOVED & MATCHES"].exists)
    }

    /// Double-tapping a mixer fader snaps it to 0 dB.
    func testDoubleTapSnapsFaderToZero() throws {
        try XCTSkipIf(isLive, "moves the live mix; demo mode only")
        let fader = app.descendants(matching: .any)["fader.in/1"]
        XCTAssertTrue(fader.waitForExistence(timeout: 5))
        let start = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
        XCTAssertNotEqual(fader.value as? String, "0.0 dB", "the drag should have moved it off 0 dB first")
        fader.doubleTap()
        XCTAssertEqual(fader.value as? String, "0.0 dB")
        Thread.sleep(forTimeInterval: 0.5)   // it used to snap back a frame later
        XCTAssertEqual(fader.value as? String, "0.0 dB", "the snap should stick")
    }

    /// Double-tapping an EQ gain knob snaps it to 0 dB.
    func testDoubleTapSnapsEQGainToZero() throws {
        try XCTSkipIf(isLive, "moves the live mix; demo mode only")
        app.buttons["Open Lead vox"].firstMatch.tap()
        let gain = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Gain'")).element(boundBy: 1)  // LMF
        XCTAssertTrue(gain.waitForExistence(timeout: 5))
        func db() -> Double? { (gain.value as? String).flatMap { Double($0.replacingOccurrences(of: " dB", with: "").replacingOccurrences(of: "+", with: "")) } }
        let before = try XCTUnwrap(db(), "\(String(describing: gain.value))")
        XCTAssertGreaterThan(abs(before), 1, "the demo's LMF gain should start away from 0 dB")
        gain.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)
        let after = try XCTUnwrap(db(), "\(String(describing: gain.value))")
        XCTAssertLessThanOrEqual(abs(after), 0.5, "double-tap should snap to 0 dB (got \(after))")
    }

    /// Pinching the EQ graph sets the selected band's Q: spreading widens the bell (lower Q), pinching in narrows it.
    func testPinchOnEQGraphSetsQ() throws {
        try XCTSkipIf(isLive, "changes Q on the live mix; runs in demo mode only")
        app.buttons["Open Lead vox"].firstMatch.tap()
        let graph = app.descendants(matching: .any)["eq.graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        let callout = app.staticTexts["eq.callout"]
        func q() -> Double? {
            guard callout.exists, let r = callout.label.range(of: #"Q [0-9.]+"#, options: .regularExpression) else { return nil }
            return Double(callout.label[r].dropFirst(2))
        }
        let start = try XCTUnwrap(q(), "the selected band shows no Q: \(callout.label)")
        graph.pinch(withScale: 2.5, velocity: 1.5)
        let wider = try XCTUnwrap(q())
        XCTAssertLessThan(wider, start, "spreading should lower Q (\(start) → \(wider))")
        graph.pinch(withScale: 0.3, velocity: -1.5)
        let narrower = try XCTUnwrap(q())
        XCTAssertGreaterThan(narrower, wider, "pinching in should raise Q (\(wider) → \(narrower))")
    }

    /// A bridge show this version can't decode: a persistent banner says so and the console is paused.
    func testUnreadableBridgeShowShowsBanner() throws {
        try XCTSkipIf(isLive, "simulates a bridge on another version; demo mode only")
        app.terminate()
        app.launchArguments = ["-demo", "-badconfig"]
        app.launch()
        let banner = app.descendants(matching: .any)["banner.configError"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "no banner for an unreadable show")
        XCTAssertTrue(banner.label.contains("same version"), banner.label)
        let mute = app.buttons["mute.in/1"]
        XCTAssertTrue(mute.exists)
        let wasOn = mute.isSelected
        mute.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()   // the button isn't hittable while paused
        XCTAssertEqual(mute.isSelected, wasOn, "controls should be paused while the bridge's show is unreadable")
    }
}

/// Finishing batch: Backup & restore, Plugin templates, display order, toasts.
final class FOHRemoteFinishingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        if let host = ProcessInfo.processInfo.environment["FOH_HOST"], !host.isEmpty {
            app.launchArguments = ["-host", host]
        } else {
            app.launchArguments = ["-demo"]
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
    }

    private var isLive: Bool { app.launchArguments.contains("-host") }

    func testBackupAndTemplatesScreens() {
        app.buttons["Setup"].firstMatch.tap()
        app.buttons["Backup & restore"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["heading.backup"].waitForExistence(timeout: 5), "Backup & restore heading missing")
        XCTAssertTrue(app.buttons["EXPORT SHOW…"].exists)
        XCTAssertTrue(app.buttons["IMPORT SHOW…"].exists)

        app.buttons["Plugin templates"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["heading.templates"].waitForExistence(timeout: 5), "Plugin templates heading missing")
        XCTAssertTrue(app.staticTexts["Waves SSL Channel"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Waves Tune Real-Time"].firstMatch.exists)
    }

    func testReorderInputsChangesMixerOrderOnly() throws {
        try XCTSkipIf(isLive, "Reorders the demo show only — don't change a live bridge's order")
        app.buttons["Setup"].firstMatch.tap()
        app.buttons["Channels & I/O"].firstMatch.tap()
        let reorder = app.buttons["Reorder inputs"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 5))
        reorder.tap()
        let moveUp = app.buttons["Move Guitar up"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 5))
        moveUp.tap()

        app.buttons["Mixer"].firstMatch.tap()
        let guitar = app.buttons["Open Guitar"].firstMatch
        let kelly = app.buttons["Open Lead vox"].firstMatch
        XCTAssertTrue(guitar.waitForExistence(timeout: 5))
        XCTAssertLessThan(guitar.frame.minX, kelly.frame.minX, "Guitar should now be left of Lead vox on the mixer")
        // Addresses don't move: Lead vox is still slot 1 (mute.in/1).
        XCTAssertTrue(app.buttons["mute.in/1"].exists)
        XCTAssertGreaterThan(app.buttons["mute.in/1"].frame.minX, app.buttons["mute.in/2"].frame.minX)
    }

    func testDemoPatchChangeShowsToast() throws {
        try XCTSkipIf(isLive, "Would send Program Change to a live bridge")
        let next = app.buttons["Next patch"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.buttons["toast"].waitForExistence(timeout: 2), "No toast after changing patch")
    }
}
