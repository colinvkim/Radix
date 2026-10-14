import Compression
import CryptoKit
import Foundation

private nonisolated enum ScanArchiveSectionStreamConstants {
    static let encodedReadByteCount = 64 * 1_024
    static let codecOutputByteCount = 64 * 1_024
}

nonisolated enum ScanArchiveSectionStreamError: LocalizedError {
    case initialization
    case encoding
    case corrupted
    case truncated
    case trailingData
    case noProgress
    case alreadyFinished

    var errorDescription: String? {
        switch self {
        case .initialization:
            return String(
                localized: "Archive section compression could not be initialized.",
                comment: "Archive error detail when the system compression stream cannot be initialized."
            )
        case .encoding:
            return String(
                localized: "Archive section compression failed.",
                comment: "Archive error detail when compressing an archive section fails."
            )
        case .corrupted:
            return String(
                localized: "The compressed archive section is corrupt.",
                comment: "Archive error detail when a compressed archive section cannot be decoded."
            )
        case .truncated:
            return String(
                localized: "The compressed archive section is truncated.",
                comment: "Archive error detail when a compressed archive section ends before its end marker."
            )
        case .trailingData:
            return String(
                localized: "The compressed archive section contains trailing data.",
                comment: "Archive error detail when bytes follow a compressed archive section end marker."
            )
        case .noProgress:
            return String(
                localized: "Archive section compression made no progress.",
                comment: "Archive error detail when a compression stream stalls."
            )
        case .alreadyFinished:
            return String(
                localized: "Archive section compression was already finished.",
                comment: "Archive error detail when a completed compression stream is used again."
            )
        }
    }
}

/// Writes decoded section bytes either directly or through one bounded LZFSE
/// stream. The checksum always covers decoded bytes, independent of transport.
nonisolated struct ScanArchiveSectionWriter {
    private let fileHandle: FileHandle
    private let encoder: ScanArchiveLZFSEEncoder?
    private var hasher = SHA256()
    private var isFinished = false

    init(
        fileHandle: FileHandle,
        encoding: ScanArchiveSectionEncoding
    ) throws {
        self.fileHandle = fileHandle
        self.encoder = encoding == .lzfse ? try ScanArchiveLZFSEEncoder() : nil
    }

    mutating func append(_ data: Data) throws {
        guard !isFinished else {
            throw ScanArchiveSectionStreamError.alreadyFinished
        }
        try Task.checkCancellation()
        hasher.update(data: data)
        if let encoder {
            try encoder.append(data, to: fileHandle)
        } else {
            try fileHandle.write(contentsOf: data)
        }
    }

    mutating func append(_ text: String) throws {
        try append(Data(text.utf8))
    }

    mutating func finish() throws -> String {
        guard !isFinished else {
            throw ScanArchiveSectionStreamError.alreadyFinished
        }
        try Task.checkCancellation()
        if let encoder {
            try encoder.finish(to: fileHandle)
        }
        isFinished = true
        return Data(hasher.finalize()).base64EncodedString()
    }
}

/// Presents decoded section bytes from either identity or LZFSE transport.
nonisolated final class ScanArchiveSectionReader {
    private let identityHandle: FileHandle?
    private let decoder: ScanArchiveLZFSEDecoder?
    private var isClosed = false

    init(
        url: URL,
        encoding: ScanArchiveSectionEncoding
    ) throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        if encoding == .lzfse {
            do {
                self.decoder = try ScanArchiveLZFSEDecoder(fileHandle: fileHandle)
                self.identityHandle = nil
            } catch {
                try? fileHandle.close()
                throw error
            }
        } else {
            self.identityHandle = fileHandle
            self.decoder = nil
        }
    }

    deinit {
        close()
    }

    func read(upToCount byteCount: Int) throws -> Data {
        guard !isClosed, byteCount > 0 else { return Data() }
        try Task.checkCancellation()
        if let decoder {
            return try decoder.read(upToCount: byteCount)
        }
        return try identityHandle?.read(upToCount: byteCount) ?? Data()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let decoder {
            decoder.close()
        } else {
            try? identityHandle?.close()
        }
    }
}

private nonisolated final class ScanArchiveLZFSEEncoder {
    private var stream: compression_stream
    private let outputBuffer: UnsafeMutablePointer<UInt8>
    private var isInitialized = false
    private var didFinish = false

    init() throws {
        outputBuffer = .allocate(
            capacity: ScanArchiveSectionStreamConstants.codecOutputByteCount
        )
        stream = compression_stream(
            dst_ptr: outputBuffer,
            dst_size: 0,
            src_ptr: UnsafePointer(outputBuffer),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream,
            COMPRESSION_STREAM_ENCODE,
            COMPRESSION_LZFSE
        ) == COMPRESSION_STATUS_OK else {
            outputBuffer.deallocate()
            throw ScanArchiveSectionStreamError.initialization
        }
        isInitialized = true
    }

    deinit {
        if isInitialized {
            _ = compression_stream_destroy(&stream)
        }
        outputBuffer.deallocate()
    }

    func append(_ data: Data, to fileHandle: FileHandle) throws {
        guard !didFinish else {
            throw ScanArchiveSectionStreamError.alreadyFinished
        }
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { rawBuffer in
            let source = rawBuffer.bindMemory(to: UInt8.self)
            guard let sourceAddress = source.baseAddress else { return }
            stream.src_ptr = sourceAddress
            stream.src_size = source.count

            while stream.src_size > 0 {
                try Task.checkCancellation()
                let previousSourceSize = stream.src_size
                let (status, producedByteCount) = try process(flags: 0)
                if producedByteCount > 0 {
                    try fileHandle.write(contentsOf: Data(
                        bytes: outputBuffer,
                        count: producedByteCount
                    ))
                }
                guard status != COMPRESSION_STATUS_END else {
                    throw ScanArchiveSectionStreamError.encoding
                }
                guard previousSourceSize != stream.src_size || producedByteCount > 0 else {
                    throw ScanArchiveSectionStreamError.noProgress
                }
            }
        }
    }

    func finish(to fileHandle: FileHandle) throws {
        guard !didFinish else {
            throw ScanArchiveSectionStreamError.alreadyFinished
        }

        stream.src_ptr = UnsafePointer(outputBuffer)
        stream.src_size = 0
        while true {
            try Task.checkCancellation()
            let (status, producedByteCount) = try process(
                flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            )
            if producedByteCount > 0 {
                try fileHandle.write(contentsOf: Data(
                    bytes: outputBuffer,
                    count: producedByteCount
                ))
            }
            if status == COMPRESSION_STATUS_END {
                didFinish = true
                return
            }
            guard producedByteCount > 0 else {
                throw ScanArchiveSectionStreamError.noProgress
            }
        }
    }

    private func process(flags: Int32) throws -> (
        status: compression_status,
        producedByteCount: Int
    ) {
        stream.dst_ptr = outputBuffer
        stream.dst_size = ScanArchiveSectionStreamConstants.codecOutputByteCount
        let status = compression_stream_process(&stream, flags)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw ScanArchiveSectionStreamError.encoding
        }
        return (
            status,
            ScanArchiveSectionStreamConstants.codecOutputByteCount - stream.dst_size
        )
    }
}

private nonisolated final class ScanArchiveLZFSEDecoder {
    private let fileHandle: FileHandle
    private var stream: compression_stream
    private let outputBuffer: UnsafeMutablePointer<UInt8>
    private var encodedBuffer = Data()
    private var encodedOffset = 0
    private var reachedSourceEOF = false
    private var reachedStreamEnd = false
    private var isInitialized = false
    private var isClosed = false

    init(fileHandle: FileHandle) throws {
        self.fileHandle = fileHandle
        outputBuffer = .allocate(
            capacity: ScanArchiveSectionStreamConstants.codecOutputByteCount
        )
        stream = compression_stream(
            dst_ptr: outputBuffer,
            dst_size: 0,
            src_ptr: UnsafePointer(outputBuffer),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_LZFSE
        ) == COMPRESSION_STATUS_OK else {
            outputBuffer.deallocate()
            throw ScanArchiveSectionStreamError.initialization
        }
        isInitialized = true
    }

    deinit {
        close()
        outputBuffer.deallocate()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if isInitialized {
            _ = compression_stream_destroy(&stream)
            isInitialized = false
        }
        try? fileHandle.close()
    }

    func read(upToCount requestedByteCount: Int) throws -> Data {
        guard !isClosed, !reachedStreamEnd, requestedByteCount > 0 else {
            return Data()
        }
        let outputByteCount = min(
            requestedByteCount,
            ScanArchiveSectionStreamConstants.codecOutputByteCount
        )

        while true {
            try Task.checkCancellation()
            if encodedOffset == encodedBuffer.count, !reachedSourceEOF {
                encodedBuffer = try fileHandle.read(
                    upToCount: ScanArchiveSectionStreamConstants.encodedReadByteCount
                ) ?? Data()
                encodedOffset = 0
                reachedSourceEOF = encodedBuffer.isEmpty
            }

            let availableSourceByteCount = encodedBuffer.count - encodedOffset
            var consumedByteCount = 0
            var producedByteCount = 0
            var status = COMPRESSION_STATUS_OK

            encodedBuffer.withUnsafeBytes { rawBuffer in
                let source = rawBuffer.bindMemory(to: UInt8.self)
                if availableSourceByteCount > 0, let baseAddress = source.baseAddress {
                    stream.src_ptr = baseAddress.advanced(by: encodedOffset)
                } else {
                    stream.src_ptr = UnsafePointer(outputBuffer)
                }
                stream.src_size = availableSourceByteCount
                stream.dst_ptr = outputBuffer
                stream.dst_size = outputByteCount

                let flags = reachedSourceEOF
                    ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    : 0
                status = compression_stream_process(&stream, flags)
                consumedByteCount = availableSourceByteCount - stream.src_size
                producedByteCount = outputByteCount - stream.dst_size
            }
            encodedOffset += consumedByteCount

            if status == COMPRESSION_STATUS_ERROR {
                throw reachedSourceEOF
                    ? ScanArchiveSectionStreamError.truncated
                    : ScanArchiveSectionStreamError.corrupted
            }
            if status == COMPRESSION_STATUS_END {
                try validateNoTrailingData()
                reachedStreamEnd = true
                if producedByteCount == 0 {
                    return Data()
                }
                return Data(bytes: outputBuffer, count: producedByteCount)
            }
            if producedByteCount > 0 {
                return Data(bytes: outputBuffer, count: producedByteCount)
            }
            if consumedByteCount > 0 {
                continue
            }
            if reachedSourceEOF {
                throw ScanArchiveSectionStreamError.truncated
            }
            if availableSourceByteCount == 0 {
                continue
            }
            throw ScanArchiveSectionStreamError.noProgress
        }
    }

    private func validateNoTrailingData() throws {
        guard encodedOffset == encodedBuffer.count else {
            throw ScanArchiveSectionStreamError.trailingData
        }
        let trailingData = try fileHandle.read(upToCount: 1) ?? Data()
        guard trailingData.isEmpty else {
            throw ScanArchiveSectionStreamError.trailingData
        }
        reachedSourceEOF = true
    }
}
