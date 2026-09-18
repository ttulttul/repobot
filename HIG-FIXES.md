# HIG remediation — 18 September 2026

Fetched `origin` and fast-forwarded this worktree from `fc941a5` to `eb76d47`
(`Add repository age monitoring and map redesign`) before implementation. The
upstream sidebar/detail map and repository-age features are preserved. Implementation
and verification were performed in the isolated audit worktree before integration.

User decisions: Check Now performs a one-time check while monitoring stays paused;
environment and agent-account editors use one grouped sheet with collapsed advanced
sections; include a layered icon version.

| Audit finding | Implementation |
| --- | --- |
| 1. Duplicate Settings windows | All AppKit entry points invoke the existing SwiftUI Settings command and its target; the separate manually owned window is removed. |
| 2. Stacked editors | Folders, SSH options, monitoring options, and agent account fields stay inside their owning draft editor. Advanced sections use disclosure controls. |
| 3. Misleading cached status | Details and map copies identify paused, pending, and unavailable results as last known state. Stale detail and menu icons no longer imply a current clean result. |
| 4. Hidden or truncated errors | Full selectable errors appear in the relevant settings, repository, and map views; detail actions surface Terminal failures. |
| 5. Initial setup | New installations start with no assumed root and open Environments with a direct folder chooser. The empty map links to setup. Configured users retain their selected pane. |
| 6. Accessibility names | General disclosure rows and switches, copy-command, repository detail, agent, root-folder, account, SSH, and search controls have contextual names. |
| 7. Ignore recovery | Ignore switches to Restore Warnings in the detail window; resuming warnings clears both ignored and snoozed state. |
| 8. Paused commands | One-time checks publish fresh results without starting timers or watchers or changing the monitoring preference. Duplicate checks are disabled while running. |
| 9. Failed-save semantics | Configuration and profiles publish only after persistence succeeds; ID-based upserts make retries idempotent. |
| 10. Notification authorization | Preference and system permission are separate; authorization refreshes on activation. Denied permission has an explanation and a System Settings action. |
| 11. Notification destinations | Bodies identify repositories; grouped notifications carry all affected IDs and open a filtered map. Single-repository notifications retain direct detail navigation. |
| 12. Mac conventions | Native Settings tabs, General naming, pane titles, disabled Settings minimize/zoom, native search and Command-F, and saved window geometry. |

Additional changes: deduplicated attention entries within environment menus,
Option-click copy-path help, scrollable editors, wrapping detail actions, strict
numeric input and range validation, and connection/discovery task cancellation
when onboarding closes. Host-trust reset still has its own explicit confirmation
and explains that it takes effect immediately.

`assets/icons/AppIcon.icon` separates the existing branch and repository lines
into vector layers on an opaque blue background. Apple’s renderer supplies masking,
lighting, and appearance variants. Xcode and the shell build include the source;
the shell build reports an explicit ICNS fallback if the asset compiler is unavailable.
See [icon build details](assets/icons/README.md).

## Verified

- Swift test suite passed: 126 tests in 28 suites; opt-in live SSH/agent checks and
  benchmarks remained skipped. New regressions cover failed saves and idempotent
  retries, initial roots, stale-state presentation, permission revocation, grouped
  notification filtering, numeric parsing, and paused checks without timers/watchers, including in-flight timer inspection and cancellation cleanup.
- `python3 scripts/test-remote.py` passed its discovery, read-only probing, unusual
  paths, new-directory, worktree, and root-event checks.
- `CONFIGURATION=debug ./scripts/build-app.sh` built the app and CLI. Deep/strict
  code-signature verification passed. The final required-layered build succeeded with the repaired system toolchain and no framework overrides, as described below.
- Required-layered mode fails explicitly when the compiler is unavailable.
- Icon Composer 27’s `ictool` successfully rendered the layered source for macOS
  design-generation 26. Default at 1024 and 32 pixels, Dark, and TintedDark at
  128 pixels were visually inspected.
- Shell syntax and `git diff --check` passed.

## Live UI verification

The computer connection recovered briefly with a newly identified test bundle.
Screenshots and accessibility trees confirmed:

- First launch opens Environments, with a direct folder chooser and disabled
  Settings zoom/minimize controls. Command-Comma reuses that Settings window.
- Environment and account editors have one sheet with collapsed advanced sections;
  expanding them reveals inline fields. Cancel discards the environment name draft.
- Entered repository roots save and discover the two disposable Git repositories.
  This test exposed and fixed a stale-draft validation bug: Save now constructs and
  validates a local proposed value before persistence. Numeric settings use the same pattern.
- General has contextual Manage labels. `10abc` is rejected with an inline error;
  changing polling to `12` saves exactly 12 seconds in the fixture configuration.
- Command-F opens the map and focuses its native search field. Typing filters the
  list, and the native clear button restores both repositories.
- Paused map results explicitly say last known state. Refresh All shows Checking
  while retaining the paused banner. After adding a new fixture file, the inventory
  cache records one untracked file and the configuration still has monitoring disabled.

Test isolation correction: the first UI-tool relaunch did not inherit the temporary
shell environment and refreshed the regular inventory cache. Its configuration and
agent-profile files retained their pre-test modification times; configured upstream
modes were read-only, with no fetch mode. That instance was stopped. Subsequent tests
used `LSEnvironment` in the separate test bundle; creation and changes of its fixture
configuration were verified directly. A fixture account profile was saved and its
existing CLI login status checked; no agent task, login flow, or provider submission
was initiated. The test instance was stopped after verification.

## Remaining verification limits

The native connection then failed with “native pipe closed before response,” including
after reconnection. Detail-window status/recovery, every Settings entry point while a
sheet is open, restored map geometry, and actual notification delivery/navigation still
need live verification. VoiceOver speech, Voice Control, Full Keyboard Access, Increase
Contrast, Reduce Transparency, dark app appearance, and macOS 15 rendering also remain
unverified. These are implementation fixes with bounded test evidence, not certification
of full HIG conformance.

Icon Composer continues to time out. Its agreement click could not be confirmed;
authorization to accept it was received, but acceptance is not reported as successful.

## Xcode repair and layered compilation

The installed receipt for `com.apple.pkg.XcodeSystemResources` was version
`16.2.0.0.1.1733547573`, while `/Applications/Xcode.app` is Xcode 27.0 (`27A266a`).
The matching bundled `XcodeSystemResources.pkg` is version `27.0.0.0.1788430725`;
`pkgutil --check-signature` verified it as Apple Software.

The package was expanded to a temporary directory. Directing `actool` to its complete
framework set through process-local `DYLD_FRAMEWORK_PATH` resolved the missing symbol.
`CONFIGURATION=debug REPOBOT_LAYERED_ICON=1 ./scripts/build-app.sh` then succeeded with
that environment. This is a compiled layered app, not an ICNS fallback:

- `Assets.car` is present; `CFBundleIconName` is `AppIcon`.
- `assetutil --info` reports three-layer `IconImageStack` entries for Aqua, Dark Aqua,
  and tintable appearances, six appearance-specific groups, and two vectors.
- The compatibility ICNS was extracted and visually inspected at 256 pixels.
- The complete app passed `codesign --verify --deep --strict`.

The user installed the bundled Apple-signed package with administrator authentication.
The installed receipt now reports `27.0.0.0.1788430725`; `actool --version` and
`xcodebuild -version` both succeed normally. No system framework files or license
preferences were manually overwritten.

Final verification explicitly removed `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH`:

```sh
env -u DYLD_FRAMEWORK_PATH -u DYLD_LIBRARY_PATH CONFIGURATION=debug REPOBOT_LAYERED_ICON=1 REPOBOT_TOOLCHAIN_FALLBACK=0 ./scripts/build-app.sh
env -u DYLD_FRAMEWORK_PATH -u DYLD_LIBRARY_PATH REPOBOT_TOOLCHAIN_FALLBACK=0 ./scripts/swift.sh test --disable-xctest
```

Both succeeded. Xcode 27's Swift Build backend nests SwiftPM resources differently;
`build-app.sh` now supports that layout as well as the native backend's layout.
The rebuilt app passed deep/strict signing verification. Its catalog again contains
three-layer Aqua, Dark Aqua, and tintable icon stacks, and its metadata selects AppIcon.
The test runner reports 101 core tests in 23 suites and 25 app tests in 5 suites,
for 126 tests in 28 suites total.

A newly signed test bundle with isolated support storage launched, but the computer-use
connection returned `cgWindowNotFound` on both path and bundle-ID selection. Finder/Dock
presentation and the remaining live UI checks above are still unverified.

## General pane refinement

General now uses a native grouped Form with Startup & monitoring, Monitoring, and
System sections. Monitoring and launch-at-login use switches. Each disclosure row
is a full-width button with a chevron, title, and secondary summary; Hidden Findings
keeps its ignored/snoozed counts inline. Notifications retains its sheet because it
also includes categories and quiet hours. The three top-level categories are unchanged.

An isolated app launch verified the section layout, scrolling through System, opening
Checks by clicking blank space in its row, and opening the Hidden Findings empty state.
Accessibility inspection verified the disclosure names and status values and exposed
a switch-label issue that was corrected with an explicit Monitor repositories label.
The final build exposes that label; switching monitoring off updates the control and
persists `enabled: false` in the isolated configuration.
The release distribution was rebuilt with the layered icon and passed signature checks.
