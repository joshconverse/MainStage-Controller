import XCTest
import FOHCore
@testable import FOHMacKit

final class FourCCTests: XCTestCase {
    func testRoundTrip() {
        XCTAssertEqual(FourCC.string(FourCC.code("SCHM")), "SCHM")
        XCTAssertEqual(FourCC.code("aufx"), 0x6175_6678)
    }
}
