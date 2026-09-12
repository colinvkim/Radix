import Foundation

@testable import RadixCore

func scanResultFingerprint(_ store: FileTreeStore) -> String {
    var fingerprint = StableScanResultFingerprint()
    for nodeIndex in store.indexedNodeIndices() {
        guard let node = store.node(at: nodeIndex) else { continue }
        fingerprint.append(node.id)
        fingerprint.append(node.url.path)
        fingerprint.append(node.name)
        fingerprint.append(node.allocatedSize)
        fingerprint.append(node.unduplicatedAllocatedSize)
        fingerprint.append(node.dataAllocatedSize)
        fingerprint.append(node.logicalSize)
        fingerprint.append(Int64(node.descendantFileCount))
        fingerprint.append(node.linkCount)
        fingerprint.append(node.isDirectory)
        fingerprint.append(node.isSymbolicLink)
        fingerprint.append(node.isPackage)
        fingerprint.append(node.isAccessible)
        fingerprint.append(node.isSelfAccessible)
        fingerprint.append(node.isSynthetic)
        fingerprint.append(node.isAutoSummarized)
        if let lastModified = node.lastModified {
            fingerprint.append(true)
            fingerprint.append(lastModified.timeIntervalSinceReferenceDate.bitPattern)
        } else {
            fingerprint.append(false)
        }
        if let fileIdentity = node.fileIdentity {
            fingerprint.append(true)
            switch fileIdentity {
            case .resourceIdentifier(let data):
                fingerprint.append(UInt64(0))
                fingerprint.append(data)
            case .fileSystem(let device, let inode, _):
                fingerprint.append(UInt64(1))
                fingerprint.append(device)
                fingerprint.append(inode)
            }
        } else {
            fingerprint.append(false)
        }
        if let cloneIdentity = node.cloneIdentity {
            fingerprint.append(true)
            fingerprint.append(cloneIdentity.device)
            fingerprint.append(cloneIdentity.cloneID)
        } else {
            fingerprint.append(false)
        }
        let childIDs = store.childIDs(of: node.id)
        fingerprint.append(Int64(childIDs.count))
        for childID in childIDs {
            fingerprint.append(childID)
        }
    }
    return fingerprint.description
}

func scanWarningFingerprint(_ warnings: [ScanWarning]) -> String {
    warningFingerprint(warnings.sorted(by: warningPrecedes))
}

func scanOrderedWarningFingerprint(_ warnings: [ScanWarning]) -> String {
    warningFingerprint(warnings)
}

private func warningFingerprint(_ warnings: [ScanWarning]) -> String {
    var fingerprint = StableScanResultFingerprint()
    fingerprint.append(Int64(warnings.count))
    for warning in warnings {
        fingerprint.append(warning.category.rawValue)
        fingerprint.append(warning.path)
        fingerprint.append(warning.message)
    }
    return fingerprint.description
}

private func warningPrecedes(_ lhs: ScanWarning, _ rhs: ScanWarning) -> Bool {
    if lhs.category.rawValue != rhs.category.rawValue {
        return lhs.category.rawValue < rhs.category.rawValue
    }
    if lhs.path != rhs.path {
        return lhs.path < rhs.path
    }
    return lhs.message < rhs.message
}

private struct StableScanResultFingerprint: CustomStringConvertible {
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    private var value = Self.offsetBasis

    var description: String {
        String(format: "%016llx", value)
    }

    mutating func append(_ value: String) {
        append(UInt64(value.utf8.count))
        for byte in value.utf8 {
            append(byte)
        }
    }

    mutating func append(_ value: Data) {
        append(UInt64(value.count))
        for byte in value {
            append(byte)
        }
    }

    mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func append(_ value: Bool) {
        append(UInt8(value ? 1 : 0))
    }

    private mutating func append(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= Self.prime
    }
}
