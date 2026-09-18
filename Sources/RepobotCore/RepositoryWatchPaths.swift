import Foundation

/// Monitor-owned canonical paths. Freshness/content probes reuse paths until their inputs
/// change, discovery refreshes them, or a filesystem event invalidates an ancestor.
struct RepositoryWatchPaths {
  private struct Entry {
    var inputs: [String]
    var paths: [String]
    var local: Bool
    var valid = true
  }
  private var entries: [String: Entry] = [:]
  private var pathOwners: [String: Set<String>] = [:]
  private var sortedPaths: [String] = []
  private var indexDirty = true
  private(set) var resolutions = 0
  subscript(_ path: String) -> [String]? { entries[path]?.paths }
  mutating func update(_ repo: RepoSnapshot, local: Bool) {
    let inputs = [repo.path] + repo.gitDirectories
    if let entry = entries[repo.path], entry.valid, entry.local == local, entry.inputs == inputs { return }
    if local { resolutions += inputs.count }
    let resolved = local ? inputs.map(LocalWatcher.physicalPath) : inputs
    if entries[repo.path]?.inputs != inputs || entries[repo.path]?.paths != resolved || entries[repo.path]?.local != local {
      indexDirty = true
    }
    entries[repo.path] = Entry(inputs: inputs, paths: resolved, local: local)
  }
  mutating func reconcile(_ repos: SnapshotList<RepoSnapshot>, local: Bool, refresh: Bool) {
    if refresh { entries.removeAll(keepingCapacity: true); indexDirty = true }
    else {
      let present = Set(repos.map(\.path))
      let oldCount = entries.count
      entries = entries.filter { present.contains($0.key) }
      if oldCount != entries.count { indexDirty = true }
    }
    for repo in repos { update(repo, local: local) }
  }
  private(set) var routingLookups = 0
  mutating func repositories(containing path: String) -> Set<String> {
    rebuildIndex()
    var ancestor = (path as NSString).standardizingPath
    var matches = Set<String>()
    while !ancestor.isEmpty {
      routingLookups += 1
      matches.formUnion(pathOwners[ancestor] ?? [])
      let parent = (ancestor as NSString).deletingLastPathComponent
      if parent == ancestor { break }
      ancestor = parent
    }
    return matches
  }
  static let ignoredComponents: Set<String> = ["node_modules", ".venv", "vendor", "target", "build", "dist", "Library", ".Trash"]
  func ignores(_ path: String, repository: String? = nil) -> Bool {
    if let repository, let entry = entries[repository],
       (entry.inputs.dropFirst() + entry.paths.dropFirst()).contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
      return false
    }
    var relative = path[...]
    if let repository, let root = entries[repository]?.paths.first,
       path.hasPrefix(root + "/") { relative = path.dropFirst(root.count + 1) }
    return relative.split(separator: "/").contains { Self.ignoredComponents.contains(String($0)) }
  }
  private mutating func rebuildIndex() {
    if indexDirty {
      pathOwners.removeAll(keepingCapacity: true)
      for (key, entry) in entries {
        for input in entry.inputs + entry.paths {
          let normalized = (expandedPath(input) as NSString).standardizingPath
          pathOwners[normalized, default: []].insert(key)
        }
      }
      sortedPaths = pathOwners.keys.sorted(); indexDirty = false
    }
  }
  mutating func invalidateAll() {
    for key in entries.keys { entries[key]?.valid = false }
  }
  mutating func invalidate(affectedPath: String) {
    let path = (expandedPath(affectedPath) as NSString).standardizingPath
    // File edits below a watched directory do not change its canonical identity.
    // Directory/symlink replacement or a parent event does. Retain the old resolved
    // paths for event routing until the next probe/discovery installs the new paths.
    rebuildIndex()
    for key in pathOwners[path] ?? [] { entries[key]?.valid = false }
    // Prefix range lookup keeps ordinary source-file events O(log paths), rather
    // than adding another full-inventory scan to filesystem event handling.
    let prefix = path == "/" ? "/" : path + "/"
    var low = 0, high = sortedPaths.count
    while low < high {
      let mid = (low + high) / 2
      if sortedPaths[mid] < prefix { low = mid + 1 } else { high = mid }
    }
    while low < sortedPaths.count && sortedPaths[low].hasPrefix(prefix) {
      for key in pathOwners[sortedPaths[low]] ?? [] { entries[key]?.valid = false }
      low += 1
    }
  }
}
