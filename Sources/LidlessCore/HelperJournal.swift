import Darwin
import Foundation

public enum JournalPhase: String, Codable, Equatable, Sendable {
    case activating
    case active
    case restoring
    case externallyChanged
}

public struct HelperJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: UUID
    public let connectionID: UUID
    public let originalSleepDisabled: Bool
    public var phase: JournalPhase
    public let armedAt: Date

    public init(
        schemaVersion: Int = HelperJournal.currentSchemaVersion,
        sessionID: UUID,
        connectionID: UUID,
        originalSleepDisabled: Bool,
        phase: JournalPhase,
        armedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.connectionID = connectionID
        self.originalSleepDisabled = originalSleepDisabled
        self.phase = phase
        self.armedAt = armedAt
    }
}

public protocol JournalStoring: AnyObject {
    func load() throws -> HelperJournal?
    func save(_ journal: HelperJournal) throws
    func clear() throws
}

public enum JournalStoreError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case journalTooLarge
}

public protocol JournalSyscalling: AnyObject {
    func ensureDirectory(at url: URL, permissions: Int) throws
    func openExclusiveFile(at url: URL, permissions: Int) throws -> Int32
    func writeAll(_ data: Data, to descriptor: Int32) throws
    func syncFile(_ descriptor: Int32) throws
    func closeFile(_ descriptor: Int32) throws
    func renameItem(at source: URL, to destination: URL) throws
    func unlinkItemIfPresent(at url: URL) throws -> Bool
    func syncDirectory(at url: URL) throws
}

public struct JournalPOSIXError: Error, Equatable, Sendable {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }
}

public final class POSIXJournalSyscalls: JournalSyscalling {
    public init() {}

    public func ensureDirectory(at url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        let result = url.withUnsafeFileSystemRepresentation { path in
            Darwin.chmod(path, mode_t(permissions))
        }
        guard result == 0 else {
            throw posixError("chmod directory")
        }
    }

    public func openExclusiveFile(at url: URL, permissions: Int) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            let openWithMode: (UnsafePointer<CChar>, Int32, mode_t) -> Int32 = Darwin.open
            return openWithMode(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(permissions))
        }
        guard descriptor >= 0 else {
            throw posixError("open temporary journal")
        }
        return descriptor
    }

    public func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw posixError("write journal")
                }
                guard result > 0 else {
                    throw JournalPOSIXError(operation: "write journal returned zero", code: EIO)
                }
                offset += result
            }
        }
    }

    public func syncFile(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("fsync journal")
        }
    }

    public func closeFile(_ descriptor: Int32) throws {
        guard Darwin.close(descriptor) == 0 else {
            throw posixError("close journal")
        }
    }

    public func renameItem(at source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw posixError("rename journal")
        }
    }

    public func unlinkItemIfPresent(at url: URL) throws -> Bool {
        let result = url.withUnsafeFileSystemRepresentation { path in
            Darwin.unlink(path)
        }
        if result == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw posixError("unlink journal")
    }

    public func syncDirectory(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            let openWithoutMode: (UnsafePointer<CChar>, Int32) -> Int32 = Darwin.open
            return openWithoutMode(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw posixError("open journal directory")
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("fsync journal directory")
        }
    }

    private func posixError(_ operation: String) -> JournalPOSIXError {
        JournalPOSIXError(operation: operation, code: errno)
    }
}

public final class AtomicJournalStore: JournalStoring {
    public static let productionURL = URL(
        fileURLWithPath: "/Library/Application Support/Lidless/state.plist",
        isDirectory: false
    )

    private static let maximumJournalBytes = 64 * 1_024

    public let url: URL
    private let syscalls: any JournalSyscalling

    public init(url: URL = AtomicJournalStore.productionURL, syscalls: any JournalSyscalling = POSIXJournalSyscalls()) {
        self.url = url
        self.syscalls = syscalls
    }

    public func load() throws -> HelperJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumJournalBytes {
            throw JournalStoreError.journalTooLarge
        }

        let data = try Data(contentsOf: url)
        let journal = try PropertyListDecoder().decode(HelperJournal.self, from: data)
        guard journal.schemaVersion == HelperJournal.currentSchemaVersion else {
            throw JournalStoreError.unsupportedSchema(journal.schemaVersion)
        }
        return journal
    }

    public func save(_ journal: HelperJournal) throws {
        guard journal.schemaVersion == HelperJournal.currentSchemaVersion else {
            throw JournalStoreError.unsupportedSchema(journal.schemaVersion)
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(journal)
        guard data.count <= Self.maximumJournalBytes else {
            throw JournalStoreError.journalTooLarge
        }

        let directory = url.deletingLastPathComponent()
        try syscalls.ensureDirectory(at: directory, permissions: 0o700)
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(UUID().uuidString)",
            isDirectory: false
        )
        var openDescriptor: Int32?

        do {
            let descriptor = try syscalls.openExclusiveFile(at: temporaryURL, permissions: 0o600)
            openDescriptor = descriptor
            try syscalls.writeAll(data, to: descriptor)
            try syscalls.syncFile(descriptor)
            try syscalls.closeFile(descriptor)
            openDescriptor = nil
            try syscalls.renameItem(at: temporaryURL, to: url)
            try syscalls.syncDirectory(at: directory)
        } catch {
            if let openDescriptor {
                try? syscalls.closeFile(openDescriptor)
            }
            _ = try? syscalls.unlinkItemIfPresent(at: temporaryURL)
            throw error
        }
    }

    public func clear() throws {
        let removed = try syscalls.unlinkItemIfPresent(at: url)
        if removed {
            try syscalls.syncDirectory(at: url.deletingLastPathComponent())
        }
    }
}
