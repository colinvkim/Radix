//
//  FileSizeFormatter.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

enum RadixFormatters {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        formatter.isAdaptive = true
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func size(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    static func date(_ date: Date?) -> String {
        guard let date else {
            return "Unknown"
        }
        return dateFormatter.string(from: date)
    }

    static func scanElapsed(startedAt: Date, finishedAt: Date?) -> String {
        let endDate = finishedAt ?? Date()
        let seconds = max(0, Int(endDate.timeIntervalSince(startedAt)))
        return "\(seconds)s"
    }
}
