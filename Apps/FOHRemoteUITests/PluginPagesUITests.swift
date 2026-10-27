import XCTest

/// Real touches on the Pro-Q 3 and Pro-R 2 pages (PLAN.md §9c phase 3), offline in demo mode: Lead vox has Pro-Q 3
/// on insert 2 (bands 1–4 in use) and the reverb return has Pro-R 2 (decay bands 1–2 in use).
final class PluginPagesUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func open(strip: String, plugin: Int) -> XCUIElement {
        app.launchArguments = ["-demo", "-screen", "inserts", "-strip", strip, "-plugin", "\(plugin)"]
        app.launch()
        let graph = app.descendants(matching: .any)["plugin.graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 10), "the plugin page's graph didn't appear")
        return graph
    }

    private var callout: XCUIElement { app.staticTexts["plugin.callout"] }

    private func number(after prefix: String) -> Double? {
        let label = callout.label
        guard let r = label.range(of: prefix + #" [-+]?[0-9.]+"#, options: .regularExpression) else { return nil }
        return Double(label[r].dropFirst(prefix.count + 1).replacingOccurrences(of: "+", with: ""))
    }

    /// The callout's gain ("… · +2.12 dB · …").
    private func gain() -> Double? {
        guard let r = callout.label.range(of: #"[-+][0-9.]+ dB"#, options: .regularExpression) else { return nil }
        return Double(callout.label[r].dropLast(3).replacingOccurrences(of: "+", with: ""))
    }

    func testTapOnEmptyGraphAddsTheNextFreeBand() throws {
        let graph = open(strip: "in/1", plugin: 2)
        XCTAssertTrue(app.buttons["Band 5, not in use"].exists, "band 5 should start unused")
        graph.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["Band 5"].waitForExistence(timeout: 3), "a tap on empty graph should add band 5")
        XCTAssertTrue(callout.label.hasPrefix("5 · Bell"), callout.label)
        let added = try XCTUnwrap(gain(), callout.label)
        XCTAssertGreaterThan(added, 8, "added where the finger was, high on the graph (\(callout.label))")
    }

    func testDragMovesABandAndPinchSetsItsQ() throws {
        let graph = open(strip: "in/1", plugin: 2)
        let handle = graph.descendants(matching: .any)["Band 2"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        XCTAssertTrue(callout.label.hasPrefix("2 · Bell"), callout.label)
        let raised = try XCTUnwrap(gain(), callout.label)
        XCTAssertGreaterThan(raised, 0, "dragging band 2 up should raise its gain from −3 dB (\(callout.label))")

        let q = try XCTUnwrap(number(after: "Q"), callout.label)
        graph.pinch(withScale: 2.5, velocity: 1.5)
        let wider = try XCTUnwrap(number(after: "Q"), callout.label)
        XCTAssertLessThan(wider, q, "spreading should lower Q (\(q) → \(wider))")
    }

    func testDoubleTapReturnsABandToZero() throws {
        let graph = open(strip: "in/1", plugin: 2)
        let handle = graph.descendants(matching: .any)["Band 2"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        handle.tap()
        XCTAssertLessThan(try XCTUnwrap(gain(), callout.label), -2, "the demo's band 2 starts at −3 dB")
        handle.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)   // a drag from the second tap must not send the old gain back
        XCTAssertLessThanOrEqual(abs(try XCTUnwrap(gain(), callout.label)), 0.3, callout.label)
    }

    func testRemoveAndAddBandFromThePanel() throws {
        _ = open(strip: "in/1", plugin: 2)
        app.buttons["Band 4"].tap()
        app.buttons["REMOVE"].tap()
        XCTAssertTrue(app.buttons["Band 4, not in use"].waitForExistence(timeout: 3))
        app.buttons["ADD BAND 4"].tap()
        XCTAssertTrue(app.buttons["Band 4"].waitForExistence(timeout: 3))
    }

    func testShapePickerChangesTheBand() throws {
        _ = open(strip: "in/1", plugin: 2)
        app.buttons["Band 3"].tap()
        app.buttons["Notch"].tap()
        XCTAssertTrue(callout.label.hasPrefix("3 · Notch"), callout.label)
    }

    func testProR2DecayGraphAddsABand() throws {
        let graph = open(strip: "fx/1", plugin: 1)
        XCTAssertTrue(app.buttons["Decay band 3, not in use"].exists)
        graph.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["Decay band 3"].waitForExistence(timeout: 3), "a tap on empty graph should add decay band 3")
        XCTAssertTrue(callout.label.contains("decay"), callout.label)
    }
}

/// Add control, remove control and the plugin pages that replace the insert macro pages (phase 4), in demo mode.
final class PluginControlsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func open(strip: String, plugin: Int) {
        app.launchArguments = ["-demo", "-screen", "inserts", "-strip", strip, "-plugin", "\(plugin)"]
        app.launch()
    }

    func testAddAControlFromAllControlsThenRemoveIt() throws {
        open(strip: "in/1", plugin: 2)
        let all = app.buttons["ALL CONTROLS"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        all.tap()
        XCTAssertFalse(app.descendants(matching: .any)["Band 9 Frequency"].exists, "band 9 isn't in Pro-Q's core set")
        app.buttons["ADD CONTROL"].tap()
        let addSearch = app.textFields["addcontrol.search"]
        XCTAssertTrue(addSearch.waitForExistence(timeout: 5))
        addSearch.tap()
        addSearch.typeText("Band 9 Freq")
        let add = app.buttons["Add Band 9 Frequency"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 5), "added: no longer offered")
        app.buttons["addcontrol.done"].tap()

        let search = app.textFields["controls.search"]   // the list is long and built as it scrolls: search, as a person would
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Band 9")
        let knob = app.descendants(matching: .any).matching(identifier: "Band 9 Frequency").firstMatch
        XCTAssertTrue(knob.waitForExistence(timeout: 5), "the new control appears under All controls")
        knob.press(forDuration: 1.2)
        let remove = app.buttons["Remove from Pro-Q 3 controls"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(knob.waitForNonExistence(timeout: 5), "removed from the iPad")
    }

    func testTunePageRunsOnPluginControls() throws {
        open(strip: "in/1", plugin: 1)
        let c = app.buttons["C"]
        XCTAssertTrue(c.waitForExistence(timeout: 10))
        c.tap()
        XCTAssertTrue(c.isSelected, "the key picker selects C")
        XCTAssertTrue(app.buttons["Chromatic"].exists && app.buttons["Major"].exists, "the common scales are offered")
        XCTAssertTrue(app.buttons["ALL CONTROLS"].exists)
    }
}

/// MainStage's own plugins (phase 5) in demo mode, where there's no MainStage to read tables from: the learn flow.
final class MainStagePluginUITests: XCTestCase {
    func testTeachAChannelEQControlByHand() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-demo", "-screen", "inserts", "-strip", "out/1", "-plugin", "3"]   // Main › Channel EQ
        app.launch()
        let name = app.textFields["learn.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Channel EQ's page offers to teach a control")
        name.tap()
        name.typeText("Low Cut Freq")
        app.buttons["START"].tap()
        XCTAssertTrue(app.staticTexts["Low Cut Freq"].waitForExistence(timeout: 5), "waiting for MainStage")
        XCTAssertTrue(app.buttons["SEND"].exists)
        app.buttons["SEND"].tap()
        app.buttons["CHECK THE SAVED CONCERT NOW"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Low Cut Freq"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["SEND"].exists, "no longer waiting")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '(1 learned)'")).firstMatch.exists)
    }
}

/// MainStage's Record button in the top bar (demo mode).
final class RecordUITests: XCTestCase {
    func testRecordStartsWithOneTapAndAsksBeforeStopping() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-demo"]
        app.launch()
        let rec = app.buttons["record"]
        XCTAssertTrue(rec.waitForExistence(timeout: 10))
        XCTAssertEqual(rec.label, "Start recording")
        rec.tap()
        XCTAssertEqual(rec.label, "Stop recording")
        rec.tap()
        let stop = app.alerts.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "stopping asks first")
        app.alerts.buttons["Keep recording"].tap()
        XCTAssertEqual(rec.label, "Stop recording", "still recording")
        rec.tap()
        app.alerts.buttons["Stop recording"].tap()
        XCTAssertEqual(rec.label, "Start recording")
    }
}
