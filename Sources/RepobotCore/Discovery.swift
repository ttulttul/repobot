import Darwin
import Foundation
import Network
import SystemConfiguration

public struct DiscoveredHost: Identifiable, Sendable {
  public var id: String { nodeID ?? host }
  public var name: String, host: String, address: String, source: String, os: String
  public var nodeID: String? = nil
  public var online: Bool? = nil
  public var tailscaleSSH = false
  public var port = 22
  public var banner: String = ""
}
private struct TailscaleStatus: Decodable {
  struct Node: Decodable {
    var ID: String?
    var HostName: String
    var DNSName: String?
    var TailscaleIPs: [String]?
    var OS: String?
    var Online: Bool?
    var SSH_HostKeys: [String]?
  }
  var BackendState: String?
  var Peer: [String: Node]?
}
public enum HostDiscovery {
  public static let tailscalePaths = [
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
  ]
  public static func tailscale() async -> [DiscoveredHost] {
    (try? await loadTailscale()) ?? []
  }
  public static func loadTailscale(executable: String? = nil) async throws -> [DiscoveredHost] {
    guard let path = executable ?? tailscalePaths.first(where: {
      FileManager.default.isExecutableFile(atPath: $0)
    }) else {
      throw RepobotError.message("Tailscale is not installed. Enter a host manually or scan the local network.")
    }
    // Finder-launched apps do not have a terminal environment. Explicitly select CLI mode.
    let result = try await ProcessRunner.run(
      "/usr/bin/env", ["TAILSCALE_BE_CLI=1", path, "status", "--json"], timeout: 10)
    guard result.status == 0 else {
      throw RepobotError.message("Could not read Tailscale devices. Check that Tailscale is running and signed in, then refresh.")
    }
    return try parseTailscale(result.stdout)
  }
  static func parseTailscale(_ data: Data) throws -> [DiscoveredHost] {
    let status = try JSONDecoder().decode(TailscaleStatus.self, from: data)
    if let state = status.BackendState, state != "Running" {
      throw RepobotError.message("Tailscale is \(state). Connect in Tailscale, then refresh.")
    }
    return (status.Peer ?? [:]).compactMap { key, node in
      guard let ip = node.TailscaleIPs?.first else { return nil }
      let dns = (node.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
      return DiscoveredHost(
        name: node.HostName, host: dns.isEmpty ? ip : dns, address: ip, source: "Tailscale",
        os: node.OS ?? "", nodeID: node.ID ?? key, online: node.Online,
        tailscaleSSH: !(node.SSH_HostKeys ?? []).isEmpty)
    }.sorted {
      if ($0.online == true) != ($1.online == true) { return $0.online == true }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  public static func resolveNode(_ id: String) async -> DiscoveredHost? {
    await tailscale().first { $0.nodeID == id }
  }
  public static func scan(_ candidates: [DiscoveredHost]) async -> [DiscoveredHost] {
    await withTaskGroup(of: DiscoveredHost?.self, returning: [DiscoveredHost].self) { group in
      var iterator = candidates.makeIterator()
      var result: [DiscoveredHost] = []
      func add(_ candidate: DiscoveredHost) {
        group.addTask {
          guard !Task.isCancelled,
            let banner = await SSHBanner.read(host: candidate.address, port: candidate.port)
          else { return nil }
          var host = candidate
          host.banner = banner
          if host.source == "LAN",
            let result = try? await ProcessRunner.run(
              "/usr/bin/dscacheutil", ["-q", "host", "-a", "ip_address", host.address], timeout: 2),
            let line = result.text.split(separator: "\n").first(where: { $0.hasPrefix("name: ") })
          {
            host.name = String(line.dropFirst(6))
          }
          return host
        }
      }
      for _ in 0..<min(64, candidates.count) { if let next = iterator.next() { add(next) } }
      while let candidate = await group.next() {
        if let candidate { result.append(candidate) }
        if !Task.isCancelled, let next = iterator.next() { add(next) }
      }
      return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
  }
  public static func lanCandidates() -> [DiscoveredHost] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
    defer { freeifaddrs(interfaces) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    var networks: [(String, UInt32, UInt32)] = []
    while let item = cursor {
      defer { cursor = item.pointee.ifa_next }
      let name = String(cString: item.pointee.ifa_name)
      guard name.hasPrefix("en"), item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
        let addr = item.pointee.ifa_addr,
        addr.pointee.sa_family == AF_INET,
        let mask = item.pointee.ifa_netmask
      else { continue }
      let ip = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        .s_addr.bigEndian
      let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee
        .sin_addr.s_addr.bigEndian
      networks.append((name, ip, netmask))
    }
    let store = SCDynamicStoreCreate(nil, "Repobot" as CFString, nil, nil)
    let state =
      SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    let primary = state?["PrimaryInterface"] as? String
    guard
      let (_, ip, mask) = networks.first(where: { $0.0 == primary })
        ?? networks.sorted(by: { $0.0 < $1.0 }).first
    else { return [] }
    let boundedMask = max(mask, 0xffff_fc00)
    let network = ip & boundedMask
    let broadcast = network | ~boundedMask
    guard broadcast > network + 1 else { return [] }
    return ((network + 1)..<broadcast).filter { $0 != ip }.map { value in
      let address = "\((value>>24)&255).\((value>>16)&255).\((value>>8)&255).\(value&255)"
      return DiscoveredHost(name: address, host: address, address: address, source: "LAN", os: "")
    }
  }
  // Listing known devices never opens connections to peers or scans the LAN.
  public static func discover() async -> [DiscoveredHost] {
    await tailscale()
  }
  public static func discoverLAN() async -> [DiscoveredHost] {
    await scan(lanCandidates())
  }
  public static var tailscaleNeedsCLI: Bool {
    guard !tailscalePaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return false }
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return false }
    defer { freeifaddrs(interfaces) }
    var cursor = interfaces
    while let item = cursor {
      defer { cursor = item.pointee.ifa_next }
      guard String(cString: item.pointee.ifa_name).hasPrefix("utun"),
        let addr = item.pointee.ifa_addr, addr.pointee.sa_family == AF_INET
      else { continue }
      let ip = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        .s_addr.bigEndian
      if ip & 0xffc0_0000 == 0x6440_0000 { return true }
    }
    return false
  }
  public static func parseManual(_ text: String) throws -> Environment {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }), !text.hasPrefix("-"),
      let parts = URLComponents(string: "ssh://" + text), let host = parts.host, !host.isEmpty,
      parts.password == nil, parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
      parts.port.map({ (1...65535).contains($0) }) ?? true
    else { throw RepobotError.message("Enter user@host, host:port, or user@[IPv6]:port") }
    var env = Environment(name: host, kind: .ssh)
    env.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    env.user = parts.user ?? NSUserName()
    env.port = parts.port
    return env
  }
  public static func configuredUser(for host: String, sshPath: String = "/usr/bin/ssh") async
    -> String
  {
    guard let result = try? await ProcessRunner.run(sshPath, ["-G", "--", host], timeout: 5),
      result.status == 0
    else { return NSUserName() }
    return result.text.split(separator: "\n").first { $0.hasPrefix("user ") }.map {
      String($0.dropFirst(5))
    } ?? NSUserName()
  }
}
private final class SSHBanner: @unchecked Sendable {
  let lock = NSLock(), connection: NWConnection
  var continuation: CheckedContinuation<String?, Never>?
  var data = Data()
  var finished = false
  init(host: String, port: Int) {
    connection = NWConnection(
      host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .ssh,
      using: .tcp)
  }
  static func read(host: String, port: Int) async -> String? {
    let probe = SSHBanner(host: host, port: port)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { probe.start($0) }
    } onCancel: {
      probe.finish(nil)
    }
  }
  func start(_ continuation: CheckedContinuation<String?, Never>) {
    lock.lock()
    if finished {
      lock.unlock()
      continuation.resume(returning: nil)
      return
    }
    self.continuation = continuation
    lock.unlock()
    connection.stateUpdateHandler = { [self] state in
      switch state {
      case .ready: receive()
      case .failed, .cancelled: finish(nil)
      default: break
      }
    }
    connection.start(queue: DispatchQueue(label: "Repobot.SSHBanner"))
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [self] in finish(nil) }
  }
  func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
      [self] content, _, complete, error in
      if let content { data.append(content) }
      if let line = String(data: data, encoding: .utf8)?.components(separatedBy: "\n").dropLast()
        .first(where: {
          $0.hasPrefix("SSH-")
        })
      {
        finish(String(line).trimmingCharacters(in: .whitespacesAndNewlines))
      } else if complete || error != nil || data.count > 4096 {
        finish(nil)
      } else {
        receive()
      }
    }
  }
  func finish(_ value: String?) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume(returning: value)
    connection.cancel()
  }
}
@MainActor
public final class BonjourDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate,
  @preconcurrency NetServiceDelegate
{
  private var browsers: [NetServiceBrowser] = [], services: [NetService] = []
  private var found: [DiscoveredHost] = []
  public override init() { super.init() }
  public func discover(seconds: Double = 3) async -> [DiscoveredHost] {
    for type in ["_ssh._tcp.", "_sftp-ssh._tcp."] {
      let browser = NetServiceBrowser()
      browser.delegate = self
      browsers.append(browser)
      browser.searchForServices(ofType: type, inDomain: "local.")
    }
    try? await Task.sleep(for: .seconds(seconds))
    for browser in browsers { browser.stop() }
    for service in services { service.stop() }
    browsers = []
    services = []
    return found
  }
  public func netServiceBrowser(
    _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
  ) {
    services.append(service)
    service.delegate = self
    service.resolve(withTimeout: 2)
  }
  public func netServiceDidResolveAddress(_ sender: NetService) {
    guard let host = sender.hostName else { return }
    if !found.contains(where: { $0.host == host }) {
      found.append(
        DiscoveredHost(
          name: sender.name, host: host, address: host, source: "LAN · Bonjour", os: "",
          port: sender.port))
    }
  }
}
