import Foundation
import XCTest
@testable import LidlessCore

final class PMSetParserTests: XCTestCase {
    func testParsesExactSleepDisabledValue() throws {
        XCTAssertFalse(try PMSetSnapshot.parse("System-wide power settings:\n SleepDisabled 0\n").sleepDisabled)
        XCTAssertTrue(try PMSetSnapshot.parse(" SleepDisabled\t1\n").sleepDisabled)
    }

    func testRejectsMissingMalformedDuplicateOrConflictingValues() {
        XCTAssertThrowsError(try PMSetSnapshot.parse("sleep 1"))
        XCTAssertThrowsError(try PMSetSnapshot.parse("SleepDisabled yes"))
        XCTAssertThrowsError(try PMSetSnapshot.parse("SleepDisabled 1 extra"))
        XCTAssertThrowsError(try PMSetSnapshot.parse("SleepDisabled 0\nSleepDisabled 0"))
        XCTAssertThrowsError(try PMSetSnapshot.parse("SleepDisabled 0\nSleepDisabled 1"))
    }

    func testReadUsesOnlyFixedPMSetGetCommand() throws {
        let runner = FakeCommandRunner(results: [
            .success(CommandResult(status: 0, stdout: "SleepDisabled 1", stderr: ""))
        ])
        let controller = FixedPMSetController(runner: runner)

        XCTAssertTrue(try controller.readSleepDisabled())
        XCTAssertEqual(runner.calls, [Command("/usr/bin/pmset", ["-g"])])
        XCTAssertEqual(runner.timeouts, [5])
    }

    func testSetRequiresReadBackMatch() throws {
        let runner = FakeCommandRunner(results: [
            .success(CommandResult(status: 0, stdout: "", stderr: "")),
            .success(CommandResult(status: 0, stdout: "SleepDisabled 0", stderr: ""))
        ])
        let controller = FixedPMSetController(runner: runner)

        XCTAssertThrowsError(try controller.setSleepDisabled(true)) { error in
            XCTAssertEqual(error as? PMSetError, .verificationMismatch(expected: true, actual: false))
        }
        XCTAssertEqual(runner.calls, [
            Command("/usr/bin/pmset", ["-a", "disablesleep", "1"]),
            Command("/usr/bin/pmset", ["-g"])
        ])
        XCTAssertEqual(runner.timeouts, [5, 5])
    }

    func testSetFalseUsesLiteralZeroAndVerifies() throws {
        let runner = FakeCommandRunner(results: [
            .success(CommandResult(status: 0, stdout: "", stderr: "")),
            .success(CommandResult(status: 0, stdout: "SleepDisabled 0", stderr: ""))
        ])
        let controller = FixedPMSetController(runner: runner)

        XCTAssertNoThrow(try controller.setSleepDisabled(false))
        XCTAssertEqual(runner.calls.first, Command("/usr/bin/pmset", ["-a", "disablesleep", "0"]))
    }

    func testNonzeroSetExitSkipsReadBack() throws {
        let runner = FakeCommandRunner(results: [
            .success(CommandResult(status: 77, stdout: "", stderr: "permission denied"))
        ])
        let controller = FixedPMSetController(runner: runner)

        XCTAssertThrowsError(try controller.setSleepDisabled(true)) { error in
            XCTAssertEqual(error as? PMSetError, .commandFailed(status: 77))
        }
        XCTAssertEqual(runner.calls, [Command("/usr/bin/pmset", ["-a", "disablesleep", "1"])])
    }

    func testNonzeroReadExitIsRejectedBeforeParsing() throws {
        let runner = FakeCommandRunner(results: [
            .success(CommandResult(status: 1, stdout: "SleepDisabled 1", stderr: "failed"))
        ])
        let controller = FixedPMSetController(runner: runner)

        XCTAssertThrowsError(try controller.readSleepDisabled()) { error in
            XCTAssertEqual(error as? PMSetError, .commandFailed(status: 1))
        }
    }
}

private final class FakeCommandRunner: CommandRunning {
    private var results: [Result<CommandResult, Error>]
    private(set) var calls: [Command] = []
    private(set) var timeouts: [TimeInterval] = []

    init(results: [Result<CommandResult, Error>]) {
        self.results = results
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(Command(executable, arguments))
        timeouts.append(timeout)
        guard !results.isEmpty else {
            throw FakeRunnerError.missingResult
        }
        return try results.removeFirst().get()
    }
}

private enum FakeRunnerError: Error {
    case missingResult
}
