import Foundation
import XCTest
@testable import LidlessCore

final class HelperJournalTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testRoundTripUsesBinaryPlistAndOwnerOnlyPermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let journal = makeJournal()

        try fixture.store.save(journal)

        XCTAssertEqual(try fixture.store.load(), journal)
        let data = try Data(contentsOf: fixture.store.url)
        XCTAssertEqual(String(decoding: data.prefix(6), as: UTF8.self), "bplist")
        XCTAssertEqual(try permissions(at: fixture.store.url), 0o600)
        XCTAssertEqual(try permissions(at: fixture.store.url.deletingLastPathComponent()), 0o700)
    }

    func testMissingJournalLoadsNil() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        XCTAssertNil(try fixture.store.load())
    }

    func testCorruptJournalIsReportedAndNeverClearedByLoad() throws {
        let fixture = try makeFixture(rawData: Data("not a plist".utf8))
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try fixture.store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.url.path))
        XCTAssertEqual(try Data(contentsOf: fixture.store.url), Data("not a plist".utf8))
    }

    func testClearIsIdempotentAndFsyncsContainingDirectory() throws {
        let syscalls = RecordingJournalSyscalls()
        let fixture = try makeFixture(syscalls: syscalls)
        defer { fixture.cleanup() }
        try fixture.store.save(makeJournal())

        try fixture.store.clear()
        try fixture.store.clear()

        XCTAssertNil(try fixture.store.load())
        XCTAssertEqual(syscalls.fsyncedDirectoryURLs.last, fixture.store.url.deletingLastPathComponent())
    }

    func testFailedFileSyncPreservesOldJournalAndRemovesTempFile() throws {
        let syscalls = RecordingJournalSyscalls()
        let fixture = try makeFixture(syscalls: syscalls)
        defer { fixture.cleanup() }
        let original = makeJournal(phase: .active)
        try fixture.store.save(original)
        syscalls.failNextFileSync = true

        XCTAssertThrowsError(try fixture.store.save(makeJournal(phase: .restoring)))

        XCTAssertEqual(try fixture.store.load(), original)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: fixture.store.url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".tmp.") })
    }

    private func makeJournal(phase: JournalPhase = .activating) -> HelperJournal {
        HelperJournal(
            sessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            connectionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            originalSleepDisabled: false,
            phase: phase,
            armedAt: fixedDate
        )
    }

    private func makeFixture(
        rawData: Data? = nil,
        syscalls: any JournalSyscalling = POSIXJournalSyscalls()
    ) throws -> JournalFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LidlessJournalTests-\(UUID().uuidString)", isDirectory: true)
        let url = root
            .appendingPathComponent("Library/Application Support/Lidless", isDirectory: true)
            .appendingPathComponent("state.plist")
        let store = AtomicJournalStore(url: url, syscalls: syscalls)
        if let rawData {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try rawData.write(to: url)
        }
        return JournalFixture(root: root, store: store)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return mode.intValue & 0o777
    }
}

private struct JournalFixture {
    let root: URL
    let store: AtomicJournalStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecordingJournalSyscalls: JournalSyscalling {
    private let base = POSIXJournalSyscalls()
    var failNextFileSync = false
    private(set) var fsyncedDirectoryURLs: [URL] = []

    func ensureDirectory(at url: URL, permissions: Int) throws {
        try base.ensureDirectory(at: url, permissions: permissions)
    }

    func openExclusiveFile(at url: URL, permissions: Int) throws -> Int32 {
        try base.openExclusiveFile(at: url, permissions: permissions)
    }

    func writeAll(_ data: Data, to descriptor: Int32) throws {
        try base.writeAll(data, to: descriptor)
    }

    func syncFile(_ descriptor: Int32) throws {
        if failNextFileSync {
            failNextFileSync = false
            throw RecordingError.injectedFileSyncFailure
        }
        try base.syncFile(descriptor)
    }

    func closeFile(_ descriptor: Int32) throws {
        try base.closeFile(descriptor)
    }

    func renameItem(at source: URL, to destination: URL) throws {
        try base.renameItem(at: source, to: destination)
    }

    func unlinkItemIfPresent(at url: URL) throws -> Bool {
        try base.unlinkItemIfPresent(at: url)
    }

    func syncDirectory(at url: URL) throws {
        fsyncedDirectoryURLs.append(url)
        try base.syncDirectory(at: url)
    }
}

private enum RecordingError: Error {
    case injectedFileSyncFailure
}
