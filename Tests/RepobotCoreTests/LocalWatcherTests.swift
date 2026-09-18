import Foundation
import Testing
@testable import RepobotCore

private actor LocalWatchEvents {
  var changed = Set<String>()
  func receive(_ event: WatchEvent) { if case .changed(let path) = event { changed.insert(path) } }
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
