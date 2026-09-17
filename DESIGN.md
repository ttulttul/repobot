# Repobot — Design

A macOS menu bar app that watches git repositories across this Mac and any number of
ssh-reachable machines, and tells you at a glance whether any clone is dirty, unpushed,
behind, or diverging from another copy of the same repo elsewhere.

Guiding constraints (from the brief):

- Zero software installed on remote machines. Nothing compiled, nothing copied to disk.
  Only tools that ship with a stock macOS or Linux box: `sh`, `find`, `stat`, `git`, and,
  where present, `python3`.
- Minutes to first value. Discovery of hosts (Tailscale + LAN), one-click key check,
  auto-discovery of repos, auto-selection of the cheapest monitoring mode.
- Never mutate a repo. Every git command is read-only. Fetching is opt-in.

---

## 1. Architecture

```
┌───────────────────────────────── Repobot.app (LSUIElement, no Dock icon) ─────────────────────────┐
│                                                                                                     │
│  AppKit NSStatusItem + NSMenu   SwiftUI windows (Settings, Repo Detail, Add Environment)             │
│              │                                  │                                                   │
│              └────────────── @Observable AppState (main actor) ◄── snapshots ──┐                    │
│                                                                                │                    │
│  RepobotCore (Swift package, testable, no UI)                                  │                    │
│  ┌──────────────┐  ┌────────────────────┐  ┌──────────────┐  ┌──────────────┐ │                    │
│  │ Discovery    │  │ EnvironmentMonitor │  │ Analyzer     │  │ StateStore   │─┘                    │
│  │ Tailscale    │  │ (actor, 1 per env) │  │ per-repo     │  │ merges env   │                      │
│  │ Bonjour/LAN  │  │ - Transport        │  │ status +     │  │ snapshots,   │                      │
│  │ port-22 scan │  │ - RepoFinder       │  │ cross-env    │  │ persists     │                      │
│  └──────────────┘  │ - Prober           │  │ comparison   │  │ cache        │                      │
│                    │ - Watcher (mode)   │  └──────────────┘  └──────────────┘                      │
│                    └────────────────────┘                                                           │
│  Transport protocol:  LocalTransport (Process)   |   SSHTransport (/usr/bin/ssh + ControlMaster)   │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Key decisions:

- **One process.** The app itself is the background process. `LSUIElement=true`, launch at login
  via `SMAppService`. No helper daemon, no XPC, no LaunchAgent to install.
- **System `ssh`, not an embedded library.** We shell out to `/usr/bin/ssh`. That gives us the
  user's `~/.ssh/config`, their agent, hardware keys, jump hosts, and Tailscale SSH for free, and
  it means the key-check we show the user is exactly what their terminal would do.
  Every environment keeps one multiplexed master connection
  (`ControlMaster=auto ControlPersist=10m ControlPath=~/Library/Application Support/Repobot/cm-%C`)
  so subsequent probes are ~50 ms instead of a full handshake.
- **Scripts go over stdin, never to disk.** `ssh host sh -s < probe.sh`,
  `ssh host python3 - < watcher.py`. Nothing is written on the remote.
- **The local Mac is just another environment** using `LocalTransport`. Same probe script,
  same analyzer, so local/remote behave identically and the local path doubles as the test bed.
- **Swift 6 strict concurrency.** One actor per environment; a `StateStore` actor merges snapshots
  and publishes an immutable `WorldSnapshot` to the main actor. The `NSMenu` is rebuilt from the
  latest snapshot in `menuNeedsUpdate`, so the menu is never stale and never blocks.
- **Not sandboxed, not App Store.** We need `ssh`, arbitrary paths, and the network. Distribute as a
  Developer ID signed + notarized `.app`. Local scanning of `~/Documents`, `~/Desktop` etc. will
  trigger the normal Files & Folders TCC prompt; Full Disk Access is not required.
- **Build layout:** `Package.swift` with `RepobotCore` (library) + `repobot` (CLI dev harness:
  `repobot discover`, `repobot probe user@host ~/git`, prints the same snapshot the UI would show),
  plus an Xcode app target for `Repobot.app`. The Xcode project is generated from a `project.yml`
  (XcodeGen) so everything is text. Minimum macOS 15.

---

## 2. Data model

```swift
struct Environment: Identifiable, Codable {
    let id: UUID
    var name: String                     // "devbox", "This Mac"
    var kind: Kind                       // .local | .ssh
    var host: String                     // MagicDNS name preferred, IP fallback
    var tailscaleNodeID: String?         // re-resolve IP if it changes
    var user: String
    var identityFile: String?            // nil = ssh default behaviour
    var roots: [String]                  // "~/git", "/srv/projects"
    var watchMode: WatchMode             // .auto | .events | .poll
    var pollInterval: Duration?          // nil = global default (60 s)
    var upstreamCheck: UpstreamCheck     // .lsRemote (default) | .fetch | .off
    var capabilities: Capabilities?      // cached probe of remote tools
}

struct RepoSnapshot: Codable {           // what the probe returns, one per repo
    var path: String
    var headSHA: String; var branch: String?; var detached: Bool
    var upstream: String?; var upstreamSHA: String?; var ahead: Int; var behind: Int; var upstreamGone: Bool
    var staged: Int; var modified: Int; var untracked: Int; var conflicted: Int
    var operation: Operation             // none, merge, rebase, cherryPick, revert, bisect
    var stashCount: Int
    var originURL: String?; var rootCommit: String   // identity across machines
    var lastCommitDate: Date; var lastCommitSubject: String
    var localBranches: [String: String]  // name -> sha (capped at 200)
    var staleLock: Bool                  // .git/index.lock older than 10 min
    var probedAt: Date
}

struct RepoStatus {                      // Analyzer output, what the UI renders
    var identity: RepoIdentity           // normalized origin URL, else root commit
    var severity: Severity               // .ok, .info, .attention, .problem
    var findings: [Finding]              // ordered, each with plain-English text + suggested command
    var peers: [PeerRelation]            // this clone vs each other clone of the same repo
}
```

Config lives in `~/Library/Application Support/Repobot/config.json`; the last `WorldSnapshot` is
cached in `state.json` so the menu is populated instantly on launch while the first sweep runs.
No secrets are stored; ssh keys stay where they are.

---

## 3. Onboarding: adding an environment

Goal: from "Add Environment…" to a green checkmark in under two minutes, no typing beyond a username.

### 3.1 Host discovery (parallel, runs while the sheet opens)

**Tailscale**

1. Detect the CLI at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`,
   `/usr/local/bin/tailscale`, or `/opt/homebrew/bin/tailscale`. (Verified present on this
   machine at the first path.) Fallback detection: any `utun` interface with a `100.64.0.0/10` address.
2. `tailscale status --json` → `Self` + `Peer{}`; each peer has `HostName`, `DNSName`, `TailscaleIPs`,
   `OS`, `Online`, `UserID`, `SSH_HostKeys`. Drop `Self`, drop `Online == false` (on this tailnet that's
   28 of 55 peers skipped without a single packet).
3. TCP-connect to port 22 on every online peer concurrently (Network.framework `NWConnection`,
   1.5 s timeout, cap 64 in flight). Read the ssh banner line to distinguish OpenSSH from other
   listeners.
4. If `SSH_HostKeys` is non-empty the node accepts **Tailscale SSH**; no key needed, mark it "Tailscale
   SSH" and skip the key check.

**LAN**

1. Bonjour browse `_ssh._tcp` and `_sftp-ssh._tcp` (every Mac with Remote Login on advertises;
   most Linux boxes with avahi do too). Needs `NSLocalNetworkUsageDescription` + `NSBonjourServices`
   in Info.plist; macOS will show the Local Network permission prompt once.
2. Sweep the primary interface's subnet (cap at /22, 1024 addresses) with the same port-22 connect.
   Reverse-resolve names via mDNS/DNS. Skip addresses already found via Tailscale.

**Manual** — a plain `user@host[:port]` field for anything else (jump hosts come from `~/.ssh/config`).

Results render as one list, grouped Tailscale / LAN / Manual, with OS icon, name, IP, and "ssh ✓"
as scans complete.

### 3.2 Username and key check

Selecting a host shows a single Username field, prefilled from (in order): the `User` for that host in
`~/.ssh/config`, the local short username, or the Tailscale login name.

On each edit (debounced 500 ms) we run:

```
ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    [-i key] user@host 'echo REPOBOT_OK; uname -s; git --version'
```

`BatchMode=yes` guarantees no password prompt can hang us: success means the default key (or agent)
works, failure means it doesn't. Outcomes:

| Result | UI |
|---|---|
| `REPOBOT_OK` + git version | Green "Connected as user · git 2.43 · Linux". Next button enabled. |
| Auth failed | "Your key isn't authorized on this host." Buttons: pick another key from `~/.ssh/*.pub`, or **Install key…** which opens Terminal with `ssh-copy-id user@host` pre-typed (the only place a password can be entered, and it's the user's terminal, not us). |
| Host key changed | Red warning with the ssh text; do not auto-accept. |
| Connected, no git | "git is not installed on this host" — cannot proceed. |
| Timeout | "Unreachable on port 22." |

### 3.3 Capability probe (once, cached, re-run on demand)

Same session, one script:

```
uname -s; uname -m; git --version
command -v python3 && python3 -c 'import ctypes,sys;print(sys.version_info[:2])'
command -v inotifywait; command -v fswatch
cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null
echo ~ ; ls -d ~/git ~/src ~/code ~/projects ~/dev ~/repos ~/work 2>/dev/null
```

The last line seeds the root-folder picker with folders that actually exist, so most users just
tick `~/git` and finish.

### 3.4 Repo discovery (BFS, shallow first)

Given a root, find repos level by level:

```
find "$root" -mindepth 2 -maxdepth 2 -name .git -prune -print       # depth-1 subfolders (default)
# only if that yields nothing:
find "$root" -mindepth 3 -maxdepth 3 -name .git -prune -print ...    # depth 2, then 3, cap 4
```

- `-name .git` matches both the directory and the file form (worktrees, submodules). Submodules are
  skipped (their parent covers them); linked worktrees are kept.
- Prune `node_modules`, `.venv`, `vendor`, `target`, `build`, `Library`, `.Trash`.
- The root itself is checked too (`$root/.git`).
- Cap 500 repos per root; bare repos are ignored in v1.
- Re-run discovery every 10 min, and immediately when the root directory itself changes in event mode
  (new clone appears → shows up within seconds).

---

## 4. The probe (read-only, one round trip per environment)

A POSIX `sh` script sent over stdin, taking repo paths as arguments. It never writes to the repo:
`GIT_OPTIONAL_LOCKS=0` prevents `git status` from refreshing the index, `GIT_TERMINAL_PROMPT=0` and
`-c credential.helper=` prevent any prompt. Output is line-oriented, tab-separated (no `jq` on the
remote), one block per repo:

```
REPO      <path>
HEAD      <sha>  <branch|->  <detached 0|1>
UPSTREAM  <name|->  <sha|->  <ahead>  <behind>  <gone 0|1>
STATUS    <staged>  <modified>  <untracked>  <conflicted>
OP        none|merge|rebase|cherry-pick|revert|bisect
STASH     <n>
ORIGIN    <url|->
ROOT      <root-commit-sha>
LAST      <epoch>  <subject>
BRANCH    <name>  <sha>            (repeated, capped)
LOCK      <0|1>
END       <path>
```

Sources: `git status --porcelain=v2 --branch` (gives branch, upstream, ahead/behind and all counts in
one call), `git for-each-ref refs/heads`, `git rev-list --max-parents=0 HEAD`,
`git remote get-url origin`, `git stash list | wc -l`, existence of `.git/MERGE_HEAD`,
`rebase-merge/`, `rebase-apply/`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_LOG`, and
`find .git/index.lock -mmin +10`.

Cost: ~20–100 ms per repo on a warm cache; 30 repos every minute is negligible.

**Upstream freshness.** `ahead/behind` from `git status` is only as fresh as the last fetch. To know
if the *server* moved we need the network. Default is read-only:
`git ls-remote --heads <remote> <branch>` per repo on the upstream interval (default 5 min),
compared with the local remote-tracking ref. Opt-in alternative: `git fetch --quiet` (writes
remote-tracking refs, which many developers prefer since then `git status` in their terminal is
accurate too). If the check fails (no credentials on that box, offline), the repo gets an
"upstream unknown since <time>" info finding rather than an error every minute.

---

## 5. Monitoring modes (auto-detected, cheapest wins)

| Tier | Condition | Mechanism | Latency |
|---|---|---|---|
| 1 | Local Mac | `FSEventStream` on each root, recursive, native | < 1 s |
| 2 | Linux with `python3` (nearly universal) | `ssh host python3 -` running a stdin-supplied script that calls `inotify_init1`/`inotify_add_watch` **via `ctypes` on libc** — no packages, no compiler | < 1 s |
| 3 | `inotifywait` (Linux) or `fswatch` (mac) already installed | long-lived `ssh host inotifywait -m -r ...` / `fswatch -r` | < 1 s |
| 4 | macOS remote with Xcode CLT `python3` | FSEvents via `ctypes` on CoreServices (phase 6; fiddlier but same trick) | < 1 s |
| 5 | Anything else | Client-side polling: run the probe every `pollInterval` (global default 60 s, per-env override) over the multiplexed connection | ≤ interval |

Details for the event tiers:

- **What we watch.** `.git/` internals (HEAD, index, refs/, logs/HEAD, FETCH_HEAD, MERGE_HEAD…) for
  every repo — that's ~5 watches per repo and catches commits, checkouts, fetches, rebases, stashes.
  Plus the working tree recursively, skipping `.git`, `node_modules`, `.venv`, `target`, `build`,
  capped at 2,000 directories per repo and the kernel's `max_user_watches`. Repos over the cap get
  `.git`-only watching plus the safety sweep.
- **Safety sweep.** Even in event mode a full probe runs every 5 min (configurable) to catch anything
  the watcher missed and to run the upstream check.
- **Debounce.** Events are coalesced per repo for 2 s (an editor save or `git commit` produces dozens
  of events), then only the affected repos are re-probed.
- **Heartbeat & reconnect.** The watcher prints `PING` every 30 s; if two are missed, or ssh exits,
  the monitor reconnects with exponential backoff (5 s → 5 min) and falls back to polling meanwhile,
  so the user never loses coverage — the menu shows "events (reconnecting)".
- **Sleep/wake & network changes.** `NSWorkspace.didWakeNotification` and `NWPathMonitor` trigger an
  immediate sweep and watcher restart. On battery with no user activity we can stretch poll intervals
  ×2 (optional).
- **Per-environment override.** Settings show the detected mode ("Events — inotify via python3") with
  a picker to force polling and set the interval.

The `.git`-only fallback and the safety sweep are why we never need the working tree watched perfectly:
commits/pushes/checkouts are always instant; a stray uncommitted edit shows within the sweep interval.

---

## 6. What we track, and what counts as "needs attention"

Designed around what actually bites a developer working across a laptop, a desktop, and a couple of
dev boxes.

### Per clone

| Finding | Severity | Plain-English headline |
|---|---|---|
| Merge/rebase/cherry-pick/revert/bisect in progress | **problem** | "A rebase is in progress on devbox" |
| Unmerged (conflicted) paths | **problem** | "3 files have unresolved conflicts" |
| Branch diverged from upstream (ahead > 0 and behind > 0) | **problem** | "main has diverged from origin: 2 ahead, 5 behind" |
| Behind upstream | attention | "main is 5 commits behind origin" |
| Upstream branch deleted (`gone`) | attention | "Upstream branch was deleted (merged PR?)" |
| Uncommitted changes older than the threshold (default 4 h) | attention | "Uncommitted changes for 2 days on devbox" |
| Unpushed commits older than threshold (default 24 h) | attention | "3 commits not pushed since Tuesday" |
| Stale `index.lock` | attention | "A stale lock file may block git" |
| Detached HEAD with new commits | attention | "Detached HEAD with 2 commits that aren't on any branch" |
| Uncommitted changes (recent) | info | "Working on 4 files" |
| Unpushed commits (recent) | info | "2 commits ahead of origin" |
| Detached HEAD, no new commits | info | |
| No upstream configured | info | "Branch feature/x has no upstream" |
| Stashes present | info | "2 stashes" |
| Upstream check failed | info | "Couldn't reach origin from devbox since 09:12" |
| Clean, in sync | **ok** | |

Thresholds are global settings; "recent" work is normal and should stay green-ish (info), otherwise the
tool is just nagging.

### Across clones of the same repo (the reason this app exists)

Clones are grouped by identity: normalized `origin` URL (strip scheme/user/`.git`, lowercase host) with
the root commit as a tiebreaker/fallback when there is no origin. For each pair of clones on the **same
branch**, we ask each side about the other's tip: `git cat-file -e <otherSHA>` and
`git merge-base --is-ancestor <otherSHA> HEAD` (both read-only, done in the probe by passing peer SHAs
as arguments on the next round). Then:

| Relation | Severity | Headline (shown on the clone you're looking at) |
|---|---|---|
| Same branch, tips diverged, neither has the other's commits | **problem** | "main on devbox and on this Mac have diverged — 2 commits each way, neither pushed" |
| Other clone has commits this one doesn't (and they're unpushed) | attention | "devbox has 3 commits on main you don't have here" |
| Other clone has uncommitted changes on the same branch | attention | "devbox has uncommitted changes on main" |
| This clone is behind the other, and the other's commits are pushed | attention | "This Mac is 3 behind devbox (pull to catch up)" |
| Other clone on a different branch | info | "devbox is on feature/y" |
| Same tip everywhere, all clean | **ok** | "In sync with devbox and build-server" |

### Per environment

| State | Menu rendering |
|---|---|
| All repos ok/info | ✓ green |
| Any attention | ⚠ yellow |
| Any problem | ⚠ red-tinted |
| Unreachable / auth failed / host key changed | ✕ grey, with reason in the submenu header |
| Watcher reconnecting | ✓/⚠ with "(reconnecting)" in header |

Suppression: per-repo **Ignore** and **Snooze 1h / until tomorrow**, and per-finding "don't warn
about stashes" style toggles in Settings.

---

## 7. Menu bar UI

Modeled on the Tailscale menu (see screenshot): a header with a master toggle, "This device",
then the remote environments as submenus.

```
 ⎇   Repobot                                                    [ on/off toggle ]
      3 repos need attention · checked 12 s ago
 ────────────────────────────────────────────────
 ⚠   mailchannels-api · devbox      diverged from this Mac      ← top-level attention items,
 ⚠   repobot · this Mac             5 behind origin                sorted problem > attention,
 ⚠   infra · build-server           rebase in progress             max 6, click → detail window
 ────────────────────────────────────────────────
 ✓   This Mac  (kens-macbook-pro)                            ▸
 ⚠   devbox  (100.101.2.3 · events)                          ▸
 ✕   build-server  (unreachable since 08:40)                 ▸
 ────────────────────────────────────────────────
      Add Environment…
      Check Now                                          ⌘R
      Settings…                                          ⌘,
 ────────────────────────────────────────────────
      Quit                                               ⌘Q
```

Environment submenu:

```
      devbox · events (inotify) · checked 12 s ago · Open Terminal
 ────────────────────────────────────────────────
 ⚠   mailchannels-api          diverged from this Mac          ← attention block first (flat),
 ⚠   worker                    uncommitted 2 d                    one click, no scrolling
 ────────────────────────────────────────────────
      ~/git                                                    ← configured root (section header)
 ✓        mailchannels-api
 ✓        billing
 ✓        worker
      ~/src                                                    ← second root
 ✓        infra
 ────────────────────────────────────────────────
      Rescan for repositories
      Edit Environment…
```

- Attention items float to the top both globally (main menu) and per environment (submenu), so the
  worst thing is always one click away. Within sections, repos are sorted severity-first, then name.
- Icons: SF Symbols `checkmark.circle.fill` (green), `exclamationmark.triangle.fill` (yellow; red for
  problem), `xmark.circle` (grey). The status item itself is `arrow.triangle.branch` with a small badge
  count when anything needs attention, and a subtle animation while a sweep runs.
- Clicking a repo opens the **Repo Detail** window. Option-click copies the path. Right side of the
  item shows a short reason so most questions are answered without opening anything.
- The header toggle pauses all monitoring (connections are closed, nothing runs) — useful on hostile
  Wi-Fi or when on battery.

### Repo Detail window

A floating panel (not a true modal — menu bar apps shouldn't block anything), one per repo, brought to
front if already open:

1. **Headline** — the top finding in plain English, e.g. *"`main` on devbox has diverged from this Mac.
   Each side has commits the other doesn't, and neither has been pushed. Pushing from either side now
   will force you into a merge later."*
2. **Branch & upstream** — branch, upstream, ahead/behind, last commit (age, subject), last checked.
3. **Working tree** — staged / modified / untracked / conflicted counts and the first 20 paths.
4. **Other copies** — table: environment, branch, tip (short), relation (in sync / 3 ahead / 2 behind /
   diverged / dirty), last activity.
5. **Suggested next step** — a copyable command (`git pull --rebase`, `git push`, `git rebase --continue`)
   and buttons: **Open in Terminal** (`ssh -t user@host 'cd path && exec $SHELL'` for remotes, `cd` for
   local), **Reveal in Finder** (local only), **Re-check**, **Snooze**, **Ignore repo**.
   We do not run mutating git commands ourselves in v1.

### Notifications

`UserNotifications` only on transitions into attention/problem (never on every poll), coalesced per
environment ("devbox: 2 repos need attention"), with a quiet-hours setting and a toggle per severity.
Clicking a notification opens the repo detail.

### Settings window (SwiftUI)

- **General:** launch at login, default poll interval, safety-sweep interval, upstream check interval
  and method (ls-remote / fetch / off), thresholds (uncommitted hours, unpushed hours), notifications,
  quiet hours.
- **Environments:** list with status; per-env sheet: name, host, user, key, roots (with the folder
  suggestions from the capability probe), detected mode + override, poll interval override, upstream
  method override, ignored repos, "Re-test connection".
- **Advanced:** path to `ssh`, extra ssh options, log viewer, "Reset host key trust" per environment.

---

## 8. Resilience & edge cases

- **Host key trust:** `StrictHostKeyChecking=accept-new` on first contact (we show the fingerprint in
  the Add sheet); a changed key is surfaced as an environment error and never auto-accepted.
- **IP churn:** store the Tailscale `NodeID` and re-resolve via `tailscale status --json` before
  reconnecting; prefer MagicDNS names.
- **Multiplexing failures:** if the ControlMaster socket is stale, delete it and reconnect. Socket
  path is under our own Application Support dir to keep the path short (unix socket limit 104 chars).
- **Huge repos:** `git status` cost is bounded by the index; if a probe exceeds 10 s the repo is marked
  "slow" and probed only on the safety sweep. Suggest `core.untrackedCache` / `fsmonitor` in the detail
  window but never set it.
- **Same repo checked out twice on one machine** (worktrees): treated as separate clones; cross-clone
  logic applies just the same.
- **User is mid-operation:** an in-progress rebase is reported, never touched.
- **Locale/time:** remote timestamps are epoch seconds from `git log -1 --format=%ct`; no date parsing.
- **Shell differences:** the probe is POSIX `sh` (dash/bash/zsh-in-sh-mode all fine); we test for
  BSD vs GNU `find`/`stat` in the capability probe and pick flags accordingly.
- **Privacy:** paths and branch names are the only things that leave the remote; file contents never
  do. Logs redact hostnames unless debug logging is on.

---

## 9. Implementation phases

1. **Skeleton + local-only.** Package layout, models, config persistence, `LocalTransport`, probe
   script, analyzer with per-clone findings, `FSEventStream` watcher, status item + menus, Repo Detail
   window, Settings shell. Ship value on day one with just "This Mac".
2. **SSH environments.** `SSHTransport` with ControlMaster, Add Environment (manual host) with the
   BatchMode key check and capability probe, BFS repo discovery, client-side polling mode, root-folder
   suggestions. CLI harness `repobot probe user@host` for debugging without the UI.
3. **Discovery.** Tailscale (`status --json`) and LAN (Bonjour + subnet sweep) with parallel port-22
   checks, Local Network permission plumbing, Tailscale SSH detection.
4. **Event-driven remotes.** python3+ctypes inotify watcher, `inotifywait`/`fswatch` tiers, heartbeat,
   reconnect/backoff, safety sweep, sleep/wake handling.
5. **Cross-environment analysis + notifications.** Repo identity grouping, peer-SHA round trip,
   diverged/unpushed-elsewhere/dirty-elsewhere findings, "Other copies" table, transition
   notifications, snooze/ignore, launch at login, signing + notarization.
6. **Nice-to-haves.** FSEvents-via-ctypes for macOS remotes, opt-in `git fetch`, battery-aware
   intervals, `git fsmonitor` suggestion, stale-branch report.

---

## 10. Assumptions made (say so if any are wrong)

- Running an interpreter that already exists on the remote (`python3`) counts as "no install"; only
  copying files, compiling, or package installs are off-limits.
- Read-only `ls-remote` is the default upstream check; auto-fetch is opt-in.
- Windows hosts are out of scope (WSL works as Linux). Bare repos are out of scope for v1.
- The app is distributed outside the App Store (Developer ID), minimum macOS 15.
- Before the first build on this machine: `sudo xcodebuild -license accept` (currently not accepted),
  and `brew install xcodegen` for project generation.

---

## Appendix A — probe.sh sketch

```sh
#!/bin/sh
# usage: sh -s -- /path/to/repo1 /path/to/repo2 ...   (peer SHAs passed via env PEERS="path=sha,sha;...")
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 LC_ALL=C
for r in "$@"; do
  cd "$r" 2>/dev/null || { printf 'REPO\t%s\nERR\tmissing\nEND\t%s\n' "$r" "$r"; continue; }
  printf 'REPO\t%s\n' "$r"
  g="$(git rev-parse --git-dir 2>/dev/null)" || { printf 'ERR\tnotgit\nEND\t%s\n' "$r"; continue; }
  git status --porcelain=v2 --branch -z 2>/dev/null | tr '\0' '\n' | awk '
    /^# branch.oid /      { oid=$3 }
    /^# branch.head /     { head=$3 }
    /^# branch.upstream / { up=$3 }
    /^# branch.ab /       { a=substr($3,2); b=substr($4,2) }
    /^1 |^2 /             { if (substr($2,1,1)!=".") s++; if (substr($2,2,1)!=".") m++ }
    /^u /                 { c++ }
    /^\? /                { u++ }
    END { det = (head=="(detached)") ? 1 : 0
          printf "HEAD\t%s\t%s\t%d\nUPSTREAM\t%s\t-\t%d\t%d\t0\nSTATUS\t%d\t%d\t%d\t%d\n",
                 oid, head, det, (up?up:"-"), a, b, s+0, m+0, u+0, c+0 }'
  op=none
  [ -f "$g/MERGE_HEAD" ] && op=merge
  [ -d "$g/rebase-merge" ] || [ -d "$g/rebase-apply" ] && op=rebase
  [ -f "$g/CHERRY_PICK_HEAD" ] && op=cherry-pick
  [ -f "$g/REVERT_HEAD" ] && op=revert
  [ -f "$g/BISECT_LOG" ] && op=bisect
  printf 'OP\t%s\nSTASH\t%s\n' "$op" "$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
  printf 'ORIGIN\t%s\n' "$(git remote get-url origin 2>/dev/null || echo -)"
  printf 'ROOT\t%s\n'   "$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)"
  printf 'LAST\t%s\n'   "$(git log -1 --format='%ct	%s' 2>/dev/null)"
  git for-each-ref --count=200 --format='BRANCH	%(refname:short)	%(objectname)' refs/heads
  [ -n "$(find "$g/index.lock" -mmin +10 2>/dev/null)" ] && printf 'LOCK\t1\n' || printf 'LOCK\t0\n'
  printf 'END\t%s\n' "$r"
done
```

## Appendix B — watcher.py sketch (Linux, stdlib only)

```python
import ctypes, os, sys, select, time, struct
libc = ctypes.CDLL(None, use_errno=True)
IN_MODIFY, IN_ATTRIB, IN_MOVED, IN_CREATE, IN_DELETE, IN_ONLYDIR = 0x2, 0x4, 0xC0, 0x100, 0x200, 0x1000000
MASK = IN_MODIFY|IN_ATTRIB|IN_MOVED|IN_CREATE|IN_DELETE
fd = libc.inotify_init1(0o4000)               # IN_NONBLOCK
wd_to_repo = {}
SKIP = {'.git','node_modules','.venv','vendor','target','build','dist'}
def watch(path, repo):
    wd = libc.inotify_add_watch(fd, path.encode(), MASK|IN_ONLYDIR)
    if wd >= 0: wd_to_repo[wd] = repo
for repo in sys.argv[1:]:
    g = os.path.join(repo, '.git')
    for p in (g, g+'/refs', g+'/refs/heads', g+'/refs/remotes', g+'/logs'): 
        if os.path.isdir(p): watch(p, repo)
    n = 0
    for d, dirs, _ in os.walk(repo):
        dirs[:] = [x for x in dirs if x not in SKIP]
        watch(d, repo); n += 1
        if n > 2000: break                    # cap; safety sweep covers the rest
print('READY', flush=True)
pending, last_ping = set(), time.time()
while True:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        buf = os.read(fd, 65536); i = 0
        while i < len(buf):
            wd, mask, cookie, ln = struct.unpack_from('iIII', buf, i); i += 16 + ln
            if wd in wd_to_repo: pending.add(wd_to_repo[wd])
    if pending and not r:                      # quiet for 1 s → flush
        for p in pending: print('CHANGED', p, flush=True)
        pending.clear()
    if time.time() - last_ping > 30:
        print('PING', flush=True); last_ping = time.time()
```

The Swift side launches this with `ssh host python3 - repo1 repo2 … < watcher.py`, reads stdout line
by line, debounces `CHANGED` lines, and re-probes only those repos.
