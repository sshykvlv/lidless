import Foundation

@objc private protocol ProbeProtocol {
  func status(reply: @escaping (NSObject) -> Void)
}

private let connection = NSXPCConnection(
  machServiceName: "lv.ykv.lidless.helper",
  options: .privileged
)
connection.remoteObjectInterface = NSXPCInterface(with: ProbeProtocol.self)

let semaphore = DispatchSemaphore(value: 0)
var receivedReply = false
connection.invalidationHandler = {
  semaphore.signal()
}
connection.activate()

private let proxy =
  connection.remoteObjectProxyWithErrorHandler { _ in
    semaphore.signal()
  } as? ProbeProtocol
proxy?.status { _ in
  receivedReply = true
  semaphore.signal()
}

let invalidated = semaphore.wait(timeout: .now() + 5) == .success
connection.invalidate()
exit(invalidated && !receivedReply ? EXIT_SUCCESS : EXIT_FAILURE)
