import Foundation
import Testing

@testable import RadixCore

struct FileSizeFormatterTests {
    @Test(arguments: [Int64(0), 1, 512, 1_024, 1_000_000_000, 1_000_000_000_000])
    func testSizesUseLocalizedFileUnits(bytes: Int64) {
        let expected = ByteCountFormatter()
        expected.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        expected.countStyle = .file
        expected.includesActualByteCount = false
        expected.isAdaptive = true

        #expect(RadixFormatters.size(bytes) == expected.string(fromByteCount: bytes))
    }

    @Test
    func testPercentageReturnsNilForNonPositiveTotal() {
        #expect(RadixFormatters.percentage(part: 1, total: 0) == nil)
        #expect(RadixFormatters.percentage(part: 1, total: -10) == nil)
    }

    @Test
    func testPercentageFormatsRatioWithOneFractionDigit() {
        #expect(RadixFormatters.percentage(part: 0, total: 10) == expectedPercentage(0))
        #expect(RadixFormatters.percentage(part: 1, total: 4) == expectedPercentage(0.25))
        #expect(RadixFormatters.percentage(part: 1, total: 3) == expectedPercentage(1.0 / 3.0))
        #expect(RadixFormatters.percentage(part: 1, total: 1) == expectedPercentage(1))
    }

    @Test
    func testPercentageDoesNotClampAboveOneHundredPercent() {
        #expect(RadixFormatters.percentage(part: 3, total: 2) == expectedPercentage(1.5))
    }

    @Test(arguments: [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_893_501_840)])
    func testDateUsesLocalizedMediumDateAndShortTime(date: Date) {
        let expected = DateFormatter()
        expected.locale = .current
        expected.timeZone = .current
        expected.dateStyle = .medium
        expected.timeStyle = .short

        #expect(RadixFormatters.date(date) == expected.string(from: date))
    }

    @Test
    func testMissingDateUsesLocalizedUnknownPlaceholder() {
        #expect(RadixFormatters.date(nil) == String(localized: "Unknown"))
    }

    private func expectedPercentage(_ ratio: Double) -> String? {
        let expected = NumberFormatter()
        expected.locale = .current
        expected.numberStyle = .percent
        expected.minimumFractionDigits = 1
        expected.maximumFractionDigits = 1
        return expected.string(from: NSNumber(value: ratio))
    }
}
