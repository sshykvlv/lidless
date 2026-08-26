import CryptoKit
import Darwin
import Foundation
import LidlessCore

enum SHA256FileHasherError: Error, Equatable {
  case unsafeFile
  case oversized
}

final class SHA256FileHasher: UpdateFileHashing, @unchecked Sendable {
  private static let maximumBytes: Int64 = 32 * 1_024 * 1_024
  private static let chunkBytes = 64 * 1_024

  func sha256(of file: URL) throws -> String {
    let standardized = file.standardizedFileURL
    var metadata = stat()
    guard lstat(standardized.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0,
      metadata.st_size <= Self.maximumBytes,
      standardized.resolvingSymlinksInPath().path == standardized.path
    else {
      throw SHA256FileHasherError.unsafeFile
    }

    let handle = try FileHandle(forReadingFrom: standardized)
    defer { try? handle.close() }
    var hasher = SHA256()
    var received: Int64 = 0
    while let data = try handle.read(upToCount: Self.chunkBytes), !data.isEmpty {
      received += Int64(data.count)
      guard received <= Self.maximumBytes else {
        throw SHA256FileHasherError.oversized
      }
      hasher.update(data: data)
    }
    let hexadecimal = Array("0123456789abcdef".utf8)
    return String(
      decoding: hasher.finalize().flatMap { byte in
        [hexadecimal[Int(byte >> 4)], hexadecimal[Int(byte & 0x0f)]]
      },
      as: UTF8.self
    )
  }
}
