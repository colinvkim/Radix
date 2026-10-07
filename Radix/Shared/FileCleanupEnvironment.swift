import SwiftUI

private struct ReadOnlyModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isReadOnlyMode: Bool {
        get { self[ReadOnlyModeKey.self] }
        set { self[ReadOnlyModeKey.self] = newValue }
    }
}
