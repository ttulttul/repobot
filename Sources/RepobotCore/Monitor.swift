import Foundation
import OSLog

public actor EnvironmentMonitor {
  public let environment: Environment
  private let configuration: Configuration, store: StateStore
  private var transport: any Transport
  private var snapshot: EnvironmentSnapshot
  private var loop: Task<Void, Never>?, debounce: Task<Void, Never>?
  private var localWatcher: LocalWatcher?, remoteWatcher: RemoteWatcher?
  private var discovered = Date.distantPast, swept = Date.distantPast,
    upstreamChecked = Date.distantPast
  private var lastHeartbeat = Date(), retryAt = Date.distantPast, backoff: Double = 5
  private var busy = false, pending = false, stopped = true, forceDiscovery = false
  private var changed: Set<String> = []
  private var pendingFull = false, pendingUpstream = false
  private var pendingReason = "Queued check"
  private let logger = Logger(subsystem: "com.repobot.app", category: "Monitoring")
  private var sweepRetryAt = Date.distantPast
  private var capabilities: Capabilities?
  private var watcherGeneration = UUID()
  private var activeSweep: Task<Void, Never>?
  private var lastReconnectResolution = Date.distantPast
  private var safetySwept = Date.distantPast
  private var hasRestoredSnapshot = false
  public init(
    environment: Environment, configuration: Configuration, store: StateStore,
    transport: (any Transport)? = nil
  ) {
    self.environment = environment
    self.configuration = configuration
    self.store = store
    self.transport =
      transport ?? (environment.kind == .local
      ? LocalTransport() : SSHTransport(environment: environment, configuration: configuration))
    snapshot = EnvironmentSnapshot(environment: environment)
    capabilities = environment.capabilities
  }
  public func start() {
    guard loop == nil else { return }
    stopped = false
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.tick()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
  public func stop() async {
    stopped = true
    loop?.cancel()
    loop = nil
    debounce?.cancel()
    debounce = nil
    activeSweep?.cancel()
    activeSweep = nil
    stopWatchers()
    await transport.close()
    await store.flush()
  }
  public func checkNow(rescan: Bool = false, reason: String = "Manual check") async {
    forceDiscovery = forceDiscovery || rescan
    let task = Task { await self.sweep(full: true, forceUpstream: true, reason: reason) }
    activeSweep = task
    await task.value
    activeSweep = nil
  }
  public func wake() async {
    stopWatchers()
    retryAt = .distantPast
    await checkNow(rescan: true, reason: "System wake")
  }
  public func networkChanged() async {
    guard environment.kind == .ssh, !stopped else { return }
    stopWatchers()
    retryAt = .distantPast
    await checkNow(reason: "Network recovery or route change")
  }
  private func tick() async {
    guard !stopped else { return }
    let events = localWatcher != nil || remoteWatcher != nil
    if remoteWatcher != nil && Date().timeIntervalSince(lastHeartbeat) > 65 {
      await watcherFailed("Remote watcher heartbeat was not received for 65 seconds")
    }
    let interval =
      events
      ? configuration.safetyInterval
      : (environment.pollInterval ?? configuration.pollInterval)
        * PowerPolicy.currentMultiplier(enabled: configuration.batteryAware)
    if !busy && Date() >= sweepRetryAt && (Date().timeIntervalSince(swept) >= interval
      || Date().timeIntervalSince(upstreamChecked) >= configuration.upstreamInterval)
    {
      await sweep(full: true, reason: swept == .distantPast ? "Startup check" : "Scheduled check")
    }
    if !events && environment.watchMode != .poll && Date() >= retryAt { await startWatcher() }
  }
  private func sweep(full: Bool, forceUpstream: Bool = false, reason: String = "Filesystem change") async {
    guard !stopped else { return }
    guard !busy else {
      pending = true
      pendingFull = pendingFull || full
      pendingUpstream = pendingUpstream || forceUpstream
      pendingReason = reason
      return
    }
    busy = true
    defer {
      busy = false
      if pending {
        let full = pendingFull, upstream = pendingUpstream, reason = pendingReason
        pending = false; pendingFull = false; pendingUpstream = false
        activeSweep = Task { await self.sweep(full: full, forceUpstream: upstream, reason: reason) }
      }
    }
    do {
      if !hasRestoredSnapshot {
        if let cached = await store.snapshot(for: environment.id) {
          snapshot = cached
          snapshot.environment = environment
        }
        hasRestoredSnapshot = true
      }
      guard !stopped, !Task.isCancelled else { return }
      snapshot.lastCheckReason = reason
      snapshot.lastCheckStartedAt = Date()
      snapshot.lastCheckFinishedAt = nil
      logger.debug("Check started: \(self.environment.name, privacy: .public), \(reason, privacy: .public)")
      snapshot.checkProgress = "Connecting and discovering repositories…"
      await store.updateProgress(snapshot.checkProgress, for: environment.id)
      if environment.kind == .ssh, let nodeID = environment.tailscaleNodeID,
        Date().timeIntervalSince(lastReconnectResolution) > 300,
        snapshot.error != nil || capabilities == nil
      {
        lastReconnectResolution = Date()
        if let host = await HostDiscovery.resolveNode(nodeID) {
          var resolved = environment
          resolved.host = host.host
          await transport.close()
          transport = SSHTransport(environment: resolved, configuration: configuration)
        }
      }
      if capabilities == nil {
        capabilities = try await Probe.capabilities(using: transport)
        snapshot.environment.capabilities = capabilities
      }
      var paths = snapshot.repos.map(\.path)
      var rediscovered = false
      if forceDiscovery || Date().timeIntervalSince(discovered) > 600 {
        paths = try await Probe.discover(roots: environment.roots, using: transport)
        discovered = Date()
        forceDiscovery = false
        rediscovered = true
      }
      let checkUpstream =
        forceUpstream || Date().timeIntervalSince(upstreamChecked) >= configuration.upstreamInterval
      let method = checkUpstream ? environment.upstreamCheck ?? configuration.upstreamCheck : .off
      if !full && !rediscovered {
        paths = paths.filter { path in
          changed.contains(path) && !(snapshot.repos.first { $0.path == path }?.slow ?? false)
        }
      }
      changed.removeAll()
      let allPaths = paths
      let safetyDue = Date().timeIntervalSince(safetySwept) >= configuration.safetyInterval
      if !safetyDue && !forceUpstream {
        paths = paths.filter { path in !(snapshot.repos.first { $0.path == path }?.slow ?? false) }
      }
      let peerMap = await store.peerMap(for: environment.id)
      if full || rediscovered {
        let old = Dictionary(uniqueKeysWithValues: snapshot.repos.map { ($0.path, $0) })
        snapshot.repos = allPaths.map { path in
          if let previous = old[path] { return previous }
          var repo = RepoSnapshot(path: path)
          repo.awaitingFreshCheck = true
          return repo
        }
      }
      // Watch while probing so edits made during a large sweep queue a follow-up.
      if rediscovered { stopWatchers() }
      await startWatcher()
      // Publish host-local Git state before contacting any repository upstream.
      // A large inventory or an unreachable upstream must not hide reachable hosts.
      try await probeBatches(paths, peerMap: peerMap, upstream: .off, batchSize: 8)
      guard !stopped, !Task.isCancelled else { return }
      if full || rediscovered {
        if safetyDue { safetySwept = Date() }
      }
      snapshot.checkedAt = Date()
      snapshot.error = nil
      await startWatcher()
      snapshot.checkProgress = nil
      await store.merge(snapshot)
      if method != .off {
        let upstreamPaths = snapshot.repos.filter {
          paths.contains($0.path) && $0.error == nil && $0.upstream != nil
        }.map(\.path)
        try await probeBatches(upstreamPaths, peerMap: peerMap, upstream: method, batchSize: 4)
      }
      guard !stopped, !Task.isCancelled else { return }
      if full || rediscovered { swept = Date() }
      sweepRetryAt = .distantPast
      if checkUpstream { upstreamChecked = Date() }
      snapshot.lastCheckFinishedAt = Date()
      snapshot.checkProgress = nil
      await store.merge(snapshot)
      await store.flush()
    } catch {
      guard !stopped else { return }
      snapshot.checkProgress = nil
      snapshot.lastCheckFinishedAt = Date()
      snapshot.error = error.localizedDescription
      swept = Date()
      sweepRetryAt = Date().addingTimeInterval(60)
      await store.merge(snapshot)
      await store.flush()
    }
  }
  private func probeBatches(
    _ paths: [String], peerMap: [String: [String]], upstream: UpstreamCheck, batchSize: Int
  ) async throws {
    for start in stride(from: 0, to: paths.count, by: batchSize) {
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      snapshot.checkProgress = upstream == .off
        ? "Checking repositories: \(start) of \(paths.count)"
        : "Checking upstreams: \(start) of \(paths.count) · repository status available"
      await store.updateProgress(snapshot.checkProgress, for: environment.id)
      let end = min(start + batchSize, paths.count)
      let batch = Array(paths[start..<end])
      let repos: [RepoSnapshot]
      if upstream == .off {
        repos = try await Probe.repos(batch, peerMap: peerMap, using: transport)
      } else {
        let current = Dictionary(uniqueKeysWithValues: snapshot.repos.map { ($0.path, $0) })
        repos = try await Probe.checkUpstreams(batch.compactMap { current[$0] }, peerMap: peerMap,
                                              method: upstream, using: transport)
      }
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      let updates = Dictionary(uniqueKeysWithValues: repos.map { ($0.path, $0) })
      snapshot.repos = snapshot.repos.map { updates[$0.path] ?? $0 }
      snapshot.error = nil
      // Merge preserves freshness and activity history for unchanged repositories.
      await store.merge(snapshot)
      if let merged = await store.snapshot(for: environment.id) {
        // The store enriches repository ages/freshness. Watcher events may have updated
        // monitor metadata while we awaited it; do not overwrite those newer diagnostics.
        snapshot.repos = merged.repos
      }
    }
  }
  private func startWatcher() async {
    guard !stopped, environment.watchMode != .poll else {
      snapshot.mode = "Polling"
      return
    }
    guard localWatcher == nil, remoteWatcher == nil, Date() >= retryAt, let capabilities else {
      return
    }
    do {
      watcherGeneration = UUID()
      let generation = watcherGeneration
      let handler: @Sendable (WatchEvent) -> Void = { [weak self] event in
        Task { await self?.event(event, generation: generation) }
      }
      if environment.kind == .local {
        localWatcher = try LocalWatcher(
          roots: environment.roots + snapshot.repos.map(\.path)
            + snapshot.repos.flatMap(\.gitDirectories), handler: handler)
        snapshot.mode = "Events — FSEvents"
      } else if capabilities.python || capabilities.inotifywait || capabilities.fswatch {
        remoteWatcher = try RemoteWatcher(
          transport: transport, roots: environment.roots, repos: snapshot.repos.map(\.path),
          capabilities: capabilities, handler: handler)
        snapshot.mode =
          "Events — \(capabilities.python ? (capabilities.os == "Linux" ? "inotify via python3" : "FSEvents via python3") : capabilities.inotifywait ? "inotifywait" : "fswatch")"
        lastHeartbeat = Date()
      } else {
        snapshot.mode = "Polling — no event tools available"
        retryAt = Date().addingTimeInterval(300)
      }
    } catch { await watcherFailed(error.localizedDescription) }
  }
  private func event(_ event: WatchEvent, generation: UUID) async {
    guard !stopped, generation == watcherGeneration else { return }
    switch event {
    case .ready:
      lastHeartbeat = Date()
      backoff = 5
      snapshot.reconnecting = false
      if snapshot.watcherFailure != nil && snapshot.watcherFailure?.recoveredAt == nil {
        snapshot.watcherFailure?.recoveredAt = Date()
      }
      await store.merge(snapshot)
    case .ping: lastHeartbeat = Date()
    case .ended: await watcherFailed("Remote watcher ended unexpectedly")
    case .failed(let message): await watcherFailed(message)
    case .limited:
      snapshot.mode += snapshot.mode.contains("limited") ? "" : " (limited; safety sweep active)"
    case .rescan:
      forceDiscovery = true
      scheduleDebounce()
    case .changed(let path): await repositoryChanged(path)
    }
  }
  // Used by both filesystem watcher backends; retain affected paths while a sweep is busy.
  func repositoryChanged(_ path: String) async {
    guard !stopped else { return }
    if environment.kind == .local, await store.isCachePath(path) { return }
    let skipped: Set<String> = [
      "node_modules", ".venv", "vendor", "target", "build", "Library", ".Trash",
    ]
    if let repo = snapshot.repos.first(where: { path.hasPrefix($0.path + "/") }) {
      let relative = path.dropFirst(repo.path.count + 1)
      if relative.split(separator: "/").contains(where: { skipped.contains(String($0)) }) {
        return
      }
    } else if path.split(separator: "/").contains(where: { skipped.contains(String($0)) }) {
      return
    }
    let matches = snapshot.repos.filter {
      path == $0.path || path.hasPrefix($0.path + "/")
        || $0.gitDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    if matches.isEmpty { forceDiscovery = true } else { changed.formUnion(matches.map(\.path)) }
    scheduleDebounce()
  }

  private func scheduleDebounce() {
    debounce?.cancel()
    debounce = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
        await self?.sweep(full: false)
      } catch {}
    }
  }
  private func stopWatchers() {
    watcherGeneration = UUID()
    localWatcher?.stop()
    localWatcher = nil
    remoteWatcher?.stop()
    remoteWatcher = nil
  }
  func watcherFailed(_ message: String) async {
    snapshot.watcherFailure = WatcherFailure(message: message)
    logger.error("Watcher failed on \(self.environment.name, privacy: .public): \(message, privacy: .private)")
    stopWatchers()
    snapshot.reconnecting = true
    snapshot.mode = "Polling — events reconnecting"
    retryAt = Date().addingTimeInterval(backoff)
    backoff = min(300, backoff * 2)
    await store.merge(snapshot)
  }
}
