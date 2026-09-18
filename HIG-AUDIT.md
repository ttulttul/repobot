# Repobot — Apple Human Interface Guidelines audit

> This is the original assessment. Implementation progress and current verification limits are recorded in [HIG-FIXES.md](HIG-FIXES.md); source line references below refer to the audited revision.

Reviewed 18 September 2026 at commit `fc941a5ba6bb1976ac3885cd794c1f330ac9bd60` on `t3code/apple-design-guidelines-audit`.

**Assessment: partially aligned, with several concrete interaction defects.** Native SwiftUI/AppKit controls, system typography, standard dialogs, and the template status icon provide a sound foundation. The biggest problems concern window ownership, modal navigation, status accuracy, and recovery. This is a design assessment against the current HIG, not an Apple certification or an App Store acceptance prediction.

**Evidence and scope.** Reviewed all presentation files in `Sources/RepobotApp`, their relevant state-management paths, bundle metadata, and icon assets. `CONFIGURATION=debug ./scripts/build-app.sh` successfully built and signed the app and CLI. Inspected a separately identified audit bundle on macOS 26.6.2 using temporary configuration, empty agent profiles, and local test roots. Observed Settings, environment editing, nested folder editing, and the empty Repository Map through screenshots and accessibility trees. Confirmed Command-Comma and Command-W behavior. The existing running Repobot instance and its configuration were left untouched; the audit instance was stopped afterward.

The computer-use connection failed during subsequent inspection, including after reconnection attempts. Populated maps, agent execution, actual notification delivery, VoiceOver speech, Full Keyboard Access, dark appearance, Increase Contrast, Reduce Transparency, smaller displays, and macOS 15 were not verified live. Two local repository fixtures were created, but their rendered results were not inspected. No agent analysis, external-provider submission, remote connection, login, or permission grant was performed. No application source was changed, and no test suite was run: this audit uses a successful build, focused UI inspection, and source evidence.

Priority describes user impact: **High** should be addressed first; **Medium** affects clarity, accessibility, or recovery; **Low** concerns polish. “Source-confirmed” means the relevant implementation is present or absent, not that every resulting scenario was reproduced.

1. **High — Two independent Settings windows. UI-confirmed.**

   Launching the audit app opened the manually constructed “Repobot Settings.” Pressing Command-Comma opened a second window with SwiftUI's Settings-window identifier. Closing that window returned to the original. The app declares a `Settings` scene and separately creates an `NSWindow` containing another `SettingsView`.

   This splits navigation and sheet ownership, potentially allowing simultaneous drafts. Route the status-menu command, first launch, Coding Agents, and Command-Comma through one Settings scene or one consistently managed controller. Acceptance: every entry point activates the same window, including while a sheet is open.

   Evidence: [RepobotApp.swift:9](Sources/RepobotApp/RepobotApp.swift#L9), [AppState.swift:269](Sources/RepobotApp/AppState.swift#L269). HIG basis: predictable access to a custom settings window in [Settings](https://developer.apple.com/design/human-interface-guidelines/settings).

2. **Medium — Editing stacks sheets on top of sheets. UI- and source-confirmed.**

   Environments → Edit → Folders → Manage opens another sheet; cancelling it returns to the editing sheet. Agent profile → CLI account → Manage repeats the pattern. Add Environment also presents its SSH identity editor as another sheet.

   Apple explicitly recommends presenting one sheet at a time from the main interface. Replace nested sheets with sections or navigation inside one editor, retaining a single draft and a clear Save/Cancel boundary. Acceptance: closing a sheet returns to its owning window; navigating between editor sections does not imply saving.

   Evidence: [SettingsView.swift:58](Sources/RepobotApp/SettingsView.swift#L58), [EnvironmentSettingsView.swift:139](Sources/RepobotApp/EnvironmentSettingsView.swift#L139), [AgentSettingsView.swift:154](Sources/RepobotApp/AgentSettingsView.swift#L154), [AddEnvironmentView.swift:117](Sources/RepobotApp/AddEnvironmentView.swift#L117). HIG: [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets).

3. **High — Repository details can present cached data as current. Source-confirmed.**

   Repository Map explicitly marks paused monitoring and pending fresh checks. Repository details only show a stale-data banner when the environment has an error. A previously clean repository can therefore retain its green checkmark and “Clean and in sync” headline while monitoring is paused or its first fresh check is pending. A checked timestamp alone doesn't explain why the status is unverified.

   Share freshness presentation across menu, map, and details. Show paused/pending/unavailable state before the cached verdict and qualify clean/in-sync claims. Acceptance: opening the same repository from every surface communicates the same freshness, including immediately after restart.

   Evidence: [RepoDetailView.swift:14](Sources/RepobotApp/RepoDetailView.swift#L14), [AppState.swift:225](Sources/RepobotApp/AppState.swift#L225), [RepositoryMapView.swift:50](Sources/RepobotApp/RepositoryMapView.swift#L50), [RepositoryMapModel.swift:34](Sources/RepobotApp/RepositoryMapModel.swift#L34). HIG: accurate, discoverable state in [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback).

4. **High — Some failed actions have no feedback in their originating window. Source-confirmed.**

   Open in Terminal writes a failure to `AppState.error`. `RepoDetailView` never displays that error, so a failed Terminal launch can appear to do nothing. Ignore and Snooze persistence failures have the same presentation gap. Elsewhere, several errors are capped at three lines with no expansion, risking loss of the corrective detail.

   Present contextual failure and recovery in the window that initiated the action. Keep full diagnostics selectable or available through a Details disclosure. Acceptance: a denied Terminal automation request and a failed settings write produce readable feedback without requiring the user to discover another window.

   Evidence: [AppState.swift:299](Sources/RepobotApp/AppState.swift#L299), [RepoDetailView.swift:103](Sources/RepobotApp/RepoDetailView.swift#L103), [SettingsView.swift:105](Sources/RepobotApp/SettingsView.swift#L105), [EnvironmentSettingsView.swift:129](Sources/RepobotApp/EnvironmentSettingsView.swift#L129). HIG: [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback), [Labels](https://developer.apple.com/design/human-interface-guidelines/labels).

5. **Medium — First launch opens general preferences instead of the required setup. UI- and source-confirmed.**

   The fresh audit configuration opened the “Settings” pane, with polling, notifications, and diagnostics. Choosing local repository folders requires discovering Environments → Edit → Manage. The default root is `~/git`; there is no prominent initial folder-selection action. The launch condition also repeats whenever there is one environment and no cached clones, rather than recording completed onboarding.

   For an unconfigured or empty installation, open the relevant environment pane and offer Choose Repository Folder. Give an empty map a direct setup action. Preserve normal last-pane behavior after setup. Acceptance: someone without `~/git` can reach a useful first scan without learning the preferences hierarchy.

   Evidence: [AppState.swift:16](Sources/RepobotApp/AppState.swift#L16), [RepobotApp.swift:56](Sources/RepobotApp/RepobotApp.swift#L56), [Models.swift:41](Sources/RepobotCore/Models.swift#L41), [RepositoryMapView.swift:69](Sources/RepobotApp/RepositoryMapView.swift#L69). HIG: [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding).

6. **Medium — Accessibility labels lose the purpose of several controls. Partly UI-confirmed.**

   The general pane exposes six identical “Manage…” buttons. The folder editor exposes a text-entry area whose value is the paths, without a descriptive label. Repeated map Details and agent buttons also lack explicit repository context. Native controls provide a baseline, but these names make direct navigation and speech targeting harder.

   Give controls contextual accessibility labels such as “Manage notifications,” “Repository root folders,” and “Details for sample-project on This Mac.” Group rows meaningfully and suppress decorative image announcements. The observed ellipsis menu already exposed “More”; it is not an unlabeled-control finding.

   Evidence: [SettingsView.swift:112](Sources/RepobotApp/SettingsView.swift#L112), [EnvironmentSettingsView.swift:170](Sources/RepobotApp/EnvironmentSettingsView.swift#L170), [RepositoryMapView.swift:119](Sources/RepobotApp/RepositoryMapView.swift#L119). HIG: [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). Acceptance requires an actual VoiceOver and Voice Control pass; the accessibility tree alone is not sufficient.

7. **Medium — Ignore has no nearby reversal. Source-confirmed.**

   Ignore repo immediately persists suppression. The detail headline changes to Ignored, but the button remains Ignore repo. Snooze has Resume warnings, which only clears snoozing and does not undo Ignore. Restoring ignored findings requires Settings → Hidden findings → Manage → Restore → Done.

   Toggle the action to Stop Ignoring or Restore Warnings and expose Undo where appropriate. Keep the central hidden-findings list for bulk management. Acceptance: an accidental Ignore can be reversed in the same context, and the result is immediately visible.

   Evidence: [RepoDetailView.swift:113](Sources/RepobotApp/RepoDetailView.swift#L113), [AppState.swift:196](Sources/RepobotApp/AppState.swift#L196), [SettingsView.swift:232](Sources/RepobotApp/SettingsView.swift#L232). HIG: recoverability in [Principles](https://developer.apple.com/design/human-interface-guidelines/principles), contextual options in [Settings](https://developer.apple.com/design/human-interface-guidelines/settings).

8. **Medium — Enabled check commands can silently do nothing. Source-confirmed.**

   The status menu's Check Now and Rescan actions, and repository detail's Re-check button, remain available while monitoring is paused. `AppState.check` immediately returns in that state. Environment Settings and Repository Map correctly disable their equivalent buttons.

   Choose one consistent behavior: disable checks with an explanation while paused, or let a manual check run without resuming continuous monitoring. Acceptance: each apparently available command produces the expected result and feedback.

   Evidence: [RepobotApp.swift:145](Sources/RepobotApp/RepobotApp.swift#L145), [RepobotApp.swift:155](Sources/RepobotApp/RepobotApp.swift#L155), [RepoDetailView.swift:112](Sources/RepobotApp/RepoDetailView.swift#L112), [AppState.swift:124](Sources/RepobotApp/AppState.swift#L124). HIG: unavailable-command treatment in [Menus](https://developer.apple.com/design/human-interface-guidelines/menus).

9. **Medium — Save failures undermine the draft/Cancel model. Source-confirmed; failure not injected live.**

   Environment and profile editors copy their draft into shared state before saving. If persistence fails, the sheet remains open, but Cancel only dismisses it; shared state retains the failed edit. Retrying Add Environment after a failed write appends the environment again. This contradicts the apparent promise that Cancel abandons an uncommitted draft.

   Persist a proposed value before committing it to shared state, or roll back on failure. Make retries idempotent. Acceptance: with an unwritable support directory, failed Save followed by Cancel leaves the prior configuration intact; retrying Add never duplicates an environment.

   Evidence: [AppState.swift:182](Sources/RepobotApp/AppState.swift#L182), [AddEnvironmentView.swift:129](Sources/RepobotApp/AddEnvironmentView.swift#L129), [AgentSettingsView.swift:145](Sources/RepobotApp/AgentSettingsView.swift#L145), [SettingsView.swift:241](Sources/RepobotApp/SettingsView.swift#L241). HIG: Cancel semantics in [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets).

10. **Medium — Notification settings do not explain denied or revoked authorization. Source-confirmed.**

    Permission is appropriately requested only after opting in. However, denial simply sets the preference back to false. There is no explanatory state, authorization-status refresh, or route to the system notification settings. If permission is revoked externally, the app can continue to summarize its own preference as Enabled.

    Distinguish the user's preference from system authorization, refresh authorization on activation, and show a contextual Open Notification Settings action when blocked. Acceptance: first denial, later revocation, and restoration all produce accurate in-app status.

    Evidence: [AppState.swift:309](Sources/RepobotApp/AppState.swift#L309), [SettingsView.swift:99](Sources/RepobotApp/SettingsView.swift#L99), [SettingsView.swift:242](Sources/RepobotApp/SettingsView.swift#L242). HIG: [Managing notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications), [Settings](https://developer.apple.com/design/human-interface-guidelines/settings).

11. **Medium — Grouped notifications don't identify or open the complete affected group. Source-confirmed.**

    Notifications report a machine and a repository count; their bodies concatenate finding descriptions without adding repository names. Clicking opens only `clones[0]`, even if several repositories triggered the notification. A notification about multiple repositories can therefore leave the others undiscoverable from its destination.

    Include concise repository identifiers and take grouped notifications to the corresponding filtered map or attention list. Preserve direct detail navigation for a single repository. Acceptance: the destination accounts for every item named in the notification.

    Evidence: [AppState.swift:320](Sources/RepobotApp/AppState.swift#L320), [RepobotApp.swift:209](Sources/RepobotApp/RepobotApp.swift#L209). HIG: concise, useful notifications in [Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications).

12. **Low — Settings chrome and search don't fully follow Mac conventions. Partly UI-confirmed.**

    The manually created Settings window enables minimize/zoom, retains the same title across panes, and uses a custom button strip instead of a settings toolbar. The third pane is ambiguously named Settings inside Settings. The map uses a plain `TextField`, with no search icon, clear control, or explicit Find command. These are distinct from the duplicate-window defect.

    Use the standard settings presentation, title the pane appropriately, rename the general pane General, and use a native search field with a discoverable Find shortcut. Also restore map window geometry: closing currently discards the window and reopening recenters it at the default size.

    Evidence: [AppState.swift:213](Sources/RepobotApp/AppState.swift#L213), [SettingsView.swift:46](Sources/RepobotApp/SettingsView.swift#L46), [RepositoryMapView.swift:42](Sources/RepobotApp/RepositoryMapView.swift#L42), [AppState.swift:259](Sources/RepobotApp/AppState.swift#L259). HIG: [Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields), [Windows](https://developer.apple.com/design/human-interface-guidelines/windows).

**Additional design work, with narrower confidence.**

- **Menu density and wording:** attention repositories are inserted before the root lists and then inserted again under their roots. Consider avoiding duplicates and offering a clear Open Repository Map escape route. Long menus are not automatically noncompliant: Apple explicitly allows long dynamically generated menus. Normalize mixed command capitalization and make the Option-click Copy Path behavior discoverable. Evidence: `RepobotApp.swift:120–141, 176–185`; [Menus](https://developer.apple.com/design/human-interface-guidelines/menus).
- **Validation:** polling fields accept values that are later silently clamped; onboarding Continue is enabled for any nonempty host string, including malformed input. Show accepted ranges and inline validation before advancing. Evidence: `SettingsView.swift:224–229`, `Models.swift:227–235`, `AddEnvironmentView.swift:106–113`; [Entering data](https://developer.apple.com/design/human-interface-guidelines/entering-data).
- **Sizing and contrast:** fixed-width 580-point dialogs, 760–800-point minimum content widths, non-scrolling settings content, and small orange/secondary status text warrant testing at smaller effective display sizes and with accessibility settings. These are risks, not measured contrast or clipping failures. macOS does not support Dynamic Type; lack of iOS Dynamic Type behavior is not itself a Mac violation. See [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) and [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
- **Modern icon presentation:** the checked-in icon is a flattened ICNS with baked rounding, bevel, and shadow. Its preview is recognizable and the status-bar glyph uses template rendering. Current HIG favors layered, system-rendered effects and appearance variants; consider an Icon Composer asset for current macOS while retaining the macOS 15 fallback. Apple still permits flattened icons, so ICNS alone is not a failure. Live dark/tinted/clear variants were not tested. Evidence: `assets/icons/README.md`, `scripts/build-app.sh`; [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons).

**Existing strengths to preserve.** Native menus, lists, buttons, pickers, SF Symbols, semantic text colors, and system text styles do much of the platform work. Most editing sheets provide Escape/Cancel and Return/default actions. Removing environments/profiles and resetting host trust have explicit confirmations. Agent review describes provider/account use, leaves resolutions unselected initially, supports cancellation, and distinguishes execution from verification. Repository Map already provides useful paused/stale/progress text. The application uses a true template menu-bar glyph and does not request notification permission at launch.

**Recommended order.** First consolidate Settings ownership, fix freshness and contextual error reporting, and make save failure recoverable. Next flatten the editors, provide direct setup/recovery actions, correct command availability and notification states, and improve accessibility labels. Finish with search/window polish and a real accessibility/appearance matrix on both the oldest supported macOS and the current release.
