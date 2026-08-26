import Darwin
import Foundation

public protocol UpdateDownloading: AnyObject {
  func download(_ request: URLRequest, maximumBytes: Int64) async throws -> URL
  func text(_ request: URLRequest, maximumBytes: Int) async throws -> String
}

public protocol DiskImageAttaching: AnyObject, Sendable {
  func attachReadOnly(image: URL, mountRoot: URL) throws -> MountedImageDescription
  func detach(device: String) throws
}

public protocol UpdateStaging: AnyObject {
  func mount(diskImage: URL, version: SemanticVersion) throws -> MountedUpdateSession
}

public enum UpdateURLPolicyError: Error, Equatable, Sendable {
  case invalidScheme
  case credentialsNotAllowed
  case invalidPort
  case invalidHost
  case localDestination
  case invalidRequest
}

public enum UpdateURLPolicy {
  public static func validate(_ request: URLRequest) throws {
    guard let url = request.url,
      request.httpMethod == nil || request.httpMethod == "GET",
      request.httpBody == nil,
      request.httpBodyStream == nil
    else {
      throw UpdateURLPolicyError.invalidRequest
    }

    let forbiddenHeaders = ["authorization", "cookie", "proxy-authorization"]
    let suppliedHeaders = Set(
      (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
    )
    guard suppliedHeaders.isDisjoint(with: forbiddenHeaders) else {
      throw UpdateURLPolicyError.credentialsNotAllowed
    }
    try validate(url)
  }

  public static func validate(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https" else {
      throw UpdateURLPolicyError.invalidScheme
    }
    guard url.user == nil, url.password == nil else {
      throw UpdateURLPolicyError.credentialsNotAllowed
    }
    guard url.port == nil || url.port == 443 else {
      throw UpdateURLPolicyError.invalidPort
    }
    guard let rawHost = url.host, !rawHost.isEmpty else {
      throw UpdateURLPolicyError.invalidHost
    }

    let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard host != "localhost",
      !host.hasSuffix("."),
      !host.hasSuffix(".localhost"),
      !host.hasSuffix(".local")
    else {
      throw UpdateURLPolicyError.localDestination
    }
    guard !isLocalIPv4(host), !isLocalIPv6(host) else {
      throw UpdateURLPolicyError.localDestination
    }
    if host.allSatisfy({ $0.isNumber || $0 == "." }), !isValidIPv4(host) {
      throw UpdateURLPolicyError.invalidHost
    }
  }

  private static func isValidIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4
      && parts.allSatisfy { part in
        !part.isEmpty && part.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
          && UInt8(part) != nil
      }
  }

  private static func isLocalIPv4(_ host: String) -> Bool {
    guard isValidIPv4(host) else {
      return false
    }
    let parts = host.split(separator: ".").compactMap { UInt8($0) }
    return parts[0] == 0
      || parts[0] == 10
      || parts[0] == 127
      || (parts[0] == 100 && (64...127).contains(parts[1]))
      || (parts[0] == 169 && parts[1] == 254)
      || (parts[0] == 172 && (16...31).contains(parts[1]))
      || (parts[0] == 192 && parts[1] == 168)
      || parts[0] >= 224
  }

  private static func isLocalIPv6(_ host: String) -> Bool {
    guard host.contains(":"), !host.contains("%") else {
      return host.contains(":")
    }
    var address = in6_addr()
    guard inet_pton(AF_INET6, host, &address) == 1 else {
      return true
    }
    let bytes = withUnsafeBytes(of: &address) { Array($0) }
    let isUnspecified = bytes.allSatisfy { $0 == 0 }
    let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
    let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
    let isMulticast = bytes[0] == 0xff
    let isMappedIPv4 =
      bytes.prefix(10).allSatisfy { $0 == 0 }
      && bytes[10] == 0xff && bytes[11] == 0xff
    let isMappedLocal =
      isMappedIPv4
      && (bytes[12] == 127 || (bytes[12] == 169 && bytes[13] == 254))
    return isUnspecified || isLoopback || isLinkLocal || isUniqueLocal || isMulticast
      || isMappedLocal
  }
}
