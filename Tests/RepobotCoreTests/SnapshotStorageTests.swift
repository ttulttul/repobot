import Foundation
import Testing
@testable import RepobotCore

struct SnapshotStorageTests {
  @Test func testRetainedSnapshotsCopyOnlyChangedPagesAndKeepArrayEncoding() throws {
    let original = SnapshotList(0..<2048)
    var edited = original
    edited[777] = -1
    #expect(original[777] == 777)
    #expect(edited[777] == -1)
    let differing = zip(original.pageStorage, edited.pageStorage).filter { $0 != $1 }.count
    #expect(differing == 1)
    let encoded = try JSONEncoder().encode(edited)
    #expect(try JSONDecoder().decode([Int].self, from: encoded)[777] == -1)
    #expect(try JSONDecoder().decode(SnapshotList<Int>.self, from: encoded) == edited)
    var structural = edited
    structural.remove(at: 31)
    structural.append(2048)
    #expect(structural.count == edited.count)
    #expect(edited[31] == 31)
    #expect(structural[31] == 32)
    for _ in 0..<33 { structural.removeLast() }
    #expect(structural.count == 2015)
    #expect(original.count == 2048)
  }

  @Test func testPublishedWorldAndEnvironmentStayImmutableAfterDelta() {
    var env = EnvironmentSnapshot(environment: .local)
    env.repos = SnapshotList((0..<100).map { index in
      var repo = RepoSnapshot(path: "/repos/\(index)")
      repo.originURL = "https://example.test/\(index).git"
      return repo
    })
    var analyzer = IncrementalAnalyzer()
    let config = Configuration()
    let old = analyzer.analyze([env], configuration: config)
    let savedEnvironment = env
    env.repos[42].modified = 1
    let changes: RepositoryChanges = [RepositoryID(environment: env.id, path: env.repos[42].path):
      RepositoryChange(repo: env.repos[42], position: 42)]
    let new = analyzer.analyze([env], configuration: config, changes: changes)
    #expect(old.clones[42].repo.modified == 0)
    #expect(savedEnvironment.repos[42].modified == 0)
    #expect(new.clones[42].repo.modified == 1)
    #expect(zip(old.clones.pageStorage, new.clones.pageStorage).filter { $0 != $1 }.count == 1)
    #expect(new.changes?.indices == [42])
    #expect(new.changes?.previous == old.changes?.revision)
  }
}
