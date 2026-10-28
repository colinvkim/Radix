import Foundation
import Testing

@testable import RadixCore

struct ScanPathResolverTests {
    @Test(arguments: [
        ("/scan", "root"),
        ("/scan/Reports/Empty/", "empty"),
        ("./notes.txt", "file"),
        ("../Reports/./notes.txt", "file"),
        ("/scan/Reports/space name.txt", "spaces"),
        ("/scan/Reports/末尾 ", "unicode"),
        ("/scan//Reports/Empty/../notes.txt", "file"),
    ])
    func resolvesScannedPathsWithIndependentRecordIDs(input: String, expectedID: String) throws {
        let fixture = PathFixture()
        let resolver = ScanPathResolver(
            treeStore: fixture.store, baseDirectoryID: fixture.folder.id
        )
        #expect(try resolver.resolve(input)?.id == expectedID)
    }

    @Test(arguments: ["", "/scan-other/Reports", "/scan/Reports/missing", "/scan/Reports/notes.txt/", "/scan/reports", "~someone/Reports"])
    func unavailablePathsDoNotResolve(input: String) throws {
        #expect(try ScanPathResolver(treeStore: PathFixture().store).resolve(input) == nil)
    }

    @Test
    func completionsStayInsideTheScanAndExcludeHiddenAndSyntheticNodes() throws {
        let fixture = PathFixture()
        let resolver = ScanPathResolver(treeStore: fixture.store, hiddenNodeIDs: [fixture.folder.id])
        #expect(try resolver.resolve("/scan/Reports/notes.txt") == nil)
        #expect(try resolver.resolve("/scan/System") == nil)
        #expect(try resolver.completions(for: "/scan/").map(\.id) == [fixture.root.id])
        #expect(try resolver.completions(for: "/sc").map(\.id) == [fixture.root.id])
        let visible = ScanPathResolver(treeStore: fixture.store)
        #expect(try visible.completions(for: "/scan/rep").map(\.id) == [fixture.folder.id])
        #expect(try visible.completions(for: "/scan/Reports/Empty/").map(\.id) == [fixture.empty.id])
    }

    @Test
    func exactScanRootCompletesWithoutATrailingSlash() throws {
        let fixture = PathFixture()
        let resolver = ScanPathResolver(treeStore: fixture.store)
        #expect(try resolver.completions(for: "/scan").map(\.id) == [fixture.root.id])
    }

    @Test(arguments: ["/", "/scan/"])
    func ancestorsOfScanRootCompleteToTheRoot(input: String) throws {
        let root = pathRecord(id: "root", path: "/scan/nested", directory: true)
        let resolver = ScanPathResolver(treeStore: FileTreeStore(root: root))
        #expect(try resolver.completions(for: input).map(\.id) == [root.id])
    }

    @Test
    func completionIsBoundedNaturallyOrderedAndCancellable() throws {
        let children = (1...20).reversed().map { pathRecord(id: "id-\($0)", path: "/scan/item\($0)") }
        let root = pathRecord(id: "root", path: "/scan", directory: true)
        let resolver = ScanPathResolver(treeStore: FileTreeStore(root: root, childrenByID: [root.id: children]))
        #expect(try resolver.completions(for: "/scan/item").map(\.id) == (1...8).map { "id-\($0)" })
        #expect(try resolver.completions(for: "/scan/").map(\.id) == [root.id] + (1...7).map { "id-\($0)" })
        #expect(try resolver.completions(for: "/scan/", limit: 1).map(\.id) == [root.id])
        #expect(try resolver.completions(for: "/scan/", limit: 0).isEmpty)
        let probe = CancellationProbe(throwOnCheck: 5)
        #expect(throws: CancellationError.self) {
            try resolver.completions(for: "/scan/", cancellationCheck: probe.check)
        }
    }

    @Test
    func tildeUsesTheCurrentHomeDirectory() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = pathRecord(id: "home", path: home, directory: true)
        let file = pathRecord(id: "file", path: home + "/scanned-only.txt")
        let resolver = ScanPathResolver(treeStore: FileTreeStore(root: root, childrenByID: [root.id: [file]]))
        #expect(try resolver.resolve("~/scanned-only.txt")?.id == file.id)
    }

    @Test
    func privatePathComponentsAndFilenameWhitespaceArePreserved() throws {
        let file = pathRecord(id: "file", path: "/private/tmp/scan/ padded ")
        let root = pathRecord(id: "root", path: "/private/tmp/scan", directory: true)
        let resolver = ScanPathResolver(treeStore: FileTreeStore(root: root, childrenByID: [root.id: [file]]))
        #expect(try resolver.resolve("/private/tmp/scan/ padded ")?.id == file.id)
        #expect(try resolver.resolve("/tmp/scan/ padded ") == nil)
    }
}

@MainActor
struct GoToPathTests {
    @Test
    func folderJumpClearsSearchAndSelectionAndRecordsThePreviousLocation() async throws {
        let fixture = PathFixture()
        let model = makePathApp(fixture)
        defer { model.cleanup() }
        let browser = model.makeFileBrowserModel()
        browser.updateContent(model.navigation.browserContent())
        browser.setActiveQuery(FileBrowserQuery(text: "unmatched", itemKind: .file))
        browser.setSearchScope(.entireScan)
        browser.setActiveQuery(FileBrowserQuery(text: "unmatched"))
        model.select(nodeID: fixture.folder.id)
        model.presentGoToPath()
        let request = try pathRequest(model)

        #expect(await model.goToPath("/scan/Reports/Empty/", request: request))
        #expect(model.navigation.currentFocusNode?.id == fixture.empty.id)
        #expect(model.navigation.tableNodes.isEmpty)
        #expect(model.navigation.breadcrumbNodes.map(\.id) == [fixture.root.id, fixture.folder.id, fixture.empty.id])
        #expect(model.navigation.selectedNodeIDs.isEmpty)
        #expect(browser.searchScope == .currentContents)
        #expect(browser.activeQuery == FileBrowserQuery())
        #expect(model.presentationCoordinator.activeSheet == nil)
        model.navigateBack()
        #expect(model.navigation.currentFocusNode?.id == fixture.root.id)
    }

    @Test(arguments: [false, true])
    func fileJumpOpensItsParentAndSelectsIt(startInParent: Bool) async throws {
        let fixture = PathFixture()
        let model = makePathApp(fixture)
        defer { model.cleanup() }
        let base = startInParent ? fixture.folder.id : fixture.root.id
        model.navigation.setFocusedNodeID(base)
        model.presentGoToPath()
        let request = try pathRequest(model)
        #expect(await model.goToPath(fixture.file.url.path, request: request))
        #expect(model.navigation.currentFocusNode?.id == fixture.folder.id)
        #expect(model.navigation.selectedNodeIDs == [fixture.file.id])
        #expect(model.navigation.tableNodes.contains { $0.id == fixture.file.id })
        #expect(model.navigation.canNavigateBack == !startInParent)
        if !startInParent {
            model.navigateBack()
            #expect(model.navigation.currentFocusNode?.id == fixture.root.id)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func directoryJumpUsesAvailableContents(isSummarized: Bool, hasMaterializedChildren: Bool) async throws {
        let fixture = PathFixture()
        let directory = FileNodeRecord(
            id: "directory", url: URL(filePath: "/scan/Reports/Directory"), name: "Directory",
            isDirectory: true, isSymbolicLink: false, allocatedSize: 1, logicalSize: 1,
            descendantFileCount: 1, lastModified: nil,
            isPackage: !isSummarized, isAccessible: true, isSelfAccessible: true,
            isSynthetic: false, isAutoSummarized: isSummarized
        )
        let child = pathRecord(id: "child", path: "/scan/Reports/Directory/child.txt")
        var childrenByID = [
            fixture.root.id: [fixture.folder],
            fixture.folder.id: [directory],
        ]
        if hasMaterializedChildren { childrenByID[directory.id] = [child] }
        let store = FileTreeStore(root: fixture.root, childrenByID: childrenByID)
        let model = makePathApp(fixture, store: store)
        defer { model.cleanup() }
        model.select(nodeID: fixture.folder.id)
        model.presentGoToPath()
        let request = try pathRequest(model)

        #expect(await model.goToPath(directory.url.path, request: request))
        #expect(model.navigation.currentFocusNode?.id == (hasMaterializedChildren ? directory.id : fixture.folder.id))
        #expect(model.navigation.selectedNodeIDs == (hasMaterializedChildren ? [] : [directory.id]))
        #expect(model.navigation.tableNodes.map(\.id) == (hasMaterializedChildren ? [child.id] : [directory.id]))
        model.navigateBack()
        #expect(model.navigation.currentFocusNode?.id == fixture.root.id)
    }

    @Test
    func invalidAndCancelledJumpsPreserveBrowsingAndOldScansCannotNavigate() async throws {
        let fixture = PathFixture()
        let model = makePathApp(fixture)
        defer { model.cleanup() }
        let browser = model.makeFileBrowserModel()
        browser.setActiveQuery(FileBrowserQuery(text: "notes"))
        model.presentGoToPath()
        let request = try pathRequest(model)
        #expect(!model.canGoToPath)
        #expect(await !model.goToPath("/scan/missing", request: request))
        #expect(model.navigation.currentFocusNode?.id == fixture.root.id)
        #expect(!model.navigation.canNavigateBack)
        #expect(browser.activeQuery.text == "notes")
        model.dismissGoToPath()
        #expect(browser.activeQuery.text == "notes")
        #expect(model.canGoToPath)

        model.presentGoToPath()
        let reopenedRequest = try pathRequest(model)
        #expect(await !model.goToPath(fixture.file.url.path, request: request))
        #expect(model.presentationCoordinator.activeSheet == .goToPath(reopenedRequest))
        #expect(model.navigation.currentFocusNode?.id == fixture.root.id)
        #expect(!model.navigation.canNavigateBack)
        #expect(browser.activeQuery.text == "notes")
        let replacement = PathFixture()
        model.scanState.replaceCurrentSnapshot(makeTestSnapshot(root: replacement.root, store: replacement.store))
        #expect(model.presentationCoordinator.activeSheet == nil)
        #expect(await !model.goToPath(fixture.file.url.path, request: reopenedRequest))
        #expect(model.navigation.currentFocusNode?.id == replacement.root.id)
        #expect(model.navigation.selectedNodeIDs.isEmpty)
    }
}

private struct PathFixture {
    let root = pathRecord(id: "root", path: "/scan", directory: true)
    let folder = pathRecord(id: "reports", path: "/scan/Reports", directory: true)
    let empty = pathRecord(id: "empty", path: "/scan/Reports/Empty", directory: true)
    let file = pathRecord(id: "file", path: "/scan/Reports/notes.txt")

    var store: FileTreeStore {
        FileTreeStore(root: root, childrenByID: [
            root.id: [folder, pathRecord(id: "synthetic", path: "/scan/System", synthetic: true)],
            folder.id: [empty, file,
                        pathRecord(id: "spaces", path: "/scan/Reports/space name.txt"),
                        pathRecord(id: "unicode", path: "/scan/Reports/末尾 ")],
        ])
    }
}

private func pathRecord(id: String, path: String, directory: Bool = false, synthetic: Bool = false) -> FileNodeRecord {
    FileNodeRecord(
        id: id, url: URL(filePath: path), name: URL(filePath: path).lastPathComponent,
        isDirectory: directory, isSymbolicLink: false, allocatedSize: 1, logicalSize: 1,
        descendantFileCount: directory ? 0 : 1, lastModified: nil,
        isPackage: false, isAccessible: true, isSelfAccessible: true,
        isSynthetic: synthetic, isAutoSummarized: false
    )
}

@MainActor
private func makePathApp(_ fixture: PathFixture, store: FileTreeStore? = nil) -> AppModel {
    let model = AppModel(dependencies: AppDependencies(
        preferences: TestAppPreferencesStore(preferences: AppPreferences(scan: .defaults, didCompleteOnboarding: true)),
        recentTargets: RecentTargetStore(persistence: TestRecentTargetPersistence(), isAvailable: { _ in false }),
        systemActions: .inert
    ))
    let snapshot = ScanSnapshot(
        target: ScanTarget(url: fixture.root.url), treeStore: store ?? fixture.store,
        startedAt: Date(), finishedAt: Date(), scanWarnings: [], isComplete: true,
        source: .imported(ImportedSnapshotContext(
            sourceURL: URL(filePath: "/saved.radixscan"), pathMode: .absolute,
            liveActionCapability: .pathValidation
        ))
    )
    model.scanState.replaceCurrentSnapshot(snapshot)
    model.navigation.reconcileAfterSnapshotApplied(snapshot)
    return model
}

@MainActor
private func pathRequest(_ model: AppModel) throws -> GoToPathRequest {
    guard case .goToPath(let request) = model.presentationCoordinator.activeSheet else {
        throw TestFixtureError("Go to Path was not presented.")
    }
    return request
}
