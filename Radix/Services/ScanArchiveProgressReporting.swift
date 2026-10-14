nonisolated enum ScanArchiveProgressReporting {
    private static let progressReportInterval = 512

    nonisolated static func shouldReportProgress(_ completedUnitCount: Int) -> Bool {
        completedUnitCount == 0 || completedUnitCount % progressReportInterval == 0
    }
}
