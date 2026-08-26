import Foundation
import LidlessCore

enum UpdateDownloadError: Error, Equatable {
  case invalidLimit
  case invalidResponse
  case httpStatus(Int)
  case responseTooLarge
  case tooManyRedirects
  case invalidText
  case temporaryFileCreationFailed
}

final class BoundedDownloader: UpdateDownloading {
  static let maximumDiskImageBytes: Int64 = 32 * 1_024 * 1_024
  static let maximumTextBytes = 64 * 1_024

  func download(_ request: URLRequest, maximumBytes: Int64) async throws -> URL {
    guard maximumBytes > 0, maximumBytes <= Self.maximumDiskImageBytes else {
      throw UpdateDownloadError.invalidLimit
    }
    try UpdateURLPolicy.validate(request)

    let file = try Self.makeTemporaryFile()
    let transfer = try BoundedTransfer(
      request: request,
      maximumBytes: Int(maximumBytes),
      destination: .file(file)
    )
    do {
      _ = try await transfer.start()
      return file
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }

  func text(_ request: URLRequest, maximumBytes: Int) async throws -> String {
    guard maximumBytes > 0, maximumBytes <= Self.maximumTextBytes else {
      throw UpdateDownloadError.invalidLimit
    }
    try UpdateURLPolicy.validate(request)

    let transfer = try BoundedTransfer(
      request: request,
      maximumBytes: maximumBytes,
      destination: .memory
    )
    let data = try await transfer.start()
    guard let text = String(data: data, encoding: .utf8) else {
      throw UpdateDownloadError.invalidText
    }
    return text
  }

  private static func makeTemporaryFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("lv.ykv.lidless.download-\(UUID().uuidString)")
    guard
      FileManager.default.createFile(
        atPath: url.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw UpdateDownloadError.temporaryFileCreationFailed
    }
    return url
  }
}

private final class BoundedTransfer: NSObject, @unchecked Sendable {
  enum Destination {
    case memory
    case file(URL)
  }

  private let request: URLRequest
  private let maximumBytes: Int
  private let destination: Destination
  private var session: URLSession?
  private var continuation: CheckedContinuation<Data, any Error>?
  private var receivedBytes = 0
  private var redirects = 0
  private var memory = Data()
  private var fileHandle: FileHandle?
  private var completed = false

  init(request: URLRequest, maximumBytes: Int, destination: Destination) throws {
    self.request = request
    self.maximumBytes = maximumBytes
    self.destination = destination
    if case .file(let url) = destination {
      fileHandle = try FileHandle(forWritingTo: url)
    }
  }

  func start() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 30
      configuration.waitsForConnectivity = false
      configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      configuration.httpCookieAcceptPolicy = .never
      configuration.httpShouldSetCookies = false
      configuration.urlCredentialStorage = nil

      let delegateQueue = OperationQueue()
      delegateQueue.name = "lv.ykv.lidless.update-transfer"
      delegateQueue.maxConcurrentOperationCount = 1
      let session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: delegateQueue
      )
      self.session = session
      session.dataTask(with: request).resume()
    }
  }

  private func fail(_ error: any Error, task: URLSessionTask? = nil) {
    guard !completed else { return }
    completed = true
    task?.cancel()
    finishFile()
    continuation?.resume(throwing: error)
    continuation = nil
    session?.invalidateAndCancel()
    session = nil
  }

  private func succeed() {
    guard !completed else { return }
    completed = true
    do {
      try fileHandle?.synchronize()
      finishFile()
      continuation?.resume(returning: memory)
    } catch {
      finishFile()
      continuation?.resume(throwing: error)
    }
    continuation = nil
    session?.finishTasksAndInvalidate()
    session = nil
  }

  private func finishFile() {
    try? fileHandle?.close()
    fileHandle = nil
  }
}

extension BoundedTransfer: URLSessionDataDelegate, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      fail(UpdateDownloadError.invalidResponse, task: dataTask)
      return
    }
    guard (200...299).contains(response.statusCode) else {
      completionHandler(.cancel)
      fail(UpdateDownloadError.httpStatus(response.statusCode), task: dataTask)
      return
    }
    if response.expectedContentLength > Int64(maximumBytes) {
      completionHandler(.cancel)
      fail(UpdateDownloadError.responseTooLarge, task: dataTask)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !completed else { return }
    guard data.count <= maximumBytes - receivedBytes else {
      fail(UpdateDownloadError.responseTooLarge, task: dataTask)
      return
    }
    receivedBytes += data.count
    do {
      switch destination {
      case .memory:
        memory.append(data)
      case .file:
        try fileHandle?.write(contentsOf: data)
      }
    } catch {
      fail(error, task: dataTask)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard redirects < 5 else {
      completionHandler(nil)
      fail(UpdateDownloadError.tooManyRedirects, task: task)
      return
    }
    do {
      try UpdateURLPolicy.validate(request)
      redirects += 1
      completionHandler(request)
    } catch {
      completionHandler(nil)
      fail(error, task: task)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      fail(error)
    } else {
      succeed()
    }
  }
}
