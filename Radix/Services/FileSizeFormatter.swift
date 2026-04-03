//
//  FileSizeFormatter.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

enum RadixFormatters {
    private static let formatterCache = FormatterCache()

    static func size(_ bytes: Int64) -> String {
        formatterCache.size(bytes)
    }

    static func date(_ date: Date?) -> String {
        guard let date else {
            return "Unknown"
        }
        return formatterCache.date(date)
    }

    static func scanElapsed(startedAt: Date, finishedAt: Date?) -> String {
        let endDate = finishedAt ?? Date()
        let interval = max(0, endDate.timeIntervalSince(startedAt))
        return formatterCache.elapsed(interval)
    }
}

private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private let byteFormatter: ByteCountFormatter
    private let dateFormatter: DateFormatter
    private let elapsedFormatter: DateComponentsFormatter

    init() {
        let byteFormatter = ByteCountFormatter()
        byteFormatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        byteFormatter.countStyle = .file
        byteFormatter.includesActualByteCount = false
        byteFormatter.isAdaptive = true
        self.byteFormatter = byteFormatter

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        self.dateFormatter = dateFormatter

        let elapsedFormatter = DateComponentsFormatter()
        elapsedFormatter.allowedUnits = [.hour, .minute, .second]
        elapsedFormatter.unitsStyle = .abbreviated
        elapsedFormatter.zeroFormattingBehavior = [.dropLeading, .dropTrailing]
        self.elapsedFormatter = elapsedFormatter
    }

    func size(_ bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return byteFormatter.string(fromByteCount: bytes)
    }

    func date(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return dateFormatter.string(from: date)
    }

    func elapsed(_ interval: TimeInterval) -> String {
        lock.lock()
        defer { lock.unlock() }
        return elapsedFormatter.string(from: interval) ?? "0s"
    }
}
