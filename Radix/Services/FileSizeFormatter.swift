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

}

private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private let byteFormatter: ByteCountFormatter
    private let dateFormatter: DateFormatter
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
}
