import Foundation
import Testing

struct BenchmarkSupportTests {
    @Test
    func testMedianHandlesEmptyOddAndEvenSamples() {
        #expect(BenchmarkSupport.median([]) == nil)
        #expect(BenchmarkSupport.median([3, 1, 2]) == 2)
        #expect(BenchmarkSupport.median([4, 1, 3, 2]) == 2.5)
    }

    @Test
    func testDurationSecondsIncludesAttoseconds() {
        #expect(abs((BenchmarkSupport.durationSeconds(.seconds(1) + .milliseconds(250))) - (1.25)) <= 0.000_001)
    }

    @Test
    func testByteDeltaClampsDecreasesToZero() {
        #expect(BenchmarkSupport.byteDelta(from: 100, to: 125) == 25)
        #expect(BenchmarkSupport.byteDelta(from: 125, to: 100) == 0)
    }

    @Test
    func testResultLinePreservesBenchmarkOutputFormat() {
        #expect(
            BenchmarkSupport.resultLine(
                prefix: "TEST_RESULT",
                phase: "fixture",
                seconds: 1.25,
                count: 7,
                peakRSS: 99,
                extra: "fingerprint=abc"
            ) == "TEST_RESULT phase=fixture seconds=1.250000 count=7 peak_rss=99 fingerprint=abc")
        #expect(
            BenchmarkSupport.resultLine(
                prefix: "TEST_RESULT",
                phase: "fixture",
                seconds: 0,
                count: 0,
                peakRSS: 0
            ) == "TEST_RESULT phase=fixture seconds=0.000000 count=0 peak_rss=0 ")
    }
}
