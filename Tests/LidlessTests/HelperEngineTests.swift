import Foundation
import XCTest
@testable import LidlessCore

final class HelperEngineTests: XCTestCase {
    private let connection = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var events: [EngineEvent]!
    private var pmset: FakePMSetController!
    private var journal: FakeJournalStore!
    private var wallClock: FakeWallClock!
    private var monotonicClock: FakeMonotonicClock!
    private var engine: HelperEngine!

    override func setUp() {
        super.setUp()
        events = []
        pmset = FakePMSetController(events: { [unowned self] in events.append($0) })
        journal = FakeJournalStore(events: { [unowned self] in events.append($0) })
        wallClock = FakeWallClock(now: fixedDate)
        monotonicClock = FakeMonotonicClock(now: 100)
        engine = HelperEngine(
            pmset: pmset,
            journal: journal,
            wallClock: wallClock,
            monotonicClock: monotonicClock
        )
    }

    func testArmJournalsBeforeMutationAndReturnsOwnedSession() throws {
        pmset.observed = false

        let session = try engine.arm(connectionID: connection, sample: safeBattery, floor: BatteryFloor(10)!)

        XCTAssertEqual(events, [
            .read(false),
            .journal(.activating),
            .set(true),
            .read(true),
            .journal(.active)
        ])
        XCTAssertEqual(engine.status().state, .active)
        XCTAssertEqual(engine.status().sessionID, session)
        XCTAssertEqual(engine.nextLeaseDeadline(), 130)
    }

    func testRefusesExternalSleepDisabledWithoutMutation() {
        pmset.observed = true

        XCTAssertThrowsError(try engine.arm(connectionID: connection, sample: safeBattery, floor: BatteryFloor(10)!)) {
            XCTAssertEqual($0 as? HelperError, .externallyDisabled)
        }
        XCTAssertEqual(events, [.read(true)])
        XCTAssertNil(journal.stored)
    }

    func testUnsafeArmNeverReadsJournalOrTouchesPMSet() {
        XCTAssertThrowsError(try engine.arm(connectionID: connection, sample: atFloor, floor: BatteryFloor(10)!)) {
            XCTAssertEqual($0 as? HelperError, .unsafe(.atBatteryFloor))
        }
        XCTAssertEqual(events, [])
        XCTAssertNil(journal.stored)
    }

    func testDisarmRestoresAndClearsOnlyAfterVerification() throws {
        let session = try arm()
        events.removeAll()

        try engine.disarm(connectionID: connection, sessionID: session, reason: .user)

        XCTAssertEqual(events, [
            .journal(.restoring),
            .set(false),
            .read(false),
            .clearJournal
        ])
        XCTAssertEqual(engine.status().state, .inactive)
        XCTAssertEqual(engine.status().lastDisarmReason, .user)
    }

    func testFailedRestoreKeepsJournalBlocksArmAndCanRetryRecovery() throws {
        let session = try arm()
        pmset.setShouldFail = true

        XCTAssertThrowsError(try engine.disarm(connectionID: connection, sessionID: session, reason: .batteryFloor)) {
            XCTAssertEqual($0 as? HelperError, .restoreFailed)
        }
        XCTAssertEqual(engine.status().state, .faulted)
        XCTAssertNotNil(journal.stored)
        XCTAssertThrowsError(try engine.arm(connectionID: connection, sample: safeBattery, floor: BatteryFloor(10)!)) {
            XCTAssertEqual($0 as? HelperError, .faulted)
        }

        pmset.setShouldFail = false
        try engine.recoverAtLaunch()
        XCTAssertFalse(pmset.observed)
        XCTAssertNil(journal.stored)
        XCTAssertEqual(engine.status().state, .inactive)
    }

    func testLaunchRecoveryRestoresBeforeAcceptingWork() throws {
        journal.stored = activeJournal(originalSleepDisabled: false)
        pmset.observed = true

        try engine.recoverAtLaunch()

        XCTAssertEqual(events, [
            .journal(.restoring),
            .set(false),
            .read(false),
            .clearJournal
        ])
        XCTAssertFalse(pmset.observed)
        XCTAssertNil(journal.stored)
        XCTAssertEqual(engine.status().state, .inactive)
    }

    func testCorruptJournalFailsSafeToZeroRemainsPresentAndFaulted() {
        journal.loadShouldFail = true
        pmset.observed = true

        XCTAssertThrowsError(try engine.recoverAtLaunch()) {
            XCTAssertEqual($0 as? HelperError, .corruptJournal)
        }

        XCTAssertEqual(events, [.set(false), .read(false)])
        XCTAssertFalse(pmset.observed)
        XCTAssertTrue(journal.corruptFileStillExists)
        XCTAssertEqual(engine.status().state, .faulted)
    }

    func testUnsafeRenewRestoresBeforeReturningCutoff() throws {
        let session = try arm()
        events.removeAll()

        XCTAssertThrowsError(
            try engine.renew(
                connectionID: connection,
                sessionID: session,
                sample: atFloor,
                floor: BatteryFloor(10)!
            )
        ) {
            XCTAssertEqual($0 as? HelperError, .unsafe(.atBatteryFloor))
        }
        XCTAssertFalse(pmset.observed)
        XCTAssertNil(journal.stored)
        XCTAssertEqual(engine.status().lastDisarmReason, .batteryFloor)
    }

    func testRenewHealthCheckFailureRestoresAndReportsOriginalFailure() throws {
        let session = try arm()
        pmset.remainingReadFailures = 1
        events.removeAll()

        XCTAssertThrowsError(
            try engine.renew(
                connectionID: connection,
                sessionID: session,
                sample: safeBattery,
                floor: BatteryFloor(10)!
            )
        ) { XCTAssertEqual($0 as? HelperError, .healthCheckFailed) }

        XCTAssertFalse(pmset.observed)
        XCTAssertEqual(engine.status().state, .inactive)
        XCTAssertEqual(engine.status().lastDisarmReason, .unsafePower)
    }

    func testStaleRenewFailsClosedAndRestores() throws {
        let session = try arm()
        let stale = PowerSample(
            source: .battery,
            percentage: 90,
            sampledAt: fixedDate.addingTimeInterval(-16)
        )

        XCTAssertThrowsError(
            try engine.renew(
                connectionID: connection,
                sessionID: session,
                sample: stale,
                floor: BatteryFloor(10)!
            )
        ) { XCTAssertEqual($0 as? HelperError, .unsafe(.staleSample)) }
        XCTAssertFalse(pmset.observed)
    }

    func testConnectionInvalidationAndLeaseDeadlineRestore() throws {
        _ = try arm()
        events.removeAll()
        try engine.connectionInvalidated(connectionID: connection)
        XCTAssertFalse(pmset.observed)
        XCTAssertEqual(engine.status().lastDisarmReason, .connectionInvalidated)

        let second = try arm()
        XCTAssertEqual(engine.nextLeaseDeadline(), 130)
        try engine.leaseExpired(now: 129.999)
        XCTAssertEqual(engine.status().sessionID, second)
        try engine.leaseExpired(now: 130)
        XCTAssertFalse(pmset.observed)
        XCTAssertEqual(engine.status().lastDisarmReason, .leaseExpired)
    }

    func testRenewExtendsLeaseAndRejectsWrongOwnershipIDs() throws {
        let session = try arm()

        XCTAssertThrowsError(
            try engine.renew(connectionID: UUID(), sessionID: session, sample: safeBattery, floor: BatteryFloor(10)!)
        ) { XCTAssertEqual($0 as? HelperError, .wrongConnection) }
        XCTAssertThrowsError(
            try engine.renew(connectionID: connection, sessionID: UUID(), sample: safeBattery, floor: BatteryFloor(10)!)
        ) { XCTAssertEqual($0 as? HelperError, .wrongSession) }

        monotonicClock.now = 111
        try engine.renew(connectionID: connection, sessionID: session, sample: safeBattery, floor: BatteryFloor(10)!)
        XCTAssertEqual(engine.nextLeaseDeadline(), 141)
    }

    func testExternalChangeToZeroEndsOwnershipWithoutFightingIt() throws {
        let session = try arm()
        pmset.observed = false
        events.removeAll()

        XCTAssertThrowsError(
            try engine.renew(connectionID: connection, sessionID: session, sample: safeBattery, floor: BatteryFloor(10)!)
        ) { XCTAssertEqual($0 as? HelperError, .externallyChanged) }

        XCTAssertEqual(events, [.read(false), .journal(.externallyChanged), .clearJournal])
        XCTAssertEqual(engine.status().state, .inactive)
        XCTAssertEqual(engine.status().lastDisarmReason, .externalChange)
        XCTAssertNil(journal.stored)
    }

    func testDuplicateDisarmIsIdempotentOnlyForCompletedOwnership() throws {
        let session = try arm()
        try engine.disarm(connectionID: connection, sessionID: session, reason: .user)
        events.removeAll()

        XCTAssertNoThrow(try engine.disarm(connectionID: connection, sessionID: session, reason: .user))
        XCTAssertEqual(events, [])
        XCTAssertThrowsError(try engine.disarm(connectionID: connection, sessionID: UUID(), reason: .user)) {
            XCTAssertEqual($0 as? HelperError, .noActiveSession)
        }
    }

    func testReadbackMismatchFaultsAndRetainsJournal() throws {
        let session = try arm()
        pmset.ignoreSets = true
        events.removeAll()

        XCTAssertThrowsError(try engine.disarm(connectionID: connection, sessionID: session, reason: .user)) {
            XCTAssertEqual($0 as? HelperError, .restoreFailed)
        }
        XCTAssertTrue(pmset.observed)
        XCTAssertNotNil(journal.stored)
        XCTAssertEqual(engine.status().state, .faulted)
    }

    private var safeBattery: PowerSample {
        PowerSample(source: .battery, percentage: 42, sampledAt: fixedDate)
    }

    private var atFloor: PowerSample {
        PowerSample(source: .battery, percentage: 10, sampledAt: fixedDate)
    }

    @discardableResult
    private func arm() throws -> UUID {
        pmset.observed = false
        return try engine.arm(connectionID: connection, sample: safeBattery, floor: BatteryFloor(10)!)
    }

    private func activeJournal(originalSleepDisabled: Bool) -> HelperJournal {
        HelperJournal(
            sessionID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            connectionID: connection,
            originalSleepDisabled: originalSleepDisabled,
            phase: .active,
            armedAt: fixedDate
        )
    }
}

private enum EngineEvent: Equatable {
    case read(Bool)
    case set(Bool)
    case journal(JournalPhase)
    case clearJournal
}

private final class FakePMSetController: PMSetControlling {
    var observed = false
    var setShouldFail = false
    var ignoreSets = false
    var remainingReadFailures = 0
    private let record: (EngineEvent) -> Void

    init(events: @escaping (EngineEvent) -> Void) {
        record = events
    }

    func readSleepDisabled() throws -> Bool {
        if remainingReadFailures > 0 {
            remainingReadFailures -= 1
            throw PMSetError.commandFailed(status: 1)
        }
        record(.read(observed))
        return observed
    }

    func setSleepDisabled(_ enabled: Bool) throws {
        record(.set(enabled))
        if setShouldFail {
            throw PMSetError.commandFailed(status: 1)
        }
        if !ignoreSets {
            observed = enabled
        }
    }
}

private final class FakeJournalStore: JournalStoring {
    var stored: HelperJournal?
    var loadShouldFail = false
    var corruptFileStillExists = true
    private let record: (EngineEvent) -> Void

    init(events: @escaping (EngineEvent) -> Void) {
        record = events
    }

    func load() throws -> HelperJournal? {
        if loadShouldFail {
            throw FakeJournalError.corrupt
        }
        return stored
    }

    func save(_ journal: HelperJournal) throws {
        record(.journal(journal.phase))
        stored = journal
    }

    func clear() throws {
        record(.clearJournal)
        stored = nil
    }
}

private enum FakeJournalError: Error {
    case corrupt
}

private final class FakeWallClock: WallClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class FakeMonotonicClock: MonotonicClock {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}
