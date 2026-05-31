import XCTest
@testable import RadixCore

final class FileSizeFormatterTests: XCTestCase {
    func testSmallSizesUseByteUnits() {
        XCTAssertTrue(RadixFormatters.size(0).localizedCaseInsensitiveContains("byte"))
        XCTAssertEqual(RadixFormatters.size(1), "1 byte")
        XCTAssertEqual(RadixFormatters.size(512), "512 bytes")
        XCTAssertEqual(RadixFormatters.size(1_024), "1 KB")
    }
}
