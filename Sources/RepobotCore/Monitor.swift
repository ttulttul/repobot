import Foundation
import OSLog

public actor EnvironmentMonitor {
  public let environment: Environment
  private let configuration: Configuration, store: StateStore
  private var transport: any Transport
  private var repoPositions: [String: Int] = [:]
  private var repositoryWatchPaths = RepositoryWatchPaths()
  private func indexRepositories(refreshWatchPaths: Bool = false) {
    repoPositions = Dictionary(uniqueKeysWithValues: snapshot.repos.enumerated().map { ($0.element.path, $0.offset) })
    repositoryWatchPaths.reconcile(snapshot.repos, local: environment.kind == .local, refresh: refreshWatchPaths)
  }
  private var snapshot: EnvironmentSnapshot
  private var loop: Task<Void, Never>?, debounce: Task<Void, Never>?
  private var localWatcher: LocalWatcher?, remoteWatcher: RemoteWatcher?
  private var discovered = Date.distantPast, swept = Date.distantPast,
    upstreamChecked = Date.distantPast
  private var lastHeartbeat = Date(), retryAt = Date.distantPast, backoff: Double = 5
  private var oneShot = false
  private var busy = false, pending = false, stopped = true, forceDiscovery = false
  private var sweepQueued = false
  private(set) var timerFirings = 0
  private(set) var scheduledDeadline: Date?
  private var changed: Set<String> = []
  private var pendingFull = false, pendingUpstream = false
  private var pendingReason = "Queued check"
  private let logger = Logger(subsystem: "com.repobot.app", category: "Monitoring")
  private var sweepRetryAt = Date.distantPast
  private var capabilities: Capabilities?
  private var watcherGeneration = UUID()
  private var watcherGroup: Int32?, watcherCPU: WatcherCPUReading?
  private var watcherCoverage: WatcherCoverage?
  private var resetWatcherCoverage = false
  private(set) var watcherStarts = 0
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
    guard stopped else { return }
    stopped = false
    scheduleTick()
  }
  private func pollingInterval() -> Double {
    if localWatcher != nil || remoteWatcher != nil { return configuration.safetyInterval }
    return (environment.pollInterval ?? configuration.pollInterval)
      * PowerPolicy.currentMultiplier(enabled: configuration.batteryAware)
  }
  private func scheduleTick() {
    loop?.cancel(); loop = nil; scheduledDeadline = nil
    guard !stopped, !oneShot else { return }
    let now = Date()
    let events = localWatcher != nil || remoteWatcher != nil
    let date = MonitorDeadline.next(now: now, busy: busy || sweepQueued, events: events,
      remote: remoteWatcher != nil, canRetryWatcher: capabilities != nil && environment.watchMode != .poll,
      swept: swept, upstream: upstreamChecked, retrySweep: sweepRetryAt, retryWatcher: retryAt,
      heartbeat: lastHeartbeat, interval: pollingInterval(), upstreamInterval: configuration.upstreamInterval,
      batteryAware: configuration.batteryAware)
    guard let date else { return }
    scheduledDeadline = date
    loop = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(max(0.001, date.timeIntervalSinceNow)))
        guard !Task.isCancelled else { return }
        await self?.timerFired()
      } catch {}
    }
  }
  private func timerFired() async {
    guard !stopped else { return }
    loop = nil; scheduledDeadline = nil; timerFirings += 1
    await tick()
    scheduleTick()
  }
  public func stop() async {
    stopped = true
    loop?.cancel()
    loop = nil; scheduledDeadline = nil
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
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    activeSweep = nil
  }
  /// A manual check while continuous monitoring is paused. No timers or watchers are started.
  public func checkOnce(rescan: Bool = false) async {
    guard stopped, !Task.isCancelled else { return }
    oneShot = true
    stopped = false
    forceDiscovery = rescan
    await sweep(full: true, forceUpstream: true, reason: "One-time check while paused")
    await stop()
    oneShot = false
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
    if remoteWatcher != nil && Date().timeIntervalSince(lastHeartbeat) >= 65 {
      await watcherFailed("Remote watcher heartbeat was not received for 65 seconds")
    }
    if localWatcher == nil && remoteWatcher == nil && environment.watchMode != .poll && Date() >= retryAt {
      await startWatcher()
    }
    guard !stopped else { return }
    if !busy && !sweepQueued && Date() >= sweepRetryAt && (Date().timeIntervalSince(swept) >= pollingInterval()
      || Date().timeIntervalSince(upstreamChecked) >= configuration.upstreamInterval) {
      sweepQueued = true
      activeSweep = Task {
        self.sweepQueued = false
        await self.sweep(full: true, reason: self.swept == .distantPast ? "Startup check" : "Scheduled check")
      }
    }
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
    scheduleTick()
    defer {
      busy = false
      if pending {
        let full = pendingFull, upstream = pendingUpstream, reason = pendingReason
        pending = false; pendingFull = false; pendingUpstream = false
        activeSweep = Task { await self.sweep(full: full, forceUpstream: upstream, reason: reason) }
      }
      scheduleTick()
    }
    do {
      if !hasRestoredSnapshot {
        if let cached = await store.snapshot(for: environment.id) {
          snapshot = cached
          snapshot.environment = environment
        }
        indexRepositories()
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
      var paths = full ? snapshot.repos.map(\.path)
        : changed.filter { repoPositions[$0] != nil }.sorted {
          repoPositions[$0, default: 0] < repoPositions[$1, default: 0]
        }
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
          changed.contains(path) && !(repoPositions[path].map { snapshot.repos[$0].slow } ?? false)
        }
      }
      changed.removeAll()
      let allPaths = paths
      let safetyDue = Date().timeIntervalSince(safetySwept) >= configuration.safetyInterval
      if !safetyDue && !forceUpstream {
        paths = paths.filter { path in !(repoPositions[path].map { snapshot.repos[$0].slow } ?? false) }
      }
      let peerMap = await store.peerMap(for: environment.id, paths: Set(paths))
      if full || rediscovered {
        let old = Dictionary(uniqueKeysWithValues: snapshot.repos.map { ($0.path, $0) })
        snapshot.repos = SnapshotList(allPaths.map { path in
          if let previous = old[path] { return previous }
          var repo = RepoSnapshot(path: path)
          repo.awaitingFreshCheck = true
          return repo
        })
        indexRepositories(refreshWatchPaths: rediscovered)
        // Successful discovery is authoritative even if the previous connection failed.
        // Clear that error before merging, so an empty discovery can remove stale copies.
        snapshot.error = nil
        await store.merge(snapshot)
      }
      // Watch while probing so edits made during a large sweep queue a follow-up.
      await startWatcher()
      // Publish host-local Git state before contacting any repository upstream.
      // A large inventory or an unreachable upstream must not hide reachable hosts.
      try await probeBatches(paths, peerMap: peerMap, upstream: .off, batchSize: 8,
                             reuseFacts: !rediscovered && !forceUpstream)
      guard !stopped, !Task.isCancelled else { return }
      if full || rediscovered {
        if safetyDue { safetySwept = Date() }
      }
      snapshot.checkedAt = Date()
      snapshot.error = nil
      await startWatcher()
      snapshot.checkProgress = nil
      await store.merge(snapshot, changedPaths: [])
      if method != .off {
        let upstreamPaths = paths.filter { path in
          guard let index = repoPositions[path] else { return false }
          return snapshot.repos[index].error == nil && snapshot.repos[index].upstream != nil
        }
        try await probeBatches(upstreamPaths, peerMap: peerMap, upstream: method, batchSize: 4)
      }
      guard !stopped, !Task.isCancelled else { return }
      if full || rediscovered { swept = Date() }
      sweepRetryAt = .distantPast
      if checkUpstream { upstreamChecked = Date() }
      snapshot.lastCheckFinishedAt = Date()
      snapshot.checkProgress = nil
      await store.merge(snapshot, changedPaths: [])
      await store.flush()
    } catch {
      guard !stopped else { return }
      snapshot.checkProgress = nil
      snapshot.lastCheckFinishedAt = Date()
      snapshot.error = error.localizedDescription
      swept = Date()
      sweepRetryAt = Date().addingTimeInterval(60)
      await store.merge(snapshot, changedPaths: [])
      await store.flush()
    }
  }
  private func probeBatches(
    _ paths: [String], peerMap: [String: [String]], upstream: UpstreamCheck, batchSize: Int, reuseFacts: Bool = false
  ) async throws {
    let batches = upstream == .off
      ? stride(from: 0, to: paths.count, by: batchSize).map { Array(paths[$0..<min($0 + batchSize, paths.count)]) }
      : Probe.upstreamBatches(paths.compactMap { repoPositions[$0].map { snapshot.repos[$0] } }, size: batchSize)
    guard upstream != .off else {
      var start = 0
      for batch in batches {
        defer { start += batch.count }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        snapshot.checkProgress = "Checking repositories: \(start) of \(paths.count)"
        await store.updateProgress(snapshot.checkProgress, for: environment.id)
        let previous: [String: RepoSnapshot] = reuseFacts ? Dictionary(uniqueKeysWithValues: batch.compactMap { path in
          repoPositions[path].map { (path, snapshot.repos[$0]) }
        }) : [:]
        try await merge(Probe.repos(batch, peerMap: peerMap, previous: previous, using: transport), batch: batch)
      }
      return
    }
    // Network-bound: keep several batches in flight and merge each as it completes. A batch
    // holds every copy of one upstream, so its private query cache needs no coordination.
    let width = Probe.upstreamConcurrency(
      cpus: environment.kind == .local ? ProcessInfo.processInfo.activeProcessorCount : capabilities?.cpus,
      remote: environment.kind == .ssh)
    let transport = transport
    var pending = batches.makeIterator(), done = 0
    try await withThrowingTaskGroup(of: ([String], [RepoSnapshot]).self) { group in
      // Capture status at launch, not up front: events may refresh it meanwhile.
      for _ in 0..<width {
        guard let batch = pending.next() else { break }
        let repos = upstreamInputs(batch)
        group.addTask { (batch, try await Probe.checkUpstreams(repos, peerMap: peerMap, method: upstream, using: transport)) }
      }
      snapshot.checkProgress = "Checking upstreams: 0 of \(paths.count) · repository status available"
      await store.updateProgress(snapshot.checkProgress, for: environment.id)
      while let (batch, repos) = try await group.next() {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try await merge(repos, batch: batch)
        done += batch.count
        snapshot.checkProgress = "Checking upstreams: \(done) of \(paths.count) · repository status available"
        await store.updateProgress(snapshot.checkProgress, for: environment.id)
        if let batch = pending.next() {
          let repos = upstreamInputs(batch)
          group.addTask { (batch, try await Probe.checkUpstreams(repos, peerMap: peerMap, method: upstream, using: transport)) }
        }
      }
    }
  }
  private func upstreamInputs(_ batch: [String]) -> [RepoSnapshot] {
    batch.compactMap { path in repoPositions[path].map { snapshot.repos[$0] } }
  }
  private func merge(_ repos: [RepoSnapshot], batch: [String]) async throws {
    do {  // Scope retained from the batch loop body.
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      for repo in repos {
        if let index = repoPositions[repo.path] { snapshot.repos[index] = repo }
      }
      snapshot.error = nil
      // Carry the exact probe batch through analysis and durable persistence.
      await store.merge(snapshot, changedPaths: Set(repos.map(\.path)))
      if let merged = await store.snapshot(for: environment.id) {
        // The store enriches repository ages/freshness. Watcher events may have updated
        // monitor metadata while we awaited it; do not overwrite those newer diagnostics.
        snapshot.repos = merged.repos
      }
      for path in batch {
        guard let index = repoPositions[path] else { continue }
        let repo = snapshot.repos[index]
        repositoryWatchPaths.update(repo, local: environment.kind == .local)
      }
      if let watcher = localWatcher, batch.contains(where: { path in
        (repositoryWatchPaths[path] ?? []).contains { candidate in
          !watcher.watchedRoots.contains { $0 == "/" || candidate == $0 || candidate.hasPrefix($0 + "/") }
        }
      }) {
        // A probe may discover an external worktree/common Git directory after
        // registration. Add its coverage immediately, not at the next discovery.
        stopWatchers()
        await startWatcher()
      }
    }
  }
  private func startWatcher() async {
    if oneShot { snapshot.mode = "Manual check · monitoring paused"; return }
    defer { scheduleTick() }
    guard !stopped, environment.watchMode != .poll else {
      snapshot.mode = "Polling"
      return
    }
    guard let capabilities else { return }
    let coverage = WatcherCoverage(roots: environment.roots, repos: snapshot.repos)
    if localWatcher != nil || remoteWatcher != nil {
      guard resetWatcherCoverage || watcherCoverage != coverage else { return }
      stopWatchers()
    } else if Date() < retryAt { return }
    resetWatcherCoverage = false
    snapshot.watcherCoverageWarning = nil
    snapshot.watchUsage = nil
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
          capabilities: capabilities, gitDirectories: coverage.gitDirectories,
          clientID: RemoteWatcher.clientID(environment: environment.id),
          skipNames: configuration.effectiveWatchSkipNames,
          activeDays: configuration.effectiveWatchActiveDays, handler: handler)
        snapshot.mode =
          "Events — \(capabilities.python ? (capabilities.os == "Linux" ? "inotify via python3" : "FSEvents via python3") : capabilities.inotifywait ? "inotifywait" : "fswatch")"
        lastHeartbeat = Date()
      } else {
        snapshot.mode = "Polling — no event tools available"
        retryAt = Date().addingTimeInterval(300)
      }
      if localWatcher != nil || remoteWatcher != nil { watcherCoverage = coverage; watcherStarts += 1 }
    } catch { await watcherFailed(error.localizedDescription) }
  }
  private func event(_ event: WatchEvent, generation: UUID) async {
    guard !stopped, generation == watcherGeneration else { return }
    defer { scheduleTick() }
    switch event {
    case .ready:
      lastHeartbeat = Date()
      backoff = 5
      snapshot.reconnecting = false
      if snapshot.watcherFailure != nil && snapshot.watcherFailure?.recoveredAt == nil {
        snapshot.watcherFailure?.recoveredAt = Date()
      }
      await store.merge(snapshot, changedPaths: [])
    case .ping: lastHeartbeat = Date()
    case .group(let group): watcherGroup = group
    case .usage(let usage):
      snapshot.watchUsage = usage
      await store.merge(snapshot, changedPaths: [])
    case .ended: await watcherFailed("Remote watcher ended unexpectedly")
    case .failed(let message): await watcherFailed(message)
    case .limited(let message):
      snapshot.mode += snapshot.mode.contains("limited") ? "" : " (limited; safety sweep active)"
      snapshot.watcherCoverageWarning = message
      await store.merge(snapshot, changedPaths: [])
    case .reset:
      resetWatcherCoverage = true
      await self.event(.rescan, generation: generation)
    case .rescan:
      repositoryWatchPaths.invalidateAll()
      forceDiscovery = true
      scheduleDebounce()
    case .changed(let path): await repositoryChanged(path)
    case .changedPaths(let paths):
      for path in paths { await repositoryChanged(path, debounce: false) }
      if !changed.isEmpty || forceDiscovery { scheduleDebounce() }
    }
  }
  // Used by both filesystem watcher backends; retain affected paths while a sweep is busy.
  func repositoryChanged(_ path: String, debounce: Bool = true) async {
    guard !stopped else { return }
    if environment.kind == .local, await store.isCachePath(path) { return }
    if environment.kind == .local { repositoryWatchPaths.invalidate(affectedPath: path) }
    let path = environment.kind == .local ? LocalWatcher.physicalPath(path) : path
    let matches = repositoryWatchPaths.repositories(containing: path)
    if matches.isEmpty {
      if repositoryWatchPaths.ignores(path) { return }
      forceDiscovery = true
    } else {
      let relevant = matches.filter { !repositoryWatchPaths.ignores(path, repository: $0) }
      guard !relevant.isEmpty else { return }
      changed.formUnion(relevant)
    }
    if debounce { scheduleDebounce() }
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
  /// Sampled on demand while the environment settings are visible. Linux only: nil for
  /// FSEvents watchers, which have no per-directory cost, and when no watcher is running.
  public func watcherCost() async -> WatcherCost? {
    guard remoteWatcher != nil, capabilities?.os == "Linux", let group = watcherGroup else { return nil }
    let generation = watcherGeneration
    guard let (cost, reading) = try? await WatcherCostSampler.remote(
      group: group, transport: transport, previous: watcherCPU), generation == watcherGeneration
    else { return nil }
    watcherCPU = reading
    return cost
  }
  private func stopWatchers() {
    watcherGeneration = UUID()
    watcherGroup = nil
    watcherCPU = nil
    watcherCoverage = nil
    localWatcher?.stop()
    localWatcher = nil
    remoteWatcher?.stop()
    remoteWatcher = nil
  }
  func watcherFailed(_ message: String) async {
    defer { scheduleTick() }
    snapshot.watcherFailure = WatcherFailure(message: message)
    logger.error("Watcher failed on \(self.environment.name, privacy: .public): \(message, privacy: .private)")
    stopWatchers()
    snapshot.reconnecting = true
    snapshot.mode = "Polling — events reconnecting"
    retryAt = Date().addingTimeInterval(backoff)
    backoff = min(300, backoff * 2)
    await store.merge(snapshot, changedPaths: [])
  }
}

/// Pure deadline calculation makes retry/heartbeat/power behavior testable without waiting minutes.
enum MonitorDeadline {
  static func next(now: Date, busy: Bool, events: Bool, remote: Bool, canRetryWatcher: Bool,
                   swept: Date, upstream: Date, retrySweep: Date, retryWatcher: Date,
                   heartbeat: Date, interval: Double, upstreamInterval: Double, batteryAware: Bool) -> Date? {
    var dates: [Date] = []
    if !busy {
      dates.append(max(retrySweep, min(swept.addingTimeInterval(interval), upstream.addingTimeInterval(upstreamInterval))))
      // Battery/idle policy is relevant only to polling. Re-evaluate at most once a
      // minute so waking activity can shorten an extended polling interval.
      if !events && batteryAware { dates.append(now.addingTimeInterval(60)) }
    }
    if !events && canRetryWatcher { dates.append(retryWatcher) }
    if remote { dates.append(heartbeat.addingTimeInterval(65)) }
    return dates.min().map { max(now, $0) }
  }
}

/// Order-independent coverage identity; timestamps and content changes do not restart watchers.
struct WatcherCoverage: Equatable {
  let roots: Set<String>
  let repositories: Set<String>
  let gitDirectories: [String: [String]]
  init(roots: [String], repos: SnapshotList<RepoSnapshot>) {
    self.roots = Set(roots)
    repositories = Set(repos.map(\.path))
    gitDirectories = Dictionary(uniqueKeysWithValues: repos.filter { !$0.gitDirectories.isEmpty }
      .map { ($0.path, Set($0.gitDirectories).sorted()) })
  }
}
