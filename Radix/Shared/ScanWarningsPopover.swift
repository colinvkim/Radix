import SwiftUI

struct ScanWarningPresentation {
    private enum Kind {
        case incomplete
        case expectedMacOSProtection
        case fullDiskAccessMayHelp
        case fullDiskAccessEnabled
        case savedScanHistorical
    }

    private static let expectedMacOSProtectionPrefix = String(
        localized: "This is expected on macOS.",
        comment: "Inspector guidance that a protected system location is normal macOS behavior."
    )

    let selectionName: String
    let warnings: [ScanWarning]
    private let kind: Kind

    init(
        selectionName: String,
        warnings: [ScanWarning],
        fullDiskAccessAdvice: FullDiskAccessAdvice
    ) {
        self.selectionName = selectionName
        self.warnings = warnings
        if fullDiskAccessAdvice == .openSettings {
            kind = .fullDiskAccessMayHelp
        } else if fullDiskAccessAdvice == .rescanMayBeNeeded {
            kind = .fullDiskAccessEnabled
        } else if fullDiskAccessAdvice == .savedScanIsHistorical {
            kind = .savedScanHistorical
        } else if !warnings.isEmpty,
                  warnings.allSatisfy(PermissionAdvisor.isExpectedMacOSProtection) {
            kind = .expectedMacOSProtection
        } else {
            kind = .incomplete
        }
    }

    var noticeTitle: LocalizedStringKey {
        kind == .expectedMacOSProtection ? "Protected by macOS" : "Incomplete contents"
    }

    var noticeSummary: String {
        if kind == .expectedMacOSProtection {
            return Self.expectedMacOSProtectionPrefix + " " + String(
                localized: "\(warnings.count) system locations are protected by macOS, so this selection’s total may be incomplete.",
                comment: "Inspector warning summary for protected locations that Full Disk Access cannot unlock."
            )
        }
        return String(
            localized: "\(warnings.count) locations in this selection couldn’t be read. Its allocated size and contents may be incomplete.",
            comment: "Inspector warning summary for unreadable locations within the current selection."
        )
    }

    var showWarningsTitle: String {
        return String(
            localized: "Show \(warnings.count) Warnings",
            comment: "Action that opens the warning details popover from the Inspector or workspace header. The warning count controls pluralization."
        )
    }

    var reviewTitle: String {
        return kind == .expectedMacOSProtection
            ? String(localized: "\(warnings.count) Protected Locations in \(selectionName)", comment: "Inspector warning popover title for protected locations.")
            : String(localized: "\(warnings.count) Warnings in \(selectionName)", comment: "Inspector warning popover title. The warning count controls pluralization.")
    }

    var reviewSummary: String {
        if kind == .expectedMacOSProtection {
            return Self.expectedMacOSProtectionPrefix + " " + String(
                localized: "\(warnings.count) protected locations were skipped, so \(selectionName)’s total may be incomplete.",
                comment: "Inspector warning popover summary for protected locations."
            )
        }
        return String(
            localized: "\(warnings.count) locations were skipped, so \(selectionName)’s allocated size and contents may be incomplete.",
            comment: "Inspector warning popover summary for skipped locations."
        )
    }

    var suggestsFullDiskAccess: Bool {
        kind == .fullDiskAccessMayHelp
    }

    var confirmsExpectedProtection: Bool {
        kind == .expectedMacOSProtection
    }

    var fullDiskAccessIsEnabled: Bool {
        kind == .fullDiskAccessEnabled
    }

    var describesHistoricalSavedScan: Bool {
        kind == .savedScanHistorical
    }
}

struct ScanWarningsPopover: View {
    let presentation: ScanWarningPresentation
    let openFullDiskAccessSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(presentation.reviewTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text(presentation.reviewSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            warningList

            if presentation.suggestsFullDiskAccess {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Button("Open Full Disk Access Settings", systemImage: "gear") {
                        openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Enable Full Disk Access for Radix, then rescan to include these locations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if presentation.confirmsExpectedProtection {
                Divider()

                Label("No Full Disk Access change is required.", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else if presentation.fullDiskAccessIsEnabled {
                Divider()

                Label("Full Disk Access is enabled.", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("If you enabled it after this scan, rescan to update these results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if presentation.describesHistoricalSavedScan {
                Divider()

                Label("Saved scan", systemImage: "archivebox.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("This warning reflects the access available when this saved scan was created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    @ViewBuilder
    private var warningList: some View {
        if presentation.warnings.count > 3 {
            ScrollView {
                warningRows
            }
            .frame(height: 304)
        } else {
            warningRows
        }
    }

    private var warningRows: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(presentation.warnings.enumerated()), id: \.element.id) { index, warning in
                ScanWarningRow(warning: warning)

                if index < presentation.warnings.count - 1 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScanWarningRow: View {
    let warning: ScanWarning

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warning.category.symbolName)
                .foregroundStyle(.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(locationName)
                    .font(.subheadline.weight(.semibold))

                Text(warning.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(warning.path)

                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var locationName: String {
        let name = URL(filePath: warning.path).lastPathComponent
        return name.isEmpty ? warning.path : name
    }
}
