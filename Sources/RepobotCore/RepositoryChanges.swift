import Foundation

/// A repository's stable identity in an environment (independent of its upstream).
struct RepositoryID: Hashable, Sendable {
  var environment: UUID
  var path: String
}
/// Coalesced latest value. A nil repository is an explicit deletion; position preserves
/// discovery ordering without rescanning other environments at every checkpoint.
struct RepositoryChange: Sendable {
  var repo: RepoSnapshot?
  var position: Int
}
typealias RepositoryChanges = [RepositoryID: RepositoryChange]
