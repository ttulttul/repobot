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
