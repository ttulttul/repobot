import Foundation
import Testing
@testable import RepobotCore

private actor LocalWatchEvents {
  var changed = Set<String>()
  func receive(_ event: WatchEvent) {
    if case .changed(let path) = event { changed.insert(path) }
    if case .changedPaths(let paths) = event { changed.formUnion(paths) }
  }
}
struct LocalWatcherTests {
  @Test func testCompactRootsRespectBoundariesAndExternalSymlinks() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let git = root.appendingPathComponent("git"), sibling = root.appendingPathComponent("git-other")
    let external = root.appendingPathComponent("external")
    for dir in [git, sibling, external] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    let link = git.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    let paths = LocalWatcher.compactRoots([git.path, git.path + "/repo/.git", git.path + "/repo", git.path,
                                          sibling.path, link.path])
    #expect(Set(paths) == Set([git, sibling, external].map { LocalWatcher.physicalPath($0.path) }))
    #expect(LocalWatcher.compactRoots(["/", git.path]) == ["/"])
  }

  @Test func testWatchPathCacheReusesPathsAndInvalidatesSymlinksDiscoveryAndGitDirectories() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
    let link = root.appendingPathComponent("link")
    for directory in [a, b] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
    var repo = RepoSnapshot(path: link.path)
    repo.gitDirectories = [link.path + "/.git"]
    var cache = RepositoryWatchPaths()
    cache.update(repo, local: true)
    #expect(cache.resolutions == 2)
    #expect(cache[repo.path]?.first == LocalWatcher.physicalPath(a.path))
    for index in 0..<100 {
      repo.probedAt = Date(timeIntervalSince1970: Double(index)); repo.modified = index
      cache.update(repo, local: true)
    }
    #expect(cache.resolutions == 2)
    cache.invalidate(affectedPath: a.path + "/source.swift")
    cache.update(repo, local: true)
    #expect(cache.resolutions == 2)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
    cache.invalidate(affectedPath: link.path)
    cache.update(repo, local: true)
    #expect(cache.resolutions == 4)
    #expect(cache[repo.path]?.first == LocalWatcher.physicalPath(b.path))
    repo.gitDirectories = [a.path + "/external-git"]
    cache.update(repo, local: true)
    #expect(cache.resolutions == 6)
    #expect(cache[repo.path]?.last == LocalWatcher.physicalPath(a.path + "/external-git"))
    cache.reconcile([repo], local: true, refresh: false)
    #expect(cache.resolutions == 6)
    cache.reconcile([repo], local: true, refresh: true)
    #expect(cache.resolutions == 8)
    cache.invalidate(affectedPath: root.path) // ancestor move/removal
    cache.update(repo, local: true)
    #expect(cache.resolutions == 10)
    cache.invalidateAll() // dropped events or changed watch root
    cache.update(repo, local: true)
    #expect(cache.resolutions == 12)
    cache.update(repo, local: false)
    #expect(cache.resolutions == 12)
    #expect(cache[repo.path] == [repo.path] + repo.gitDirectories)
    cache.reconcile([], local: false, refresh: false)
    #expect(cache[repo.path] == nil)
  }

  @Test func testHundredsOfNestedPathsUseOneRootAndExternalWorkRemainsWatched() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let git = root.appendingPathComponent("git"), external = root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    var paths = [git.path]
    for index in 0..<400 {
      let dir = git.appendingPathComponent("repo-\(index)/.git")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      paths.append(dir.path)
    }
    let alias = git.appendingPathComponent("external-link")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external)
    paths.append(alias.path)
    let events = LocalWatchEvents()
    let watcher = try LocalWatcher(roots: paths) { event in Task { await events.receive(event) } }
    defer { watcher.stop() }
    #expect(watcher.watchedRoots.count == 2)
    let nested = git.appendingPathComponent("repo-399/.git/HEAD")
    let outside = external.appendingPathComponent("HEAD")
    try Data("changed".utf8).write(to: nested)
    try Data("changed".utf8).write(to: outside)
    let expected = [LocalWatcher.physicalPath(nested.path), LocalWatcher.physicalPath(outside.path)]
    for _ in 0..<100 {
      if Set(expected).isSubset(of: await events.changed) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let received = await events.changed
    #expect(Set(expected).isSubset(of: received), "Received: \(received)")
  }
}
