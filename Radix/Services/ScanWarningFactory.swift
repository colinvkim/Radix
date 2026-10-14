import Darwin
import Foundation

nonisolated enum ScanWarningFactory {
    nonisolated static func makeWarning(for url: URL, error: Error) -> ScanWarning {
        let nsError = error as NSError
        let category: ScanWarningCategory

        if nsError.domain == NSCocoaErrorDomain &&
            nsError.code == NSFileReadNoPermissionError {
            category = .permissionDenied
        } else if nsError.domain == NSPOSIXErrorDomain &&
            (nsError.code == EACCES || nsError.code == EPERM) {
            category = .permissionDenied
        } else {
            category = .fileSystem
        }

        return ScanWarning(
            path: url.path,
            message: nsError.localizedDescription,
            category: category
        )
    }

    nonisolated static func makeDuplicateNodeWarning(for url: URL) -> ScanWarning {
        ScanWarning(
            path: url.path,
            message: String(localized: "A duplicate filesystem path was collapsed in the scan results.", comment: "Warning shown when duplicate filesystem paths are collapsed.") ,
            category: .fileSystem
        )
    }

    nonisolated static func diagnosticErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code)"
    }
}
