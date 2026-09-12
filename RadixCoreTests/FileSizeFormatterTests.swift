import Foundation
import Testing

@testable import RadixCore

struct FileSizeFormatterTests {
    @Test
    func testSmallSizesUseByteUnits() {
        #expect(RadixFormatters.size(0).localizedCaseInsensitiveContains("byte"))
        #expect(RadixFormatters.size(1) == "1 byte")
        #expect(RadixFormatters.size(512) == "512 bytes")
        #expect(RadixFormatters.size(1_024) == "1 KB")
    }

    @Test
    func testPercentageReturnsNilForNonPositiveTotal() {
        #expect(RadixFormatters.percentage(part: 1, total: 0) == nil)
        #expect(RadixFormatters.percentage(part: 1, total: -10) == nil)
    }

    @Test
    func testPercentageFormatsRatioWithOneFractionDigit() {
        #expect(RadixFormatters.percentage(part: 0, total: 10) == "0.0%")
        #expect(RadixFormatters.percentage(part: 1, total: 4) == "25.0%")
        #expect(RadixFormatters.percentage(part: 1, total: 3) == "33.3%")
        #expect(RadixFormatters.percentage(part: 1, total: 1) == "100.0%")
    }

    @Test
    func testPercentageDoesNotClampAboveOneHundredPercent() {
        // A child can exceed its container (e.g. hard-link dedup or
        // allocated-vs-logical accounting); the formatter reports the raw ratio.
        #expect(RadixFormatters.percentage(part: 3, total: 2) == "150.0%")
    }
}
