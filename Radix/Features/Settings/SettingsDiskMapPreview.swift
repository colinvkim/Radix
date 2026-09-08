import SwiftUI

/// A small in-memory volume rendered with the same layouts and colors as the workspace.
struct SettingsDiskMapPreview: View {
    let mode: ScanVisualizationMode
    let depthLimit: Int
    let showFreeSpace: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let input = DiskMapFreeSpaceVisualization.input(
            snapshot: Self.snapshot,
            focusNode: Self.snapshot.root,
            showFreeSpace: showFreeSpace,
            availableCapacity: 48_000_000_000
        )

        Canvas { context, size in
            switch mode {
            case .sunburst:
                let segments = SunburstLayout.segments(
                    in: input.treeStore,
                    rootID: input.rootNode.id,
                    depthLimit: depthLimit
                )
                for segment in segments {
                    let path = SunburstRenderer.path(for: segment, in: size)
                    let style = SunburstChartStyler.baseStyle(for: segment)
                    context.fill(path, with: .color(style.fillColor))
                    context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
                }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.draw(
                    Text(RadixFormatters.size(Self.snapshot.root.allocatedSize)).font(.caption.bold()),
                    at: CGPoint(x: center.x, y: center.y - 7)
                )
                context.draw(
                    Text("used").font(.caption).foregroundStyle(.secondary),
                    at: CGPoint(x: center.x, y: center.y + 9)
                )

            case .treemap:
                let segments = TreemapLayout.segments(
                    in: input.treeStore,
                    rootID: input.rootNode.id,
                    depthLimit: depthLimit,
                    size: size
                )
                for segment in segments {
                    let path = Path(TreemapRenderer.displayRect(for: segment, in: size))
                    let style = TreemapChartStyler.baseStyle(for: segment, colorScheme: colorScheme)
                    context.fill(path, with: .color(style.fillColor))
                    context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
                }
            }
        }
        .frame(height: 230)
        .frame(maxWidth: .infinity)
        .padding(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk map preview")
        .accessibilityValue(
            showFreeSpace ? Text("\(depthLimit) levels, including free space") : Text("\(depthLimit) levels")
        )
    }

    private static let snapshot: ScanSnapshot = {
        var childrenByID: [String: [FileNodeRecord]] = [:]

        func node(id: String, bytes: Int64, depth: Int) -> FileNodeRecord {
            let children: [FileNodeRecord]
            if depth < 10 {
                let nestedBytes = bytes * 3 / 4
                children = [
                    node(id: id + "/0", bytes: nestedBytes, depth: depth + 1),
                    node(id: id + "/1", bytes: bytes - nestedBytes, depth: 10)
                ]
                childrenByID[id] = children
            } else {
                children = []
            }
            return FileNodeRecord(
                id: id, url: URL(fileURLWithPath: id), name: id,
                isDirectory: !children.isEmpty, isSymbolicLink: false,
                allocatedSize: bytes, logicalSize: bytes,
                descendantFileCount: children.isEmpty ? 1 : children.reduce(0) { $0 + $1.descendantFileCount },
                lastModified: nil, isPackage: false, isAccessible: true,
                isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
            )
        }

        let rootID = "/settings-preview"
        let children = [("Applications", 42), ("Documents", 30), ("Media", 24), ("Other", 16)].map { name, gigabytes in
            node(id: "\(rootID)/\(name)", bytes: Int64(gigabytes) * 1_000_000_000, depth: 1)
        }
        let root = FileNodeRecord(
            id: rootID, url: URL(fileURLWithPath: rootID), name: rootID,
            isDirectory: true, isSymbolicLink: false,
            allocatedSize: 112_000_000_000, logicalSize: 112_000_000_000,
            descendantFileCount: children.reduce(0) { $0 + $1.descendantFileCount },
            lastModified: nil, isPackage: false, isAccessible: true,
            isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
        )
        childrenByID[rootID] = children
        return ScanSnapshot(
            target: ScanTarget(id: rootID, url: root.url, displayName: rootID, kind: .volume),
            treeStore: FileTreeStore(root: root, childrenByID: childrenByID),
            startedAt: .distantPast, finishedAt: .distantPast,
            scanWarnings: [], isComplete: true
        )
    }()
}
