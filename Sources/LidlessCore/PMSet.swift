import Foundation

public struct Command: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: AnyObject {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

public enum PMSetSnapshotError: Error, Equatable, Sendable {
    case missingSleepDisabled
    case malformedSleepDisabled
    case duplicateSleepDisabled
}

public struct PMSetSnapshot: Equatable, Sendable {
    public let sleepDisabled: Bool

    public static func parse(_ output: String) throws -> PMSetSnapshot {
        var parsedValues: [Bool] = []

        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.first == "SleepDisabled" else {
                continue
            }
            guard fields.count == 2 else {
                throw PMSetSnapshotError.malformedSleepDisabled
            }
            switch fields[1] {
            case "0":
                parsedValues.append(false)
            case "1":
                parsedValues.append(true)
            default:
                throw PMSetSnapshotError.malformedSleepDisabled
            }
        }

        guard !parsedValues.isEmpty else {
            throw PMSetSnapshotError.missingSleepDisabled
        }
        guard parsedValues.count == 1 else {
            throw PMSetSnapshotError.duplicateSleepDisabled
        }
        return PMSetSnapshot(sleepDisabled: parsedValues[0])
    }
}

public protocol PMSetControlling: AnyObject {
    func readSleepDisabled() throws -> Bool
    func setSleepDisabled(_ enabled: Bool) throws
}

public enum PMSetError: Error, Equatable, Sendable {
    case commandFailed(status: Int32)
    case verificationMismatch(expected: Bool, actual: Bool)
}

public final class FixedPMSetController: PMSetControlling {
    private static let executable = "/usr/bin/pmset"
    private static let commandTimeout: TimeInterval = 5

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func readSleepDisabled() throws -> Bool {
        let result = try runner.run(
            executable: Self.executable,
            arguments: ["-g"],
            timeout: Self.commandTimeout
        )
        guard result.status == 0 else {
            throw PMSetError.commandFailed(status: result.status)
        }
        return try PMSetSnapshot.parse(result.stdout).sleepDisabled
    }

    public func setSleepDisabled(_ enabled: Bool) throws {
        let result = try runner.run(
            executable: Self.executable,
            arguments: ["-a", "disablesleep", enabled ? "1" : "0"],
            timeout: Self.commandTimeout
        )
        guard result.status == 0 else {
            throw PMSetError.commandFailed(status: result.status)
        }

        let actual = try readSleepDisabled()
        guard actual == enabled else {
            throw PMSetError.verificationMismatch(expected: enabled, actual: actual)
        }
    }
}
