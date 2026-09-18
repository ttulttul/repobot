# Performance notes

## Evidence from September 17, 2026

Activity Monitor sampled RepobotApp at 15:37:54, about 57 seconds after launch,
while upstream checks and agent analysis were running. The busiest observed
monitor work was `StateStore.publish → Persistence.save → JSONEncoder`.
The UI main thread waited for events in about 97% of its samples; the agent
output reader slept in about 99.7%. Blocked `read` and `wait` stacks are not
CPU-burning loops. This sample does not establish steady-state idle CPU usage
or CPU consumed by Git, SSH, and agent child processes.

The inventory inspected during diagnosis contained 719 repository copies across
three machines, with a roughly 5.7 MB JSON cache. Status checks use batches of
8; upstream checks use batches of 4. Previously, both the progress update before
each batch and the result update after it rebuilt the whole analyzed inventory
and atomically rewrote sorted, pretty-printed JSON. A complete sweep at that
inventory size could cause roughly 500 full cache rewrites.

## Implemented: cheaper publication and persistence

- `StateStore.updateProgress` updates transient environment progress without
  invalidating analyzed repository results or requesting a cache save.
- Inventory merges invalidate the cached analysis. Ordinary publications combine
  updates over 250 ms; `world()` can still obtain current results immediately.
  A progress-only publication reuses the analyzed clones.
- Dirty state is saved on a five-second deadline starting with the first unsaved
  change. The deadline is not reset by later updates, so continuous checking
  cannot postpone persistence indefinitely.
- Successful/failed sweep completion, configuration changes, and monitor shutdown
  flush pending results. Those explicit flushes can occur sooner than five seconds.
- State JSON is compact, with the same schema and atomic-write/private-permission
  behavior. Human-edited configuration files retain their readable formatting.
- A failed save retains dirty state and retries; persistence errors are published
  to the existing UI error path. Progress alone creates no new writes.
- Abrupt termination can lose updates since the last checkpoint, normally up to
  five seconds plus scheduling/write time. Normal shutdown flushes the cache.

Relevant code: `Sources/RepobotCore/Persistence.swift`,
`Sources/RepobotCore/Monitor.swift`.

### Validation

Release regression tests cover progress-only updates causing zero additional
analysis/saves, burst coalescing, deadlines during continuous updates, final flush,
configuration changes, failed-save recovery, and partial UI results arriving while
a later batch is blocked. Existing freshness, offline-machine, and state-age tests
remain part of the full suite.

A local replay of the saved 719-copy inventory, with 20 progress/result pairs,
measured the following on September 17, 2026:

| Metric | Previous publication path | New path |
| --- | ---: | ---: |
| Whole-inventory analyses | 40 | 1 |
| Cache writes | 40 | 1 |
| Elapsed time | 2.801 s | 0.065 s |
| Final cache size | 4,973,458 bytes | 3,391,893 bytes |

This is a synthetic burst benchmark, not an overall application CPU reduction.
It deliberately delivers updates within one coalescing window and then flushes.
Slow real-world checks span multiple publication/checkpoint intervals. Saved
inventory contents also change over time, so cache sizes need not match the
original diagnostic snapshot. The benchmark uses a temporary output directory
and does not contact upstreams or alter repositories or the production cache.

Reproduce with a locally configured inventory:

```sh
REPOBOT_TEST_STATE_PERFORMANCE=1 ./scripts/swift.sh test -c release --filter StateStorePerformanceTests
```

## Implemented: incremental analysis, badge updates, and upstream-only probes

The second Activity Monitor sample (16:09:29 on September 17) no longer showed
`JSONEncoder` or `Persistence.save` on sampled stacks. Remaining observed work
included `StateStore.world → Analyzer.analyze`, repeated URL normalization, and
`AppDelegate.updateBadge` sorting the attention list just to count it. That sample
was near startup; the subsequent report of approximately 6% CPU after 15 minutes
establishes that the user's concern also applies after startup.

- `IncrementalAnalyzer` caches normalized identities and findings by upstream
  group. A changed repository invalidates its group; moves/removals invalidate the
  former group too. Host errors/names and configuration changes also invalidate
  affected findings. Observation timestamps alone do not trigger analysis.
- Dirty/unpushed age boundaries, stale branches, and snooze expiry have scheduled
  deadlines. Findings can therefore change even with no filesystem events.
- `StateStore.peerMap` groups cached identities before comparing related copies,
  avoiding repeated URL normalization and unrelated pair comparisons.
- The app caches the unsorted attention count and skips notification comparisons
  for unchanged analysis revisions. The menu-bar button only updates properties
  whose displayed values changed; its image is assigned once.
- `upstream.sh` only reads checkout/tracking metadata and checks the remote. It
  does not run working-tree status, stash enumeration, branch history, root-history
  traversal, or peer ancestry checks. The monitor merges freshness fields into
  existing local results. The default remains read-only `ls-remote`.
- An explicitly configured successful fetch refreshes local facts afterward,
  because refs changed. A detected checkout/tracking change also requests a local
  refresh. Repository errors and upstream errors remain distinct from host failure.
- A file event queued during a sweep retains its affected paths instead of forcing
  another full inventory sweep. Explicit full/upstream requests retain their scope.
- Full-sweep intervals begin after the upstream phase completes, preventing a long
  network phase from making the next sweep immediately overdue. Transport failure
  defers automatic sweep retries for 60 seconds; explicit checks still work.

### Validation

Release tests compare incremental findings against the original full analyzer for
changed groups, identity changes, removals, unavailable/renamed hosts, configuration,
aging, and snooze expiry. An asynchronous test verifies age transitions are
published without repository events. Real Git fixtures verify upstream-only checks
preserve local facts and the index, handle deleted/restored remote branches and
failures, refresh after fetch, and detect a changed checkout. Monitor regressions
cover targeted events during blocked upstream checks, sweep timing, and failure
retry pacing. The full release suite passed (59 test definitions at that point;
optional live checks remain gated); a subsequent 17-test focused run included both
saved-inventory benchmarks.

A replay of the saved 719-copy inventory used 40 separately analyzed updates,
alternating repository changes and observation-time changes. This measures work
remaining after publication coalescing and excludes the initial cache population:

| Metric | Full analysis | Incremental analysis |
| --- | ---: | ---: |
| Clone analyses | 28,760 | 164 |
| Analysis elapsed time | 0.333 s | 0.103 s |
| Additional identity resolutions | Not instrumented | 0 |

All 40 resulting status collections matched full analysis. These are synthetic
measurements, not an observed reduction in settled application CPU. The existing
publication benchmark also passed (40 analysis/save pairs: 2.771 s; one coalesced
analysis/save: 0.057 s). Both use temporary output and the saved inventory without
contacting its upstreams or changing the production cache.

## Remaining work, in priority order

1. **Cache expensive Git history facts by the refs they depend on.** The local
   `probe.sh` still repeats root-history traversal, branch ahead/behind counts,
   and peer ancestry checks. Reuse results when HEAD, refs, upstream tips, and
   shallow-repository state are unchanged. Keep working-tree status fresh.
2. **Measure subprocess and wakeup overhead.** Local inspection and even the
   narrower upstream operation still launch several Git processes per repository.
   Record counts and CPU time separately for Repobot, Git, SSH, and watcher helpers
   before choosing batching or a persistent helper. Investigate watcher event
   volume if checks still do not settle.
3. **Consider finer-grained cache persistence and UI observation.** Saves still
   encode a complete world, and SwiftUI still receives a complete world when
   progress changes. Incremental persistence or smaller observed models could
   help if a new sample identifies these paths. Preserve atomic saves, bounded
   checkpoint latency, and partial-result visibility.
4. **Consider an event-driven agent-log reader.** The current reader wakes every
   50 ms during agent calls. It was mostly sleeping in the first sample and is a
   lower priority. Preserve file-backed stdout, cancellation, and final draining.

These are code-derived opportunities, not measured claims that each dominates CPU.

## Next profiling pass

Measure an initial inventory check, one complete periodic sweep, a targeted edit,
and several minutes of settled idle operation. Record parent and child CPU time,
cache-write count/bytes, analyzed publications, subprocess counts, and time until
fresh status becomes visible. Compare the same inventory and settings before and
after; retain representative samples. Current automated measurements demonstrate
less publication/persistence work, not the final steady-state CPU savings.

## Third sample and live follow-up (September 17, 2026)

The third supplied sample captured PID 79416 at 16:29:53, about 24 seconds after
launch. It contains 55 samples under `JSONEncoder.encode` from the five-second
cache checkpoint and 13 under `IncrementalAnalyzer.analyze`. The main thread was
waiting for events in 2,401 of 2,414 observations. The numerous blocking pipe reads
in `ProcessRunner` are waits, not evidence of spinning.

A read-only live measurement of the same process began about two minutes after
launch. Over 121.1 seconds, cumulative process CPU time increased from 3.39 to 6.54
seconds: **approximately 2.60% of one CPU**. Five-second intervals generally ranged
from 0.6% to 3.8%. This measurement excludes child-process CPU. Upstream checks were
still running throughout the interval; this was ongoing checking, not settled idle.
A separate ten-second sample around four minutes after launch again contained
104 samples under JSON encoding and roughly 50 under `StateStore.world`.

### Cache cost measured directly

An opt-in release diagnostic loads the saved inventory once, warms each encoder,
then measures process user+system CPU over 30 in-memory encodes. With 719 repository
copies, it measured:

| Encoding workload | Bytes | CPU per encode |
| --- | ---: | ---: |
| Current full-world JSON | 3,878,041 | 55.03 ms |
| Environment snapshots only, JSON | 1,093,711 | 18.22 ms |
| Environment snapshots only, binary plist | 396,858 | 27.94 ms |
| Four repository records, JSON | 11,511 | 0.18 ms |

The current cache includes each repository both in `environments[].repos` and
again in `clones[].repo`, along with derived findings and peer descriptions. The
previous fix reduced write frequency but still encodes the entire world at every
checkpoint. At one encode per five seconds, 55 ms represents approximately 1.1%
CPU before analysis, filesystem work, or other activity. Removing duplicate and
derived data helps, but incrementally persisting changed repository records is the
larger opportunity. The four-record result is serialization only, not a complete
incremental storage implementation or a forecast of final app CPU. Binary plist
was smaller but slower than inventory-only JSON in this test.

Recommended persistence direction: retain bounded checkpoint latency and atomic
recovery, store repository facts once, update only dirty records, and reconstruct
findings in memory. Support loading existing `state.json` during migration. Do not
trade correctness for a longer arbitrary save interval.

### Extra work and watcher evidence

- `AppState.start` calls `wake()` on **every** satisfied `NWPathMonitor` callback.
  `wake()` stops watchers, forces discovery, and requests a full upstream check for
  every environment. An isolated network-monitor test delivered an initial
  satisfied callback within 1 ms, without a connectivity transition. Thus ordinary
  startup can enqueue another sweep in addition to each monitor's startup sweep;
  further satisfied callbacks can request more. During the live observation, Mini
  started another full local/upstream pass immediately after finishing its first.
  This is consistent with the callback path, but the running app does not record
  sweep reasons, so that particular pass cannot be attributed conclusively.
- Fix the network trigger to distinguish initial state, actual recovery, and
  meaningful path changes. Preserve a real wake/reconnect check, coalesce duplicate
  requests, and record each sweep's trigger and duration for subsequent profiling.
- The saved live state consistently reported `This Mac` as `Polling — events
  reconnecting`. Its polling interval is 60 seconds versus a 300-second safety
  interval for working event monitoring. The app discards the specific watcher
  exception in `startWatcher`; it also restores old mode text from cache.
  Registering the same 441 paths succeeded both in a standalone FSEvents diagnostic
  and with the actual `LocalWatcher` in a release test. Therefore excessive path
  count is not demonstrated as the cause. Preserve/report the original error and
  verify the active watcher before claiming a particular fix. Access to the local
  unified log store was denied during this investigation.
- The first pass includes 649 upstream-bearing copies (178 local, 143 on Mini,
  328 on Linux). By the later observation, upstream checks on the Macs had recorded
  27 and 23 failures respectively. Remote latency and sequential probes extend the
  active-check period into minutes, keeping checkpoint work active. Consider
  per-environment reuse of identical upstream queries and retry backoff separately;
  do not assume credentials or reachability are interchangeable across machines.

Reproduce the opt-in diagnostics without probing repositories, contacting their
upstreams, or modifying the app cache:

```sh
REPOBOT_TEST_DIAGNOSTICS=1 ./scripts/swift.sh test -c release --filter PerformanceDiagnosticsTests
```

Both diagnostic tests passed. This investigation added diagnostics and evidence;
no production implementation or rebuilt app was delivered in this pass. The next
priority is incremental persistence and correcting the network-trigger behavior,
with watcher error reporting to resolve the outstanding fallback diagnosis.

## Implemented after the third sample

### Incremental, transactional persistence

Repository facts now live in `inventory.sqlite`. Each checkpoint compares the
current facts with the last committed records and encodes/upserts only changed
repositories. Environment metadata is stored separately; derived findings and
peer descriptions are reconstructed on load. Progress text is transient, and
age-only finding transitions do not request a checkpoint.

Each checkpoint is a single SQLite transaction with full synchronous durability
and rollback journaling. The five-second first-change deadline, flush on sweep
completion/shutdown, and retry after failures remain. Failed transactions preserve
the previous complete snapshot and leave the in-memory dirty baseline unchanged
for retry. Deleted repositories/environments and repository ordering are included
in the transaction. Database permissions are owner read/write only.

Startup reads the database when it contains a committed inventory. Otherwise it
loads the existing `state.json`; the first successful checkpoint migrates those
facts. The legacy file remains untouched as a migration backup. A committed empty
inventory does not fall back to that backup, and corrupt/unsupported databases
report an error rather than silently restoring stale JSON. The first checkpoint
of a process writes its full current facts; subsequent checkpoints are incremental.

A release benchmark replayed 30 separate four-record updates against the saved
719-copy inventory, including serialization, database transactions and disk writes:

| Checkpoint | Mean process CPU |
| --- | ---: |
| Previous full-world JSON save | 56.78 ms |
| Incremental SQLite save | 3.04 ms |

Exactly 120 repository records were encoded after the initial population, and the
restored facts matched the final input. This is about 95% less checkpoint CPU in
this workload; it is not an overall app CPU measurement. Reproduce with:

```sh
REPOBOT_TEST_DIAGNOSTICS=1 ./scripts/swift.sh test -c release --filter PerformanceDiagnosticsTests/testIncrementalPersistenceCPU
```

### Network-triggered checks

The initial network report and repeated unchanged available reports do not request
checks. Recovery from an unavailable network, or a change in the active interface
set/IP-family/DNS availability, requests a remote check. A two-second coalescing
window combines notifications; monitor queues also combine requests received while
busy. Network-triggered checks restart remote watchers and refresh remote status
and upstream evidence, without forcing discovery or checking the local machine.
Real system wake still requests discovery/checks for all machines. Hosts begin
recovery checks concurrently rather than waiting for one another's full sweep.

### Watcher diagnosis

Watcher startup exceptions, remote exit status/stderr, and missing heartbeats are
retained with a timestamp. Successful readiness marks the last failure recovered.
Explicit watcher cancellation does not record a failure. The last failure survives
checkpoints, while startup resets live mode/reconnecting indicators so old mode
text cannot masquerade as the current watcher state. Swift's unified log also
receives failure events with private error text.

Environment settings now expose a **Monitoring details** dialog with the failure,
recovery time, and latest check trigger/start/finish. Sweep triggers distinguish
startup, scheduled, filesystem, manual, network recovery, and system wake checks.
This records the evidence needed to diagnose the earlier local watcher fallback;
it does not presume its underlying cause has been fixed.

### Validation

The full release suite passed with 72 test definitions. Relevant coverage includes migration, corruption
reporting, private permissions, no-op saves, changed-row counts, deletion/order,
transaction rollback and retry, startup network suppression, duplicate reports,
real recovery/route changes, coalesced remote checks without rediscovery, local
network-event suppression, and retention of remote watcher exit status/stderr.
The gated checkpoint benchmark also passed. A subsequent 16-test focused run passed
after final monitor metadata and recovery fixes, including forcibly terminating a
SQLite writer mid-transaction and recovering the previous complete snapshot.
Overall post-relaunch CPU remains a
separate live measurement.

## Fourth sample: repository map remains active after closing

The supplied sample captured PID 67494 at 17:12:23, roughly 46 seconds after launch,
after the user closed the repository map. It still contains SwiftUI transactions
running `RepositoryMapView.body`, `RepositoryMapView.groups`, and
`WorldSnapshot.repositories`. Both accesses to `groups` appear independently:
the empty-state check at line 54 and `ForEach` at line 59. The getter groups the
entire clone inventory, sorts copies, sorts groups (including localized string
comparison and repeatedly computed severity), and then filters the result.

The window lifecycle explains why this can continue while closed:
`AppState.show` sets `isReleasedWhenClosed = false`, retains each window in its
`windows` dictionary, and has no close handler to remove the window or detach its
hosting controller. Its retained map view observes `state.world`, which changes
for progress and timestamp updates as well as substantive repository changes.
`LazyVStack` does not cache the grouping/sorting performed to produce its input.

A follow-up ten-second sample of the same process, without opening the map,
contained 72 observations under its body evaluation, with most of those in the
two grouping/sorting paths. A simultaneous 30.1-second process CPU measurement
increased from 5.17 to 5.89 CPU seconds: approximately **2.39% of one CPU**.
The map was not the only work: inventory checkpoints and incremental analysis
were also active. In the supplied short sample the main thread waited for events
in 2,369 of 2,379 observations, so that sample alone cannot assign all of the user's
reported 4% to the hidden UI or explain the earlier 10% opening peak.

Current persisted diagnostics show these checks were triggered by startup, not
repeated network-availability requests. Local and Linux checks were still in
progress during the live observation. The local watcher now records its actual
failure point: `Could not create local filesystem watcher` (FSEventStreamCreate,
not FSEventStreamStart). Its underlying cause remains to be investigated.

Recommended map changes:

1. Dispose of the map's hosting view and retained window entry on close, recreating
   them on reopen. Verify that closing stops observation-driven work and repeated
   open/close cycles do not retain view trees. Treat active agent sessions separately
   so disposing a view does not unintentionally cancel authorized background work.
2. Cache group membership and ordering across unchanged repository results; compute
   the filtered list once per relevant change rather than twice per body evaluation.
3. Separate lightweight progress/freshness updates from repository-list observation,
   and update affected rows without rebuilding all groups. Keep displayed freshness
   and unavailable-host indicators correct.

Validate closed-map CPU and absence of map evaluation in a sample, then measure
opening, scrolling, filtering, a single changed repository, and progress-only updates.
The analysis above preceded the implementation described below.


## Repository map lifecycle and presentation fixes

Implemented the three map changes identified in the fourth-sample investigation:

- Closing the map now detaches its hosting controller and content view, removes
  its retained window entry, and releases its presentation model. Reopening builds
  a new model from the latest world snapshot. Agent windows and their ongoing
  sessions keep their existing lifecycle.
- `RepositoryMapModel` caches upstream membership, sorted groups, summaries, and
  the filtered list. Membership changes rebuild grouping; severity changes reorder
  groups. A changed repository refreshes only affected group summaries. Each row
  retains its identity and the latest full clone for the Details action.
- The map no longer observes `AppState.world`. Progress banners and checked times
  have separate observable values and views. Timestamp-only publications do not
  replace row content or invalidate list membership. The analyzer's semantic
  revision skips content comparisons on progress-only updates; snapshots without
  a revision still receive full comparisons. Closing also disconnects the model
  from world publications entirely.

Regression tests exercise 240 copies across 80 upstream groups. After initial
construction, 100 progress/freshness publications cause zero additional grouping,
sorting, filtering, or summary refreshes, and zero observed list/row-content
invalidations. Checked timestamps and progress text still update. Tests also
cover changed work, moving copies between upstreams, deletion, shared-machine and
search filters, renamed/offline machines, awaiting-fresh-check indicators,
revisionless snapshots, and reconstructing a map from current state. Three actual
AppKit window-close cycles release weak references to both the hosting controller
and model, even while the test retains the closed window.

Validation: the full release suite passed (77 tests across 15 suites). The release
app was rebuilt and passed strict code-signature verification.

These checks establish lifecycle and update behavior, not a measured reduction in
whole-app CPU. After relaunch, compare idle CPU before and after opening/closing
the map and take another sample if usage remains elevated. The previously recorded
local filesystem watcher creation failure remains a separate investigation.

## Local watcher failure and changed-record pipeline (2026-09-17)

### Watcher root cause and reproduction

The local inventory supplied **441 watch paths**: the configured `~/git` root,
214 repositories, and their Git directories. Most were descendants or duplicates
of that root. FSEvents watches directory hierarchies recursively, but the
`WatchRoot` flag also registers changes along each explicitly supplied path.
Registering every descendant consumed thousands of file descriptors unnecessarily.

This machine's `launchctl limit maxfiles` reports a **256** soft limit for launched
GUI applications. The terminal/test process instead inherits **1,048,575**. This
explains why the existing watcher passed ordinary tests yet failed in Repobot:

- Before the fix, the configured-watcher diagnostic succeeded under the terminal
  limit and failed when descriptors were restricted. A separate raw registration
  probe explicitly set its own soft limit to 256 and reproduced the nil result.
- A raw registration diagnostic using the original 441 paths increased open
  descriptors from **4 to 3,639** under the higher limit.
- After the fix, those same 441 paths reduce to **one recursive root** and the
  configured watcher successfully registers under the 256-descriptor limit.
- A real event-delivery test with 400 nested Git directories and an external
  directory reached through a symlink passes using two recursive watch roots.
  Swift's test runner can raise an inherited soft limit (observed: 256 to 2,048),
  so the configured-watcher diagnostic enforces 256 inside the test process and
  prints the effective limit.

Registration now resolves physical paths, removes duplicates and covered
children, and retains separate external roots. Monitor event matching uses cached
physical paths, so `/var` versus `/private/var` and symlink spellings do not turn a
known-repository edit into an unnecessary discovery. Newly probed external Git
or worktree directories extend watcher coverage immediately. Dropped-event,
root-change and mount flags request reconciliation. Watcher errors include the
root count, descriptor limit and errno when supplied; errno after an FSEvents
failure can reflect its cleanup, so it is not treated as the sole diagnosis.
No process or system descriptor limits are raised.

Relevant API contract: [Apple FSEventStreamCreate documentation](https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate)
and the installed FSEvents SDK header's `kFSEventStreamCreateFlagWatchRoot` comments.

### Changed records through the monitoring pipeline

Probe batches now carry exact repository paths into `StateStore.merge`.
Environment metadata uses an empty path set; discovery reconciles membership and
ordering. The store maintains path indexes and independently coalesces analysis
and persistence changes as `(environment ID, repository path)` records, including
explicit deletions and ordering positions. Failed saves retain the pending records
for retry; baselines advance only after the SQLite transaction commits.

The analyzer compares only changed inputs, uses cached membership to assemble
only affected upstream groups, and patches the existing clone list. Full list
reconstruction occurs for membership/order changes. Host name/error changes and
age/configuration transitions still invalidate the groups they affect. Peer-commit
lookup also uses cached membership and the requested probe paths instead of
regrouping the full world before each check.

Persistence reads the changed-record set directly. It no longer rebuilds and
compares every repository dictionary to discover which four rows changed. Initial
checkpoints, configuration reconciliation and deleted-cache recovery retain full
rebuild paths. Environment metadata, transaction durability and fresh timestamps
remain intact.

### Validation and remaining costs

The full release suite passed **84 tests across 17 suites**. New regression tests
check bounded record visits through the store/analyzer/cache, full-analysis
parity for upstream moves/deletions/reordering/age changes, host availability,
coalesced discovery, configuration removals and failed delta-transaction retry.
Thirty single-repository updates examined 30 records in analysis and 30 in
persistence, reanalyzing the 90 copies in the affected three-copy groups.

An isolated benchmark using the saved **719-copy** inventory compared full input
scans with explicit four-record updates over 30 checkpoints:

| Component | Full input scan | Explicit changed records |
| --- | ---: | ---: |
| Analysis CPU per update | 4.086 ms | 0.425 ms |
| Persistence CPU per checkpoint | 3.265 ms | 1.075 ms |

The changed-record path examined 120 records in each component, with only one
initial clone-list build. Benchmark caches were temporary; the app's actual
inventory was read only. These are component CPU measurements, not whole-app CPU
claims. Value-type array copy-on-write, metadata encoding, SQLite connection and
transaction overhead, event routing, and genuinely broad discovery/configuration
changes still have costs. Measure the rebuilt app after relaunch and completion
of startup checks before attributing any remaining idle CPU.

Reproduction commands:

```sh
./scripts/swift.sh test -c release
REPOBOT_TEST_DIAGNOSTICS=1 ./scripts/swift.sh test -c release --filter testConfiguredLocalWatcherRegistration
REPOBOT_TEST_DIAGNOSTICS=1 REPOBOT_TEST_FD_LIMIT=256 ./scripts/swift.sh test -c release --skip-build --filter testConfiguredLocalWatcherRegistration
REPOBOT_TEST_DIAGNOSTICS=1 ./scripts/swift.sh test -c release --skip-build --filter testChangedRecordPipelineCPU
```

## UI deltas, paged snapshots, reusable SQLite, and monitor deadlines

Implemented the next four targets from the 20:52/20:53 open/closed-map samples:

1. **Incremental map delivery.** World publications carry an analyzer-instance ID,
   monotonically increasing snapshot revision, predecessor revision, structural
   flag, and changed clone indices. The map processes only those rows, caches
   machine lookup once per update, and skips repository work for progress-only
   publications. Membership changes, a new analyzer instance, legacy snapshots,
   or a missed publication trigger a complete reconciliation. This preserves
   correctness with the stream's `bufferingNewest(1)` behavior. The UI test visits
   three affected copies out of 240, catches up after an intentionally skipped
   publication, then resumes three-row updates.
2. **Bounded snapshot copying.** `SnapshotList` stores repository and clone arrays
   in 32-record pages with value semantics. A small mutation copies only its page
   and the page directory, not every repository's fields. Retained snapshots stay
   unchanged, and unchanged pages remain shared. Structural removal/reordering
   can still rebuild storage. Codable continues to use ordinary JSON arrays, so
   persisted records, CLI output arrays, and legacy decoding remain compatible.
3. **SQLite reuse.** The cache keeps its connection and prepared statements open,
   performs schema/PRAGMA setup once per connection, and uses conflict updates
   instead of deleting/replacing existing repository rows. Transactions retain
   rollback journaling and `synchronous=FULL`. File identity checks detect deleted
   or atomically replaced databases and recreate the connection and full baseline.
   Tests verify reuse across 20 delta checkpoints, replacement recovery, failed
   transactions/retries, and recovery after an interrupted external writer.
4. **Cached scripts and deadline scheduling.** Bundled scripts are loaded once
   through a thread-safe cache; failed reads remain retryable. Monitor timers now
   target the next sweep, watcher retry, or remote heartbeat expiry. Heartbeats and
   state transitions recalculate that deadline. Sweeps run separately so watchdog
   timers remain active during long probes. Stops cancel timers and active work.
   Battery-aware polling reassesses power/idle policy at most once a minute; event
   monitoring does not require that periodic reassessment. Filesystem debouncing,
   explicit refreshes, wake/network handling, and retry backoff are preserved.

Validation: **91 tests in 19 suites passed**, including retained-snapshot/page
sharing, JSON array compatibility, missed UI publications, cached-statement reuse,
file replacement, deadline calculation and an actual idle-monitor timer test.
The saved 719-copy benchmark (30 four-record updates) measured **0.391 ms CPU per
incremental analysis** and **0.585 ms CPU per incremental checkpoint**. In that
same run, full-input scans took 3.652 ms and 2.355 ms respectively. Both incremental
components examined 120 records; the clone list was built once. These isolated
measurements do not establish post-relaunch whole-app CPU or map-rendering cost.

The release app was rebuilt and its strict code signature verified. Remaining
costs include genuinely broad changes, snapshot page-directory copies, SQLite
commit durability, and subprocess work; further optimization should be based on
steady-state measurements after startup checks finish.

## 2026-09-18: coalesced map delivery, freshness storage, and watcher path caching

Sample 7 caught a full map reconciliation, repository JSON encoding/SQLite writes,
feeding peer maps, and repeated canonical-path resolution. The main thread was
waiting in 2,370 of 2,379 observations; blocked pipe reads and dispatch-group waits
are not CPU consumption. The sample alone does not establish how much each target
contributes to sustained whole-app CPU.

Implemented these three targets independently, measuring the same release workload
before changes and after each target:

1. **Catch up across skipped revisions.** The analyzer retains at most 64 change
   steps and 4,096 changed indices. Each immutable world snapshot includes that
   bounded history. The map unions the steps after its own last revision, so internal
   `world()`/`peerMap()` reads and `bufferingNewest(1)` publication drops do not force
   an inventory scan. Structural changes, history expiry, new analyzer instances,
   and snapshots without compatible history still reconcile completely. Tests cover
   skipped internal analyses and buffered publications together, history expiry,
   membership changes, reopening, and host metadata changes.
2. **Separate observation times from repository payloads.** SQLite schema 2 stores
   `probed_at` and nullable `upstream_checked_at` as scalar REAL columns, in seconds
   since Foundation's 2001 reference date. This preserves fractional Date precision.
   Timestamp/position-only changes update those columns without encoding or replacing
   the JSON payload. Git facts, upstream errors, and other semantic evidence still
   update the payload. Schema 1 remains readable; its first checkpoint upgrades the
   schema and replaces the inventory in the same transaction. Migration failures
   roll back the schema as well as the data. Durability settings remain unchanged;
   timestamp updates still have SQLite transaction and page-write costs.
3. **Cache watcher paths by their inputs.** Status and upstream-only probes reuse
   canonical paths when repository/Git-directory inputs are unchanged. Discovery,
   dropped/root-change events, new Git-directory inputs, and events at a cached path
   or its ancestor invalidate the cache. A sorted path index handles ordinary file
   events without adding another inventory scan. Tests include retargeted symlinks,
   ancestor events, external Git directories, removals, and unchanged content probes.

### Controlled measurements

The benchmark uses **720 synthetic repository copies** (240 upstream groups on three
hosts), fixed IDs/timestamps, release optimization, and temporary SQLite/filesystem
fixtures. It never reads the user's inventory, contacts Git servers, or changes the
live cache. Every workload has a warmup. Each stage was run in **five separate test
processes**, with no other test cases selected. Measurements use process user+system
CPU (`getrusage`) and wall time. Assertions verify persistence round trips and map
inventory counts; correctness tests separately verify the incremental semantics.

Machine: Apple M2 Max, macOS 26.6.2, Apple Swift 6.4. All timing values below are
**median CPU milliseconds per operation**, not app CPU percentages.

| Workload | Baseline | After fix 1 | After fix 2 | After fix 3 |
| --- | ---: | ---: | ---: | ---: |
| Map delivery after three analysis revisions | 1.6255 | 0.2923 | 0.2867 | 0.2911 |
| Analysis plus that map delivery | 1.7818 | 0.4495 | 0.4407 | 0.4338 |
| Persist four freshness-only changes | 0.5356 | 0.5398 | 0.4462 | 0.4236 |
| Persist four real-content changes (control) | 0.5538 | 0.5217 | 0.5171 | 0.5036 |
| Update paths for four unchanged repositories | 0.1170 | 0.1183 | 0.1197 | 0.0017 |

Comparing each fix with the immediately preceding stage: map-delivery CPU fell
**82.0%** (analysis plus delivery **74.8%**); freshness-checkpoint CPU fell **17.3%**;
unchanged-path update CPU fell **98.6%**. Smaller shifts in unrelated workloads are
not attributed to those changes. We did not change checkpoint frequency or upstream
checking policy. These are component benchmarks, not proof of lower steady-state
Activity Monitor CPU, SwiftUI rendering time, or child-process CPU.

Work counters establish the removed work independently of timing noise:

| Measured workload | Baseline | Optimized |
| --- | ---: | ---: |
| Rows visited over 300 coalesced map deliveries | 216,000 | 2,700 |
| Repository JSON records encoded over 100 freshness checkpoints | 400 | 0 |
| Paths resolved over 1,000 unchanged four-repository batches | 8,000 | 0 |

Raw samples, CPU/wall ranges, median absolute deviations, source fingerprints,
base Git revisions, and test-binary hashes are saved under
[benchmarks/2026-09-18](benchmarks/2026-09-18/). Baseline and staged results are
`baseline.json`, `fix-1.json`, `fix-2.json`, and `fix-3.json`; the final runner
verification is `final.json`. Source fingerprints include uncommitted source/tests
and scripts; a Git revision alone does not identify these intermediate builds.

Validation: the full release suite passed **97 tests across 20 suites** (opt-in
benchmarks are skipped in ordinary runs). The process CPU recorder was smoke-tested
against a temporary sleeping process. No before/after live-app CPU claim is made.

### Benchmark every performance change

Run one baseline, then one run for each independently reviewable performance change:

```sh
./scripts/benchmark.py --label before --output .benchmark-results/before.json
# Apply one performance change and run its relevant correctness tests.
./scripts/benchmark.py --label after --output .benchmark-results/after.json \
  --compare .benchmark-results/before.json
```

The runner builds the release tests once, then executes five fresh processes. It
retains raw test/build logs, CPU and wall samples, counters, compiler identification,
source/binary hashes, and a source archive beside each JSON result. It rejects a
comparison with different fixture versions, inventory sizes, hardware, or OS and
rejects a run if sources changed while it was measuring. The source archive was
added for future reproducibility after the four staged measurements above; those
staged JSON files have hashes but no archived source tree. `final.json` uses the
complete runner. The result copies in this repo omit local logs/source archives; those
remain beside the runner's original output. Logs/archives in `.benchmark-results`
are intentionally ignored.

Keep the machine, power state, toolchain and background workload consistent. Inspect
ranges/MAD as well as medians; repeat inconclusive comparisons. Do not add flaky
wall-clock thresholds to correctness tests. Use work counters as deterministic
regression checks. Include a real-content control workload so a fast freshness path
does not hide slower ordinary updates. Change `workload_version` when modifying the
fixture or measured workload, and establish a new baseline.

### Confirm the effect in the running app

After rebuilding and relaunching, let startup checks complete. Keep the same
inventory, settings, power state, and repository activity for each phase. Record at
least **15 minutes** with the map open, then closed; repeat/reverse the order to
reduce bias from the scheduled-check phase. Keep the open map at the same scroll
position/filter and do not interact with it during the recording.

```sh
./scripts/measure-process.py --pid "$(pgrep -x RepobotApp)" --phase map-open \
  --seconds 900 --output .benchmark-results/map-open.json
# Close the map, then record the same duration.
./scripts/measure-process.py --pid "$(pgrep -x RepobotApp)" --phase map-closed \
  --seconds 900 --output .benchmark-results/map-closed.json
```

The recorder samples cumulative process CPU time every five seconds and divides
CPU-time growth by actual monotonic elapsed time. It reports one core as 100%, like
Activity Monitor, detects a vanished/restarted process, and retains partial results
on interruption. `ps` reports CPU time at 0.01-second precision, so use long windows.
It measures Repobot's threads, including UI and background work, but excludes Git,
SSH, and remote processes. It does not open/close windows or restart the app. Record
sweeps/watcher failures alongside unexpected spikes and take a stack sample during
them; use component benchmarks to explain the cost, not to substitute for this
whole-process measurement.


## 2026-09-18: five further reductions in recurring work

Implemented the next five targets, retaining safety sweeps and explicit refreshes:

1. **Share upstream observations within one host and authentication context.**
   Copies with the same displayed upstream are batched together. The host shares a
   successful `ls-remote --heads` result only when the actual URL and full effective
   Git configuration match. Custom SSH commands, custom HTTP configuration, relative
   endpoints, and other potentially directory-dependent authentication settings
   conservatively keep independent queries. The private invocation cache contains
   only advertised refs; configuration/credentials pass through a digest and are
   never saved. Failed queries are retried independently. Fetch mode still fetches
   every copy, since each copy needs its own objects and remote-tracking refs.
2. **Reuse unchanged history/configuration facts.** Every status check still reads
   the working tree, HEAD, tracking status, operations and locks. A host-side digest
   of refs, HEAD, effective config, shallow/graft/alternate metadata, stash reflog and
   requested peer-object availability gates reuse of the expensive history facts.
   Sorted peer inputs avoid order-only invalidation. Full probes verify the digest
   again after collecting facts; changes during the probe prevent subsequent reuse.
   Discovery and explicit refresh use full probes, and unavailable fingerprint tools
   fall back to full probes. Internal cache tokens do not invalidate map content or
   trigger semantic analysis by themselves.
3. **Reuse watcher coverage and known Git directories.** Rediscovery restarts a
   watcher only when coverage changes; root/mount changes explicitly reset it.
   Remote startup receives known private/common Git directories, avoiding repeated
   Git subprocesses. macOS roots are compacted. Linux registers Git metadata before
   working trees, records actual registration errno and coverage counts, closes the
   descriptor on total registration failure, and shows limited coverage in Monitoring
   Details. Its event loop blocks until an event instead of waking every second.
4. **Index and coalesce filesystem events.** Swift and Python route a path through
   its ancestors instead of scanning every repository. Nested copies and external
   Git directories retain their owners. A bounded 50 ms ingress buffer deduplicates
   paths before crossing into the monitor actor; more than 4,096 distinct paths
   becomes a rescan. A delivered batch schedules one debounce. Stopping a watcher
   cancels pending delivery; the existing generation check rejects late callbacks.
5. **Incremental attention and notifications.** A shared revision-aware tracker
   updates severity counts and increased-severity candidates only for affected
   clones. Progress-only snapshots do no clone work. Missed publications catch up
   through bounded history; structural changes/history expiry/source replacement
   reconcile fully. Existing severities survive source replacement to avoid duplicate
   notifications. Quiet hours, disabled notifications, unverified copies and severity
   preferences still filter delivery. The menu badge refreshes when its count changes.

### Measurements for the five targets

All values are median **CPU milliseconds per operation**, not Activity Monitor
percentages. These runs used the same M2 Max/macOS/Swift host described above.

| Workload | Before/reference | Final | Difference |
| --- | ---: | ---: | ---: |
| Read-only upstream sweep, 12 copies | 957.4324 | 994.7138 | +3.9%; no clear CPU improvement |
| Unchanged local status sweep, 12 copies | 1,943.5926 | 1,198.6730 | −38.3% |
| Remote Git-directory preparation, 12 copies | 96.2194 | 0.2054 | −99.8% |
| Remote Python routing, one event among 720 copies | 0.06285 | 0.00178 | −97.2% |
| Swift routing, one event among 720 copies | 0.16666 | 0.01121 | −93.3% |
| Attention count and notification candidates, one changed copy among 720 | 1.06097 | 0.00325 | −99.7% |

The Git fixture creates 12 actual clones and a local Git server, measures five
sweeps per process, and repeats in **three fresh release test processes**. Setup is
excluded; the initial full probe supplies the history-cache baseline. Measurements
include Repobot/test-process CPU **plus waited child-process CPU**, so moving work
into Git/shell processes does not create a false saving. Real network latency and
remote-host CPU were not measured. Upstream queries fell from **12 to 1 per sweep**,
although total Git subprocesses rose from **120 to 133** because eligibility checks
have a cost. Unchanged status sweeps fell from **228 to 132 Git subprocesses**.

Staged measurements are retained rather than only the best final result. After
upstream deduplication alone, upstream CPU was 937.9952 ms (−2.0%, overlapping the
baseline range); unchanged-status CPU was 1,783.3120 ms. After selective probes,
unchanged-status CPU was 1,198.6698 ms (**−32.8% versus the preceding stage**). The
final race-hardened version measured 1,198.6730 ms, range 1,172.0880–1,283.8490.
The −38.3% overall figure includes between-run variation already present before
selective probing; the staged figure better isolates that change.

The separate Python benchmark repeats five times with real temporary Git metadata,
without installing filesystem watches. Known-directory preparation eliminates all
**24 setup Git calls** for 12 copies. After reuse alone it measured 0.2184 ms, and
routing remained 0.06293 ms; after indexed routing it measured 0.00178 ms/event.
This does not measure recursive Linux registration or remote connection startup.

The Swift scheduling fixture uses **five fresh release test processes**, 10 warmup
operations, 500 single-copy attention updates and 10,000 routed events. Reference
and optimized operations alternate execution order within each process, with result
equality checked outside the timed region. The routing reference performs one
inventory scan (conservative versus the former monitor's repeated scans). Work
counts drop from **7.2 million repository comparisons to 50,000 ancestor lookups**;
attention visits **500 affected clones**, versus at least **360,000 clones** for
badge counting alone in the reference, plus its notification scans/sort.

Raw staged/final measurements are in
[benchmarks/2026-09-18-five-targets](benchmarks/2026-09-18-five-targets/).
Swift runner results include source fingerprints, test-binary hashes, CPU/wall
ranges, MAD and per-run counters; Python results retain source hashes and raw
samples. Local logs and source archives are retained in
`.benchmark-results/five-targets/` (ignored). To reproduce the new workloads:

```sh
./scripts/benchmark.py --suite git --label git --repeats 3 \
  --output .benchmark-results/git.json
./scripts/benchmark.py --suite scheduling --label scheduling \
  --output .benchmark-results/scheduling.json
python3 scripts/benchmark-watchers.py --label watchers \
  --output .benchmark-results/watchers.json
```

The existing component controls were repeated twice (five processes per run).
Map delivery was 0.2929/0.2903 ms versus the previous 0.2869 ms, with overlapping
ranges and the same 2,700 visited-row counter. Content persistence was
0.5245/0.5131 ms versus 0.5060 ms. Freshness persistence was **0.4712/0.4523 ms
versus 0.4217 ms** (+11.7%/+7.3%); ranges overlap, and both still examine 400 records
and encode zero, but this modest slowdown is unresolved. Retain both runs and
investigate with alternating baseline/new builds before attributing it to either
code changes or SQLite/background-load variance. The tiny unchanged-path control
was 0.0018 ms versus 0.0017 ms, with zero resolutions in every run.

No post-relaunch whole-app CPU reduction is claimed from these component results.
Linux failure diagnostics were tested with simulated `inotify_add_watch` failures
on macOS; actual Linux watch registration still needs a live-host check.

Validation: **109 Swift tests across 26 suites and three Python watcher tests
passed**, including cached/full probe equivalence, ref/stash/config/peer-object
invalidation, concurrent ref mutation, shared upstream authentication boundaries,
watcher reuse, nested/external path routing, coalescing overflow and notification
parity. Shell syntax and whitespace checks passed. The release app and CLI were
rebuilt in `dist/Repobot.app`; strict deep code-signature verification passed.

### Additional optimization opportunities

These are remaining targets, not measured improvements already delivered:

1. **Reduce Git process launch and fingerprint overhead.** The local upstream
   fixture removes most network queries without a clear CPU reduction: extra config
   checks offset cheap local-server queries. A combined metadata helper or batched
   Git plumbing may help more than another Swift collection optimization. Measure
   both full/cold probes and cached probes, including child CPU. Full probes now
   perform two fingerprint passes for correctness; quantify that cold-path cost
   before expanding the cache. Large histories and many branches need separate
   fixtures from the small repositories measured here.
2. **Make rediscovery more selective.** Unknown non-repository file events still
   request discovery. Distinguishing directory/membership changes from unrelated
   files could avoid broad scans during builds outside known repositories. Preserve
   root replacement, symlink retargeting and nested-repository discovery behavior.
3. **Incrementally adjust remote watcher coverage.** Membership changes still
   rebuild the stream/watch tree. Known-directory reuse eliminates Git setup work,
   but Linux recursive registration remains proportional to directory count.
   Report new runtime registration limits as trees grow, not only startup limits;
   then consider coverage-aware safety checks for fully watched repositories.
4. **Bound very large upstream groups without losing deduplication.** Keeping all
   copies of one upstream together can exceed normal batch size and delay partial
   progress. A host-side stream/cache shared across bounded chunks would preserve
   the request reduction while keeping cancellation and progress responsive.
5. **Measure the residual running-app costs.** Repeat the 15-minute open/closed map
   protocol above with the new build, recording scheduled sweeps and watcher errors.
   The current process recorder excludes Git/SSH children and remote CPU; extend that
   accounting before attributing total energy use. SQLite durability/page writes,
   broad membership changes, and SwiftUI rendering remain candidates only if fresh
   measurements identify them. Blocked pipe reads and waits are not evidence of CPU
   consumption by themselves.
