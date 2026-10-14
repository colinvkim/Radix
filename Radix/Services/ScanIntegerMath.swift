nonisolated enum ScanIntegerMath {
    nonisolated static func addingClamped<Value: FixedWidthInteger>(
        _ lhs: Value,
        _ rhs: Value
    ) -> Value {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Value.max : sum
    }
}
