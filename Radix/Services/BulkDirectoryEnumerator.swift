//
//  BulkDirectoryEnumerator.swift
//  Radix
//
//  Created by Codex on 7/9/26.
//

import Darwin
import Foundation

/// Immediate-child enumeration backed by `getattrlistbulk(2)`.
///
/// Foundation's URL enumerator is a good compatibility path, but a scanner pays
/// heavily for materializing resource values one URL at a time. Darwin can return
/// the directory entry and the metadata Radix needs in the same kernel operation.
/// Unsupported filesystems return `nil` so callers can transparently fall back.
nonisolated enum BulkDirectoryEnumerator {
    /// Runs only after the native entry payload and exact name have been validated.
    /// Returning false skips native-name copying, metadata construction, URL
    /// materialization, and package classification for that entry.
    typealias EntryInclusion = @Sendable (
        _ childName: String,
        _ isDirectory: Bool
    ) -> Bool

    /// A single validated child component, stored exactly as NUL-terminated
    /// filesystem bytes for descriptor-relative syscalls such as `openat(2)`.
    struct NativeName: Hashable, Sendable {
        private let nullTerminatedBytes: [UInt8]

        init?<Bytes: Collection>(fileSystemBytes bytes: Bytes) where Bytes.Element == UInt8 {
            guard Self.validatedDecodedName(fileSystemBytes: bytes) != nil else {
                return nil
            }
            self.init(validatedFileSystemBytes: bytes)
        }

        fileprivate init<Bytes: Collection>(
            validatedFileSystemBytes bytes: Bytes
        ) where Bytes.Element == UInt8 {
            var storage: [UInt8] = []
            storage.reserveCapacity(bytes.count + 1)
            storage.append(contentsOf: bytes)
            storage.append(0)
            nullTerminatedBytes = storage
        }

        fileprivate static func validatedDecodedName<Bytes: Collection>(
            fileSystemBytes bytes: Bytes
        ) -> String? where Bytes.Element == UInt8 {
            guard !bytes.isEmpty,
                  !bytes.contains(0),
                  !bytes.contains(UInt8(ascii: "/")),
                  !bytes.elementsEqual([UInt8(ascii: ".")]),
                  !bytes.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")]),
                  let decodedName = String(bytes: bytes, encoding: .utf8),
                  decodedName.utf8.elementsEqual(bytes) else {
                return nil
            }
            return decodedName
        }

        /// The body must not retain the pointer after returning.
        func withUnsafeFileSystemRepresentation<Result>(
            _ body: (UnsafePointer<CChar>) throws -> Result
        ) rethrows -> Result {
            try nullTerminatedBytes.withUnsafeBytes { rawBuffer in
                let pointer = rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                return try body(pointer)
            }
        }
    }

    /// Owns one native directory descriptor and closes it exactly once.
    ///
    /// The handle is lock-protected so future descriptor-relative work can pass
    /// leases between tasks without racing a cancellation or cursor teardown.
    final class NativeDirectoryHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        init(owning descriptor: Int32) {
            precondition(descriptor >= 0, "NativeDirectoryHandle requires an open descriptor")
            self.descriptor = descriptor
        }

        deinit {
            close()
        }

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return descriptor >= 0
        }

        func close() {
            lock.lock()
            guard descriptor >= 0 else {
                lock.unlock()
                return
            }
            let descriptorToClose = descriptor
            descriptor = -1
            lock.unlock()
            Darwin.close(descriptorToClose)
        }

        fileprivate func withDescriptor<Result>(
            _ body: (Int32) throws -> Result
        ) rethrows -> Result? {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return nil }
            return try body(descriptor)
        }
    }

    struct Batch: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
        /// `nil` when no entry-inclusion callback was installed. Otherwise,
        /// counts only entries rejected by that callback, excluding hidden and
        /// dataless entries filtered before the callback runs.
        let entryInclusionExcludedItemCount: Int?
    }

    struct Result: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
    }

    enum StreamError: Error {
        case unavailable
    }

    /// Single-consumer cursor over the batches returned by `getattrlistbulk(2)`.
    /// Dropping a partially consumed cursor closes its descriptor, which lets
    /// threshold probes stop without reading or retaining the rest of a wide directory.
    final class Cursor: @unchecked Sendable {
        private let directoryURL: URL
        private let includeHiddenFiles: Bool
        private let loadsPackageMetadata: Bool
        private let metadataLoader: ScanMetadataLoader
        private let entryInclusion: EntryInclusion?
        private let lock = NSLock()
        private let directoryHandle: NativeDirectoryHandle?
        private let descriptorLease: ScanDirectoryDescriptorPool.Lease?
        private var attributes = requestedAttributes
        private var isFinished = false
        private var buffer: UnsafeMutableRawBufferPointer?
        private let forcedUnavailableAfterBatchCount: Int?
        private var successfulBatchCount = 0
        // ASCII decoding is injective and cannot have canonical-equivalence
        // collisions. Retain collision state only for the uncommon Unicode names.
        private var nonASCIINativeNameByDecodedName: [String: NativeName] = [:]

        fileprivate init(
            directoryURL: URL,
            includeHiddenFiles: Bool,
            loadsPackageMetadata: Bool,
            metadataLoader: ScanMetadataLoader,
            entryInclusion: EntryInclusion?,
            directoryHandle: NativeDirectoryHandle? = nil,
            descriptorLease: ScanDirectoryDescriptorPool.Lease? = nil,
            forcedUnavailableAfterBatchCount: Int?
        ) {
            self.directoryURL = directoryURL
            self.includeHiddenFiles = includeHiddenFiles
            self.loadsPackageMetadata = loadsPackageMetadata
            self.metadataLoader = metadataLoader
            self.entryInclusion = entryInclusion
            self.directoryHandle = directoryHandle
            self.descriptorLease = descriptorLease
            self.forcedUnavailableAfterBatchCount = forcedUnavailableAfterBatchCount
            buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: bufferCapacity,
                alignment: 8
            )
        }

        deinit {
            closeDescriptor()
            releaseBuffer()
        }

        func invalidate() {
            lock.lock()
            isFinished = true
            closeDescriptor()
            releaseBuffer()
            lock.unlock()
        }

        func nextBatch(cancellationCheck: CancellationCheck) throws -> Batch? {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return nil }
            try cancellationCheck()
            if let forcedUnavailableAfterBatchCount,
               successfulBatchCount == forcedUnavailableAfterBatchCount {
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                throw StreamError.unavailable
            }

            guard let buffer,
                  let bufferAddress = buffer.baseAddress else {
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                throw StreamError.unavailable
            }
            guard let syscallResult = withDescriptor({ descriptor in
                let count = getattrlistbulk(
                    descriptor,
                    &attributes,
                    bufferAddress,
                    buffer.count,
                    BulkDirectoryEnumerator.attributeOptions
                )
                return (count: count, errorCode: count < 0 ? errno : 0)
            }) else {
                isFinished = true
                releaseBuffer()
                throw StreamError.unavailable
            }
            let count = syscallResult.count
            if count < 0 {
                let errorCode = syscallResult.errorCode
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                if unsupportedErrors.contains(errorCode) {
                    throw StreamError.unavailable
                }
                throw posixError(errorCode, url: directoryURL)
            }
            guard count > 0 else {
                try cancellationCheck()
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                return nil
            }

            var entries: [DirectoryEntry] = []
            var enumeratedItemCount = 0
            var entryInclusionExcludedItemCount = 0
            do {
                guard try parseBatch(
                    bufferAddress: UnsafeRawPointer(bufferAddress),
                    bufferByteCount: buffer.count,
                    entryCount: Int(count),
                    directoryURL: directoryURL,
                    includeHiddenFiles: includeHiddenFiles,
                    loadsPackageMetadata: loadsPackageMetadata,
                    metadataLoader: metadataLoader,
                    entryInclusion: entryInclusion,
                    entries: &entries,
                    enumeratedItemCount: &enumeratedItemCount,
                    entryInclusionExcludedItemCount: &entryInclusionExcludedItemCount,
                    nonASCIINativeNameByDecodedName: &nonASCIINativeNameByDecodedName,
                    cancellationCheck: cancellationCheck
                ) else {
                    isFinished = true
                    closeDescriptor()
                    throw StreamError.unavailable
                }
            } catch {
                isFinished = true
                closeDescriptor()
                releaseBuffer()
                throw error
            }
            successfulBatchCount += 1
            return Batch(
                entries: entries,
                enumeratedItemCount: enumeratedItemCount,
                entryInclusionExcludedItemCount: entryInclusion == nil
                    ? nil
                    : entryInclusionExcludedItemCount
            )
        }

        private func closeDescriptor() {
            directoryHandle?.close()
        }

        private func withDescriptor<Result>(
            _ body: (Int32) throws -> Result
        ) rethrows -> Result? {
            if let directoryHandle {
                return try directoryHandle.withDescriptor(body)
            }
            return try descriptorLease?.withDescriptor(body)
        }

        private func releaseBuffer() {
            buffer?.deallocate()
            buffer = nil
        }
    }

    private static let bufferCapacity = 64 * 1_024
    private static let unsupportedErrors: Set<Int32> = [EINVAL, ENOTSUP, ENOSYS]
    static let attributeOptions = UInt64(
        FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED | FSOPT_RETURN_REALDEV
    )

    static func directoryEntries(
        at directoryURL: URL,
        includeHiddenFiles: Bool,
        loadsPackageMetadata: Bool = true,
        metadataLoader: ScanMetadataLoader,
        entryInclusion: EntryInclusion? = nil,
        cancellationCheck: CancellationCheck,
        forcedUnavailableAfterBatchCount: Int? = nil
    ) throws -> Result? {
        var entries: [DirectoryEntry] = []
        var enumeratedItemCount = 0
        let cursor = try makeCursor(
            at: directoryURL,
            includeHiddenFiles: includeHiddenFiles,
            loadsPackageMetadata: loadsPackageMetadata,
            metadataLoader: metadataLoader,
            entryInclusion: entryInclusion,
            cancellationCheck: cancellationCheck,
            forcedUnavailableAfterBatchCount: forcedUnavailableAfterBatchCount
        )
        do {
            while let batch = try cursor.nextBatch(cancellationCheck: cancellationCheck) {
                entries.append(contentsOf: batch.entries)
                enumeratedItemCount += batch.enumeratedItemCount
            }
        } catch StreamError.unavailable {
            return nil
        }
        return Result(
            entries: entries,
            enumeratedItemCount: enumeratedItemCount
        )
    }

    static func makeCursor(
        at directoryURL: URL,
        includeHiddenFiles: Bool,
        loadsPackageMetadata: Bool = true,
        metadataLoader: ScanMetadataLoader,
        entryInclusion: EntryInclusion? = nil,
        cancellationCheck: CancellationCheck,
        forcedUnavailableAfterBatchCount: Int? = nil
    ) throws -> Cursor {
        try cancellationCheck()
        #if DEBUG
        let openStart = metadataLoader.diagnostics?.start()
        #endif
        let descriptor = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw posixError(errno, url: directoryURL)
        }
        #if DEBUG
        metadataLoader.diagnostics?.record(
            operation: "bulk.cursor.open",
            url: directoryURL,
            startedAt: openStart
        )
        #endif
        return Cursor(
            directoryURL: directoryURL,
            includeHiddenFiles: includeHiddenFiles,
            loadsPackageMetadata: loadsPackageMetadata,
            metadataLoader: metadataLoader,
            entryInclusion: entryInclusion,
            directoryHandle: NativeDirectoryHandle(owning: descriptor),
            forcedUnavailableAfterBatchCount: forcedUnavailableAfterBatchCount
        )
    }

    /// Creates a cursor that borrows a pool lease. The caller retains ownership
    /// so the same opened directory can resolve child names after enumeration.
    static func makeCursor(
        at directoryURL: URL,
        borrowing descriptorLease: ScanDirectoryDescriptorPool.Lease,
        includeHiddenFiles: Bool,
        loadsPackageMetadata: Bool = true,
        metadataLoader: ScanMetadataLoader,
        entryInclusion: EntryInclusion? = nil,
        cancellationCheck: CancellationCheck,
        forcedUnavailableAfterBatchCount: Int? = nil
    ) throws -> Cursor {
        do {
            try cancellationCheck()
        } catch {
            throw error
        }
        guard descriptorLease.isOpen else {
            throw StreamError.unavailable
        }
        return Cursor(
            directoryURL: directoryURL,
            includeHiddenFiles: includeHiddenFiles,
            loadsPackageMetadata: loadsPackageMetadata,
            metadataLoader: metadataLoader,
            entryInclusion: entryInclusion,
            descriptorLease: descriptorLease,
            forcedUnavailableAfterBatchCount: forcedUnavailableAfterBatchCount
        )
    }

    /// Creates a cursor that takes ownership of an already-open directory handle.
    /// The handle is closed on exhaustion, invalidation, error, or cursor deinit.
    static func makeCursor(
        at directoryURL: URL,
        owning directoryHandle: NativeDirectoryHandle,
        includeHiddenFiles: Bool,
        loadsPackageMetadata: Bool = true,
        metadataLoader: ScanMetadataLoader,
        entryInclusion: EntryInclusion? = nil,
        cancellationCheck: CancellationCheck,
        forcedUnavailableAfterBatchCount: Int? = nil
    ) throws -> Cursor {
        do {
            try cancellationCheck()
        } catch {
            directoryHandle.close()
            throw error
        }
        guard directoryHandle.isOpen else {
            throw StreamError.unavailable
        }
        return Cursor(
            directoryURL: directoryURL,
            includeHiddenFiles: includeHiddenFiles,
            loadsPackageMetadata: loadsPackageMetadata,
            metadataLoader: metadataLoader,
            entryInclusion: entryInclusion,
            directoryHandle: directoryHandle,
            forcedUnavailableAfterBatchCount: forcedUnavailableAfterBatchCount
        )
    }

    private static var requestedAttributes: attrlist {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = requestedCommonAttributes
        attributes.fileattr = requiredFileAttributes
        attributes.forkattr = requestedExtendedCommonAttributes
        return attributes
    }

    private static var requestedCommonAttributes: attrgroup_t {
        requiredCommonAttributes | attrgroup_t(ATTR_CMN_FNDRINFO)
    }

    private static var requiredCommonAttributes: attrgroup_t {
        var attributes = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attributes |= attrgroup_t(ATTR_CMN_ERROR)
        attributes |= attrgroup_t(ATTR_CMN_NAME)
        attributes |= attrgroup_t(ATTR_CMN_DEVID)
        attributes |= attrgroup_t(ATTR_CMN_OBJTYPE)
        attributes |= attrgroup_t(ATTR_CMN_MODTIME)
        attributes |= attrgroup_t(ATTR_CMN_FLAGS)
        attributes |= attrgroup_t(ATTR_CMN_USERACCESS)
        attributes |= attrgroup_t(ATTR_CMN_FILEID)
        return attributes
    }

    private static var requiredFileAttributes: attrgroup_t {
        attrgroup_t(
            ATTR_FILE_LINKCOUNT |
            ATTR_FILE_TOTALSIZE |
            ATTR_FILE_ALLOCSIZE |
            ATTR_FILE_DATAALLOCSIZE
        )
    }

    private static var requestedExtendedCommonAttributes: attrgroup_t {
        requiredCloneMappingAttributes | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
    }

    private static var requiredCloneMappingAttributes: attrgroup_t {
        attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
    }

    /// Bulk enumeration can succeed even when an individual filesystem cannot
    /// vend every requested attribute. Those default-packed values are not a
    /// safe substitute for scanner metadata, so select the Foundation path.
    static func hasRequiredMetadataAttributes(
        _ returned: attribute_set_t,
        objectType: fsobj_type_t
    ) -> Bool {
        guard returned.commonattr & requiredCommonAttributes == requiredCommonAttributes else {
            return false
        }
        return objectType == VDIR.rawValue ||
            returned.fileattr & requiredFileAttributes == requiredFileAttributes
    }

    private struct ParsedEntryMetadata {
        let isSymbolicLink: Bool
        let logicalSize: Int64
        let allocatedSize: Int64
        let dataAllocatedSize: Int64
        let modificationTime: timespec
        let isReadable: Bool
        let device: UInt64
        let inode: UInt64
        let linkCount: UInt64
        let cloneID: UInt64?
        let mayShareDataBlocks: Bool
    }

    private struct ParsedEntry {
        let decodedName: String
        /// Borrows the current `getattrlistbulk` buffer and must be copied before
        /// the cursor advances to another kernel batch.
        let nativeNameBytes: UnsafeBufferPointer<UInt8>
        let isHidden: Bool
        let isDirectory: Bool
        let isDataless: Bool
        let hasFinderPackageFlag: Bool?
        let entryError: Int32?
        let metadata: ParsedEntryMetadata?
    }

    private static func parseBatch(
        bufferAddress: UnsafeRawPointer,
        bufferByteCount: Int,
        entryCount: Int,
        directoryURL: URL,
        includeHiddenFiles: Bool,
        loadsPackageMetadata: Bool,
        metadataLoader: ScanMetadataLoader,
        entryInclusion: EntryInclusion?,
        entries: inout [DirectoryEntry],
        enumeratedItemCount: inout Int,
        entryInclusionExcludedItemCount: inout Int,
        nonASCIINativeNameByDecodedName: inout [String: NativeName],
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        let bufferEnd = bufferAddress.advanced(by: bufferByteCount)
        var entryAddress = bufferAddress

        for index in 0..<entryCount {
            if index.isMultiple(of: 64) {
                try cancellationCheck()
            }
            guard MemoryLayout<UInt32>.size <= entryAddress.distance(to: bufferEnd) else {
                return false
            }
            let entryLength = Int(entryAddress.loadUnaligned(as: UInt32.self))
            guard entryLength >= MemoryLayout<UInt32>.size,
                  entryLength <= entryAddress.distance(to: bufferEnd) else {
                return false
            }

            let entryEnd = entryAddress.advanced(by: entryLength)
            guard let parsed = parsedEntry(
                at: entryAddress,
                end: entryEnd
            ) else {
                return false
            }
            enumeratedItemCount += 1

            guard !parsed.isDataless else {
                entryAddress = entryEnd
                continue
            }

            guard includeHiddenFiles || !parsed.isHidden else {
                entryAddress = entryEnd
                continue
            }
            if let entryInclusion,
               !entryInclusion(parsed.decodedName, parsed.isDirectory) {
                entryInclusionExcludedItemCount += 1
                entryAddress = entryEnd
                continue
            }

            let isASCII = parsed.nativeNameBytes.allSatisfy { $0 < 0x80 }
            // Ordinary ASCII leaves never perform descriptor-relative work.
            // Keep exact bytes for traversal, exceptional entries, and Unicode
            // collision detection across kernel batches.
            let needsNativeName = !isASCII || parsed.isDirectory ||
                parsed.entryError != nil || parsed.metadata?.isSymbolicLink == true
            let nativeName = needsNativeName
                ? NativeName(validatedFileSystemBytes: parsed.nativeNameBytes)
                : nil
            if !isASCII, let nativeName {
                if let previousName = nonASCIINativeNameByDecodedName[parsed.decodedName],
                   previousName != nativeName {
                    // Canonically equivalent Unicode names compare equal as Swift
                    // strings. Distinct native bytes would collide in path-keyed
                    // scan state, so abandon bulk parsing for this directory.
                    return false
                }
                nonASCIINativeNameByDecodedName[parsed.decodedName] = nativeName
            }
            entries.append(materializedEntry(
                parsed,
                nativeName: nativeName,
                under: directoryURL,
                loadsPackageMetadata: loadsPackageMetadata,
                metadataLoader: metadataLoader
            ))
            entryAddress = entryEnd
        }
        try cancellationCheck()
        return true
    }

    private static func parsedEntry(
        at entryAddress: UnsafeRawPointer,
        end entryEnd: UnsafeRawPointer
    ) -> ParsedEntry? {
        var cursor = AttributeCursor(
            current: entryAddress.advanced(by: MemoryLayout<UInt32>.size),
            end: entryEnd
        )

        // ATTR_CMN_RETURNED_ATTRS is always first. For getattrlistbulk,
        // ATTR_CMN_ERROR immediately follows it; remaining values follow the
        // declaration order from getattrlist(2). FSOPT_PACK_INVAL_ATTRS keeps
        // this fixed portion stable even when a filesystem lacks an attribute.
        guard let returned: attribute_set_t = cursor.read(),
              let entryError: UInt32 = cursor.read() else {
            return nil
        }

        let nameReferenceAddress = cursor.current
        guard let nameReference: attrreference_t = cursor.read(),
              let parsedName = parsedName(
                  reference: nameReference,
                  referenceAddress: nameReferenceAddress,
                  entryAddress: entryAddress,
                  entryEnd: entryEnd
              ),
              let deviceID: dev_t = cursor.read(),
              let objectType: fsobj_type_t = cursor.read(),
              let modificationTime: timespec = cursor.read(),
              let finderPackageBit = cursor.readFinderInfoPackageBit(),
              let flags: UInt32 = cursor.read(),
              let userAccess: UInt32 = cursor.read(),
              let fileID: UInt64 = cursor.read() else {
            return nil
        }
        let name = parsedName.compatibilityName

        var fileLinkCount: UInt32 = 1
        var fileLogicalSize: off_t = 0
        var fileAllocatedSize: off_t = 0
        var fileDataAllocatedSize: off_t = 0
        if objectType == VREG.rawValue || returned.fileattr != 0 {
            // Once a file-attribute payload is present, FSOPT_PACK_INVAL_ATTRS
            // physically packs every requested field in that group. Advance
            // through the complete layout before inspecting `returned`.
            guard let linkCount: UInt32 = cursor.read(),
                  let logicalSize: off_t = cursor.read(),
                  let allocatedSize: off_t = cursor.read(),
                  let dataAllocatedSize: off_t = cursor.read() else {
                return nil
            }
            fileLinkCount = linkCount
            fileLogicalSize = logicalSize
            fileAllocatedSize = allocatedSize
            fileDataAllocatedSize = dataAllocatedSize
        }

        guard let cloneID: UInt64 = cursor.read(),
              let extendedFlags: UInt64 = cursor.read(),
              let cloneReferenceCount: UInt32 = cursor.read() else {
            return nil
        }

        let isDirectory = objectType == VDIR.rawValue
        let isSymbolicLink = objectType == VLNK.rawValue
        let isHidden = name.first == "." || (flags & UInt32(UF_HIDDEN)) != 0
        let isDataless = ScanMetadataLoader.isDataless(fileFlags: flags)
        let hasFinderPackageFlag: Bool?
        if returned.commonattr & attrgroup_t(ATTR_CMN_FNDRINFO) != 0 {
            hasFinderPackageFlag = finderPackageBit
        } else {
            hasFinderPackageFlag = nil
        }

        if entryError != 0 {
            guard entryError <= UInt32(Int32.max) else { return nil }
            return ParsedEntry(
                decodedName: name,
                nativeNameBytes: parsedName.nativeNameBytes,
                isHidden: isHidden,
                isDirectory: isDirectory,
                isDataless: isDataless,
                hasFinderPackageFlag: hasFinderPackageFlag,
                entryError: Int32(entryError),
                metadata: nil
            )
        }

        guard hasRequiredMetadataAttributes(returned, objectType: objectType) else {
            return nil
        }

        let logicalSize: off_t = isDirectory ? 0 : fileLogicalSize
        let allocatedSize: off_t = isDirectory ? 0 : fileAllocatedSize
        let dataAllocatedSize: off_t = isDirectory ? 0 : fileDataAllocatedSize
        let parsedCloneID: UInt64?
        if !isDirectory,
           !isSymbolicLink,
           returned.forkattr & requiredCloneMappingAttributes == requiredCloneMappingAttributes,
           cloneID > 0,
           cloneReferenceCount > 1 {
            parsedCloneID = cloneID
        } else {
            parsedCloneID = nil
        }
        let metadata = ParsedEntryMetadata(
            isSymbolicLink: isSymbolicLink,
            logicalSize: max(Int64(logicalSize), 0),
            allocatedSize: max(Int64(allocatedSize), 0),
            dataAllocatedSize: max(Int64(dataAllocatedSize), 0),
            modificationTime: modificationTime,
            isReadable: (userAccess & UInt32(R_OK)) != 0,
            device: UInt64(truncatingIfNeeded: deviceID),
            inode: fileID,
            linkCount: isDirectory ? 1 : max(UInt64(fileLinkCount), 1),
            cloneID: parsedCloneID,
            mayShareDataBlocks: !isDirectory && !isSymbolicLink &&
                returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 &&
                extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
        )
        return ParsedEntry(
            decodedName: name,
            nativeNameBytes: parsedName.nativeNameBytes,
            isHidden: isHidden,
            isDirectory: isDirectory,
            isDataless: isDataless,
            hasFinderPackageFlag: hasFinderPackageFlag,
            entryError: nil,
            metadata: metadata
        )
    }

    private static func materializedEntry(
        _ parsed: ParsedEntry,
        nativeName: NativeName?,
        under directoryURL: URL,
        loadsPackageMetadata: Bool,
        metadataLoader: ScanMetadataLoader
    ) -> DirectoryEntry {
        let directoryHint: URL.DirectoryHint = parsed.isDirectory ? .isDirectory : .notDirectory
        let url = directoryURL.appending(path: parsed.decodedName, directoryHint: directoryHint)
        if let entryError = parsed.entryError {
            return DirectoryEntry(
                url: url,
                metadata: nil,
                localizedEnumerationError: posixError(entryError, url: url),
                isDirectoryHint: parsed.isDirectory,
                nativeName: nativeName
            )
        }

        guard let metadata = parsed.metadata else {
            preconditionFailure("A parsed native entry must have metadata or an entry error")
        }
        let isPackage = parsed.isDirectory && loadsPackageMetadata && metadataLoader.isPackageDirectory(
            at: url,
            hasFinderPackageFlag: parsed.hasFinderPackageFlag
        )
        let lastModified = Date(
            timeIntervalSinceReferenceDate: Double(metadata.modificationTime.tv_sec) -
                Date.timeIntervalBetween1970AndReferenceDate +
                Double(metadata.modificationTime.tv_nsec) / 1_000_000_000
        )
        let classifiedMetadata = NodeMetadata(
            isDirectory: parsed.isDirectory,
            isPackage: isPackage,
            isSymbolicLink: metadata.isSymbolicLink,
            logicalSize: metadata.logicalSize,
            allocatedSize: metadata.allocatedSize,
            dataAllocatedSize: metadata.dataAllocatedSize,
            lastModified: lastModified,
            isReadable: metadata.isReadable,
            volumeCapacity: nil,
            fileIdentity: FileIdentity(device: metadata.device, inode: metadata.inode),
            linkCount: metadata.linkCount,
            cloneIdentity: metadata.cloneID.map {
                CloneIdentity(device: metadata.device, cloneID: $0)
            },
            mayShareDataBlocks: metadata.mayShareDataBlocks
        )
        return DirectoryEntry(
            url: url,
            metadata: classifiedMetadata,
            nativeName: nativeName
        )
    }

    private static func parsedName(
        reference: attrreference_t,
        referenceAddress: UnsafeRawPointer,
        entryAddress: UnsafeRawPointer,
        entryEnd: UnsafeRawPointer
    ) -> (
        compatibilityName: String,
        nativeNameBytes: UnsafeBufferPointer<UInt8>
    )? {
        guard reference.attr_dataoffset >= 0 else { return nil }
        let dataOffset = Int(reference.attr_dataoffset)
        guard dataOffset <= referenceAddress.distance(to: entryEnd) else { return nil }
        let start = referenceAddress.advanced(by: dataOffset)
        let byteCount = Int(reference.attr_length)
        guard start >= entryAddress,
              start <= entryEnd,
              byteCount <= start.distance(to: entryEnd),
              byteCount > 0 else {
            return nil
        }

        let bytes = UnsafeRawBufferPointer(start: start, count: byteCount)
        let stringByteCount = bytes.last == 0 ? byteCount - 1 : byteCount
        let nameBytes = UnsafeRawBufferPointer(
            start: start,
            count: stringByteCount
        ).bindMemory(to: UInt8.self)
        guard let compatibilityName = NativeName.validatedDecodedName(
            fileSystemBytes: nameBytes
        ) else {
            // A lossy compatibility URL could collide with another child ID.
            // Abandon native parsing for this directory and let Foundation
            // apply its filesystem-specific path representation instead.
            return nil
        }
        return (
            compatibilityName: compatibilityName,
            nativeNameBytes: nameBytes
        )
    }

    private static func posixError(_ code: Int32, url: URL) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSURLErrorKey: url]
        )
    }
}

private nonisolated struct AttributeCursor {
    var current: UnsafeRawPointer
    let end: UnsafeRawPointer

    mutating func read<T>() -> T? {
        let size = MemoryLayout<T>.size
        let alignedSize = (size + 3) & ~3
        guard size <= current.distance(to: end),
              alignedSize <= current.distance(to: end) else {
            return nil
        }
        let value = current.loadUnaligned(as: T.self)
        current = current.advanced(by: alignedSize)
        return value
    }

    mutating func readFinderInfoPackageBit() -> Bool? {
        let byteCount = 32
        guard byteCount <= current.distance(to: end) else {
            return nil
        }
        let hasPackageBit = current.load(fromByteOffset: 8, as: UInt8.self) & 0x20 != 0
        current = current.advanced(by: byteCount)
        return hasPackageBit
    }
}
