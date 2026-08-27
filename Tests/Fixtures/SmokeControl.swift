import Foundation

private let arguments = Array(CommandLine.arguments.dropFirst())
private let simpleCommands = ["arm", "disarm", "clear-battery", "quit", "invalid-version"]
private let userInfo: [String: Any]

if arguments.count == 1, simpleCommands.contains(arguments[0]) {
  userInfo = ["command": arguments[0]]
} else if arguments.count == 2, arguments[0] == "battery",
  let percentage = Int(arguments[1]), (0...100).contains(percentage)
{
  userInfo = ["command": "battery", "percentage": percentage]
} else {
  exit(EX_USAGE)
}

DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("lv.ykv.lidless.debug.smoke"),
  object: nil,
  userInfo: userInfo,
  deliverImmediately: true
)
