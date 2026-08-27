import Darwin
import Foundation
import LidlessCore

enum UpdateProcessError: Error, Equatable {
  case invalidTimeout
  case timedOut
  case streamTooLarge
  case invalidUTF8
}

final class UpdateProcessRunner: CommandRunning {
  private static let maximumStreamBytes = 64 * 1_024
  private static let readChunkBytes = 4 * 1_024
  private static let terminationGrace: TimeInterval = 2

  func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
    guard timeout > 0 else {
      throw UpdateProcessError.invalidTimeout
    }

    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    try process.run()

    let stdout = UpdateStreamCollector(
      handle: stdoutPipe.fileHandleForReading,
      limit: Self.maximumStreamBytes,
      chunkSize: Self.readChunkBytes
    )
    let stderr = UpdateStreamCollector(
      handle: stderrPipe.fileHandleForReading,
      limit: Self.maximumStreamBytes,
      chunkSize: Self.readChunkBytes
    )
    let readers = DispatchGroup()
    let readerQueue = DispatchQueue(
      label: "lv.ykv.lidless.update-process-output",
      attributes: .concurrent
    )
    readers.enter()
    readerQueue.async {
      stdout.drain()
      readers.leave()
    }
    readers.enter()
    readerQueue.async {
      stderr.drain()
      readers.leave()
    }

    if terminated.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if terminated.wait(timeout: .now() + Self.terminationGrace) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = terminated.wait(timeout: .now() + Self.terminationGrace)
      }
      _ = readers.wait(timeout: .now() + Self.terminationGrace)
      throw UpdateProcessError.timedOut
    }

    readers.wait()
    let stdoutData = try stdout.result()
    let stderrData = try stderr.result()
    guard let stdoutText = String(data: stdoutData, encoding: .utf8),
      let stderrText = String(data: stderrData, encoding: .utf8)
    else {
      throw UpdateProcessError.invalidUTF8
    }
    return CommandResult(
      status: process.terminationStatus,
      stdout: stdoutText,
      stderr: stderrText
    )
  }
}

private final class UpdateStreamCollector: @unchecked Sendable {
  private let handle: FileHandle
  private let limit: Int
  private let chunkSize: Int
  private var data = Data()
  private var failure: (any Error)?
  private var overflowed = false

  init(handle: FileHandle, limit: Int, chunkSize: Int) {
    self.handle = handle
    self.limit = limit
    self.chunkSize = chunkSize
  }

  func drain() {
    do {
      while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
        if data.count + chunk.count <= limit {
          data.append(chunk)
        } else {
          overflowed = true
        }
      }
    } catch {
      failure = error
    }
  }

  func result() throws -> Data {
    if let failure {
      throw failure
    }
    if overflowed {
      throw UpdateProcessError.streamTooLarge
    }
    return data
  }
}
