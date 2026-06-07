//
//  QuickLookIntegration.swift
//  Radix
//
//  Created by Codex on 5/26/26.
//

import AppKit
import Foundation
import QuickLookUI

@MainActor
extension SystemIntegration {
    static var isQuickLookPreviewVisible: Bool {
        QuickLookPreviewPresenter.shared.isPreviewVisible
    }

    static var isQuickLookPreviewPanelKeyWindow: Bool {
        QuickLookPreviewPresenter.shared.isPreviewPanelKeyWindow
    }

    static func presentQuickLookPreview(for url: URL) throws {
        try QuickLookPreviewPresenter.shared.present(url)
    }

    static func toggleQuickLookPreview(for url: URL) throws {
        try QuickLookPreviewPresenter.shared.toggle(url)
    }

    static func updateVisibleQuickLookPreview(for url: URL?) {
        QuickLookPreviewPresenter.shared.updateVisiblePreview(url)
    }

    static func closeQuickLookPreview() {
        QuickLookPreviewPresenter.shared.close()
    }
}

@MainActor
private final class QuickLookPreviewPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPreviewPresenter()

    private var previewItems: [NSURL] = []

    var isPreviewVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    var isPreviewPanelKeyWindow: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isKeyWindow
    }

    func present(_ url: URL) throws {
        try setPreviewURL(url)

        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.currentPreviewItemIndex = 0
        panel?.reloadData()
        panel?.makeKeyAndOrderFront(nil)
    }

    func toggle(_ url: URL) throws {
        if isPreviewVisible {
            close()
            return
        }

        try present(url)
    }

    func updateVisiblePreview(_ url: URL?) {
        guard isPreviewVisible else { return }

        guard let url else {
            close()
            return
        }

        do {
            try setPreviewURL(url)
            let panel = QLPreviewPanel.shared()
            panel?.dataSource = self
            panel?.currentPreviewItemIndex = 0
            panel?.reloadData()
            panel?.refreshCurrentPreviewItem()
        } catch {
            close()
        }
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else {
            previewItems = []
            return
        }

        previewItems = []
        QLPreviewPanel.shared().orderOut(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index]
    }

    private func setPreviewURL(_ url: URL) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw SystemIntegration.SystemIntegrationError.quickLookUnavailable(path: url.path)
        }

        previewItems = [url as NSURL]
    }
}
