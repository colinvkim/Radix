import XCTest
@testable import RadixCore

final class SystemIntegrationTests: XCTestCase {
    func testMoveToTrashPreflightRejectsProtectedLocations() {
        XCTAssertThrowsError(
            try SystemIntegration.validateCanMoveToTrash(
                URL(filePath: "/System", directoryHint: .isDirectory)
            )
        ) { error in
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                XCTFail("Expected SystemIntegrationError, got \(error).")
                return
            }

            guard case .protectedTrashLocation(let path) = integrationError else {
                XCTFail("Expected protectedTrashLocation, got \(integrationError).")
                return
            }

            XCTAssertEqual(path, "/System")
            XCTAssertEqual(
                error.localizedDescription,
                "Radix will not move the protected location at /System to the Trash."
            )
        }
    }

    func testMoveToTrashPreflightAllowsDescendantsOfProtectedLocations() {
        XCTAssertNoThrow(
            try SystemIntegration.validateCanMoveToTrash(
                URL(filePath: "/Applications/Example.app", directoryHint: .isDirectory)
            )
        )
    }
}
