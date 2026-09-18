# Repobot

A macOS 15+ menu bar app for Git repositories on this Mac and SSH-reachable Macs or
Linux machines. It surfaces conflicts, interrupted operations, old changes, unpushed
commits, upstream changes, and differences between copies of the same repository.

## Build and run

Requires a Swift 6 toolchain (normally Xcode or Command Line Tools). No third-party
Swift dependencies are required.

```sh
./scripts/build-app.sh
open dist/Repobot.app
```

The first launch opens **Environments** in Settings. Use **Choose Repository Folder…**
on **This Mac** to start monitoring. Existing configurations keep their folders.

Settings has three native tabs: **Environments**, **Coding Agents**, and **General**.
The menu and Command-Comma open the same window. Environment and account editors
keep related fields in one sheet, with advanced sections collapsed. Save commits
the draft only after it is written successfully; Cancel discards it. Adding an environment
walks through choosing a device, connecting, and selecting repository folders.
Repositories are discovered up to four folders below each root; the root itself is
also checked. Use **Add Environment…** for SSH hosts. The menu can also be opened
with **⇧⌘R** while a Repobot window is active.

The build includes a layered `AppIcon.icon` for macOS 26+ when a working Xcode
asset compiler is available; Xcode also generates a compatibility icon for older
macOS. CLT-only or broken-Xcode builds explicitly fall back to the existing ICNS.
Set `REPOBOT_LAYERED_ICON=1` to require layered compilation (and fail if unavailable),
or `=0` to select the original ICNS. See [icon assets](assets/icons/README.md).

**Check Now** also works while monitoring is paused: it performs one check and
leaves continuous monitoring paused. Cached results remain labeled as last known
state. **Restore Warnings** reverses Ignore from the repository detail window.
Notification settings distinguish your preference from permission in System Settings;
notifications covering multiple repositories open a map filtered to those repositories.

The build script produces an ad-hoc signed local app. It does not install the app,
register launch at login, or submit anything to Apple. Copy the finished app to
`/Applications` before enabling launch at login in Settings.

On a machine whose Xcode launcher cannot load its frameworks, `scripts/swift.sh`
automatically uses the Xcode-bundled compiler with the standalone macOS 26.5 SDK,
if both exist. It does not alter `xcode-select`, accept a license, or modify system
files. Set `REPOBOT_TOOLCHAIN_FALLBACK=0` to disable this fallback, or `=1` to force
it; `REPOBOT_SDK` overrides that fallback SDK path. Local probes also use the
standalone Command Line Tools when PATH would otherwise select Apple's Git shim.

For an Xcode project (Xcode 26+ for the layered icon):

```sh
brew install xcodegen  # if needed
xcodegen generate
open Repobot.xcodeproj
```

`project.yml` is the source of truth; the generated project is intentionally ignored.

## CLI

```sh
./scripts/swift.sh build --product repobot
.build/debug/repobot discover ~/git ~/src
.build/debug/repobot discover --hosts
.build/debug/repobot discover --hosts --scan-lan
.build/debug/repobot capabilities user@host:2222
.build/debug/repobot probe local ~/git
.build/debug/repobot probe user@host '~/git' --upstream
.build/debug/repobot watch ~/git
.build/debug/repobot config
```

Quote remote `~/…` paths so your local shell does not expand them. `probe` prints the
same JSON world model used by the app. `discover --hosts` reads Tailscale’s device
list without probing hosts; add `--scan-lan` to scan the LAN instead. `--upstream` performs `ls-remote`, never fetch. `config` prints a complete
initial configuration. `watch` is a local development harness.

## Find work across machines

Open **Repository Map…** from the menu bar (or Shift-Command-M). Repobot groups
copies under their normalized tracked remote URL, falling back to origin or the
root commit. Press Command-F to search by repository or machine and use **Shared across machines**
to show repositories present on more than one configured environment.

Each copy shows its branch, commit, working-tree changes, stashes, and commits
that may need pushing, including other local branches. **Details…** opens its
findings and Terminal actions. **Refresh all** rediscovers configured roots and
checks every configured machine; it does not connect to unconfigured Tailscale peers.

Copy rows show **Last commit** and **Newest file** ages without expanding details.
Both ages are measured at the last repository check using that machine's own
system clock. Last commit refers to the checked-out HEAD's commit date.
Newest file is the most recent modification time among regular
working-tree files, including ignored files. Git directories (including custom
and shared worktree metadata), `.git` marker files, `.DS_Store`, and AppleDouble
`._*` files are excluded. Symlinks are not followed. A checkout, build, or copied
file can have a recent modification time; these ages are clues for reviewing old
work, not proof of the last human edit or that work is safe to discard.

Clock checks allow for transport delay and timestamp precision. The map warns
when a machine's clock demonstrably differs from this Mac, or another machine's
last measured clock, by more than five seconds. Slow connections or clock changes
during a check produce an inconclusive/unavailable comparison instead of a false
skew warning. Expand the monitoring warning or a copy for more detail. Older
cached repositories show ages as unavailable until their next check.

Uncommitted changes on Linux remain visible from the Mac even when the copies
are on different branches. Different branches are informational. Confirmed
history divergence is a problem; different tips with insufficient history remain
unknown. When both copies descend from the same cached upstream, complete lists
of up to 200 local commits allow comparison without fetching Git objects. The
probe inventories up to 200 local branches per repository.

Ahead/behind counts refer to the last fetched upstream and are presented as work
to review, not proof that a push is still needed. Repobot labels offline data as
last known state and waits for fresh checks after restarting. Last commit dates
are labeled as commit dates, not as proof of recent activity on that machine.
Repobot does not automatically push, pull, merge, or resolve conflicts.

Repository checks publish in small batches before upstream network checks begin.
Settings and Repository Map show progress for each machine. A pending fresh check
means cached data is still being verified; it does not mean the machine is offline.
Upstream authentication failures are reported separately from host connection failures.

## Coding-agent resolutions

Choose **Ask an agent…** on a Repository Map group or in repository details.

1. In **Coding Agents…** (also in Settings), check the detected Codex and Claude
   Code CLI logins. Add named profiles for separate accounts. Codex profiles use
   `CODEX_HOME`; Claude Code profiles use `CLAUDE_CONFIG_DIR` (not
   `CLAUDE_HOME_DIR`). Leave the directory blank for the CLI's standard home.
   **Log in / repair in Terminal…** launches that CLI's login flow for the same
   profile. Repobot does not read or store tokens or passwords.
2. Choose a profile and optionally enter a model ID or alias. Blank means no model
   override: the harness uses its configured default. The analysis retains its
   exact profile/model for execution even if you later edit profile settings.
3. **Analyze repositories** refreshes deterministic status, then runs the CLI to
   inspect diffs, logs and source through Repobot's read-only MCP helper. Source
   and status go to the selected agent provider under that CLI account. Analysis
   shows live messages and inspection activity in the dialog, then returns a
   summary, limitations, problems, and freely proposed resolution options.
4. Choose an option for each problem to address; the default leaves it unchanged.
   Review steps, risks and affected copies. **Execute selected resolutions…**
   confirms the choices, checks that working trees and refs still match the
   analysis, and opens an interactive CLI session in Terminal with those choices.
   Normal harness permission prompts remain enabled; Repobot never passes a
   permission-bypass flag. Destructive choices require recoverable backups in the
   agent instructions. The agent must recheck upstream/state before acting.
   The dialog mirrors live Terminal output; respond to permission prompts in
   Terminal. Both activity panels have **Follow latest** and **Copy** controls.
5. When the agent finishes, exit its Terminal session, then use
   **Agent finished — verify repository status**. The button becomes available
   when the session ends, including after an error.
   This refreshes deterministic results; it does not assume that a terminal
   launch or a clean tree proves the semantic task succeeded.

Profiles are stored in `agents.json`; review context, proposals, selected options,
inspection audit metadata, activity, execution prompts, and Terminal output are stored in owner-private
`agent-reviews/<id>/` under the application support directory. Reopening a review
restores its latest saved state and never automatically replays execution.
Analysis streams through an owner-private temporary file, so a UI output-reader
interruption cannot break the agent's output stream. The raw stream is removed when
the call returns (including failures/cancellation); saved activity contains only
public messages and tool summaries. A forced app termination can leave that
private temporary file in its review directory.
The dialog retains the latest 200 analysis entries and displays a bounded tail of
execution output. The private Terminal transcript may contain source and echoed
terminal text; Repobot does not enable keystroke recording.
Analysis can be cancelled or time out. An unavailable machine is reported as a
limitation and blocks execution until a fresh review can inspect every copy.

Use a current CLI with structured-output support. Codex requires `exec`,
`--json`, `--output-schema`, and MCP configuration; Claude Code requires `auth status
--json`, `--json-schema`, `--output-format stream-json`, and `--mcp-config`. Repobot retains account/model settings
but disables shell tools and hooks for analysis and supplies a scoped read-only
inspection tool. Execution uses the normal interactive harness in Terminal.

The app build script bundles the `repobot` helper alongside `RepobotApp`; both
must be present for agent analysis. Optional live smoke tests use disposable
repositories and the default logged-in CLI profiles:

```sh
REPOBOT_TEST_AGENTS=1 ./scripts/swift.sh test --disable-xctest --filter testLiveHarnessAnalysis
```

CLI references: [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive),
[Claude CLI](https://code.claude.com/docs/en/cli-reference),
[Claude profile configuration](https://code.claude.com/docs/en/env-vars#claude_config_dir).

## What is implemented

- AppKit status menu with attention items, environment/root submenus, pause,
  rescan, check now, path copying with Option-click, and reusable detail windows.
- SwiftUI settings, manual/automatic SSH onboarding, key selection, fingerprint
  display, connection tests, root suggestions, and Terminal/Finder actions.
- Tailscale devices load on opening the environment picker, with online/offline status
  and a Refresh button. SSH is tested only for the chosen host. Bonjour and bounded
  LAN SSH-banner discovery run only after clicking Scan local network. OpenSSH respects the
  user's config, keys, agent, jump hosts, custom ports, and multiplexed connections.
  SSH control sockets live in `~/.repobot/` (owner-only permissions); settings remain
  in Application Support. If the socket path would exceed macOS's limit, connections
  run without multiplexing.
- Native local FSEvents, stdin-only Python inotify and macOS FSEvents watchers,
  installed inotifywait/fswatch fallbacks, polling, heartbeat supervision,
  reconnection backoff, two-second debounce, safety sweeps, and wake/network refresh.
- Read-only Git snapshots, worktrees, submodule exclusion, stale locks, detached
  commits, operations/conflicts, upstream freshness, and explicitly opt-in fetch.
- Repository identity normalization, same-branch peer ancestry, inverse comparisons
  when only one clone knows the commits, and conservative unknown states.
- Persistent dirty/unpushed ages, cached launch state, ignore/snooze, finding toggles,
  transition notifications, quiet hours, and launch-at-login support.

Phase 6 options are included: remote macOS Python events, opt-in fetch, stale-branch
reporting, slow-repository guidance, and doubled polling intervals after five idle
minutes on battery. Battery adaptation and stale-branch reporting are off by default.

## Safety and behavior

Probes do not alter working trees, indexes, refs, or configuration. They disable
optional Git locks, fsmonitor hooks, credential prompts/helpers, and lazy object
fetching. Only an explicit **Fetch** setting authorizes updating remote-tracking
refs. Suggested commands are copied or shown, never executed by Repobot.

Remote scripts travel over stdin. Nothing is uploaded to disk, compiled, or
installed on a monitored machine. First contact uses OpenSSH `accept-new`; changed
host keys fail and require deliberate user action. Resetting trust is exposed with
a confirmation in the environment editor. SSH keys remain in their existing files.
HTTP URL credentials are removed from persisted repository identities.

Unlike the illustrative TSV protocol in `DESIGN.md`, the implementation uses
NUL-delimited fields to preserve spaces, tabs, newlines, and shell metacharacters.
Working-tree paths in the detail window retain Git's porcelain quoting. Discovery
scans every supported depth even when a shallower repository exists, so mixed-depth
layouts remain visible. Each root contributes at most 500 repositories.

Missing peer objects do **not** prove divergence. Repobot reports ancestry as unknown
until one clone can compare both tips. Read-only `ls-remote` detects server changes
but cannot update ahead/behind counts; those remain relative to the last fetch.

A status command has a ten-second watchdog. Slow repositories are retried on safety
sweeps and manual checks. Inotify watches cover Git state and non-ignored working-tree
directories only, within directory/kernel caps; safety sweeps cover unwatched paths.
Remote watchers exit when their SSH connection closes and replace a stranded predecessor.
Repositories idle for 30 days (configurable) keep Git-state watches only, and Environments
settings offers a coding agent to fix the `.gitignore` of repositories that waste watches. Existing native watcher tools may have their own limits.
LAN scanning is restricted to one active Ethernet/Wi-Fi interface and at most a
/22; Bonjour and manual entry cover hosts outside that range.

Config and cached state live in `~/Library/Application Support/Repobot/`, with owner-only
permissions. `REPOBOT_SUPPORT_DIRECTORY` selects a separate directory for tests or
independent instances. Repository facts are checkpointed incrementally in
`inventory.sqlite`; findings are rebuilt on load. Existing `state.json` caches are
migrated automatically and retained as a backup. State contains repository metadata,
never file contents. Environment settings → Monitoring → Details shows the latest
watcher failure/recovery and check trigger.
Protect this directory as you would other developer-tool state.

## Verification

```sh
./scripts/swift.sh test --disable-xctest
python3 scripts/test-remote.py
./scripts/test-ssh.sh  # optional Docker integration fixture
```

The Swift tests create temporary repositories and exercise actual Git commands,
read-only index preservation, unusual filenames, discovery pruning, worktrees,
submodules, conflicts, unborn/detached HEAD, locks, upstream changes/deletion/fetch,
peer ancestry, age persistence, suppression, notifications, process cancellation,
large pipes, native events, and Python FSEvents. The SSH test uses a disposable
loopback-only OpenSSH container, temporary keys, and a separate known-hosts file;
it verifies probing, live events, changed-host-key rejection, and failed auth.

App-controller tests also read the observable review state while repository refresh
is suspended, and cover cancellation, harness failures, and interrupted reviews.
To explicitly repeat a saved analysis with its real CLI profile, set
`REPOBOT_TEST_REVIEW_JOB` to its `job.json` path and run
`./scripts/swift.sh test --filter testLiveReviewUsingSavedRequest` after building the app.
This sends the selected repository context to that profile's provider, uses a temporary
review directory, and never executes proposed resolutions.
No configured user environments are used. CI also exercises scripts on Linux.

## Distribution

Use your Developer ID and a preconfigured `notarytool` keychain profile:

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='repobot-notary' ./scripts/notarize.sh
```

This signs with hardened runtime, submits a zip for notarization, staples and
validates the ticket, then refreshes `dist/Repobot.zip`. No signing credentials are
stored in the repository. The local build is not a notarized public release.

## Performance

Repository progress updates are coalesced; transactional cache updates write only
changed repository records on five-second checkpoints and sweep completion. See [PERFORMANCE.md](PERFORMANCE.md) for the
profiling evidence, benchmark, validation commands, and remaining optimizations.
