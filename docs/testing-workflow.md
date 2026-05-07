# B2OU testing workflow

This document is the working contract for keeping the menu-bar GUI, workspace
flows, and core export engine aligned.

## What we are testing

B2OU has three layers that need different kinds of proof:

1. Core export behavior
   `B2OUCore` covers export, cleanup, sidecar state, Bear CLI fallback,
   TextBundle handling, and dirty-file protection.
2. GUI/backend contracts
   The menu panel, workspace, dashboard, and note browser must each point to a
   real backend capability. Their inventory lives in
   `Sources/B2OUAppSupport/FeatureContract.swift`.
3. Release builds
   The CLI and menu-bar app must still build cleanly after changes.

## Automated entry points

Use these commands as the default local and CI flow:

```bash
swift build --product B2OUCoreSmokeTests
swift build --product B2OUCoreRegressionTests
swift build --product B2OUCoreContractTests
swift build --product B2OUWorkflowTests
swift build --product b2ou
swift build --product B2OUMenuBar
./scripts/run-test-suite.sh
```

The repository currently uses custom Swift executables instead of `swift test`
because the available CLI toolchain may not ship a working `XCTest` or
`Testing` module in every environment. The direct binaries behind
`./scripts/run-test-suite.sh` are the stable entry points.

The automated flow covers:

- `B2OUCoreSmokeTests`: fast sanity checks
- `B2OUCoreRegressionTests`: filesystem, SQLite, and conflict regressions
- `B2OUCoreContractTests`: config and export contracts
- `B2OUWorkflowTests`: GUI/backend contract and app-support state checks

The new `B2OUAppSupport` library holds the reusable app-side models and
contracts that both the menu-bar app and workflow tests now share.

## GUI/backend contract rules

Every GUI feature must be tagged as one of these states:

- `implemented`: the UI points to a concrete backend action
- `external_link`: the UI intentionally opens a web page or external app
- `overlaps_settings`: the UI writes persistent configuration but overlaps
  another editor and should be reviewed before expansion
- `missing_backend`: invalid for anything reachable from the primary UI

Current contract notes:

- `menu.dashboard` is now a primary action and opens the existing dashboard
  flow instead of leaving that window unreachable.
- Workspace no longer persists profile rules directly; it reviews the current
  profile and routes persistent edits to Preferences.
- Profile writes now flow through a shared writer that preserves unrelated
  profiles and unknown keys, and folder-only changes must not reset other
  profile rules.
- Menu-bar status now flows through a shared snapshot builder, with explicit
  tests for setup, source-access problems, and sync-error presentation.
- Export and backup failures now travel on separate runtime channels: backup
  failures must surface in the menu, and a successful backup must not clear an
  export failure state.
- Start-at-login changes now use an explicit toggle outcome: failed launch-item
  writes must surface an alert, and the UI must keep showing the effective
  system state instead of the requested state.
- Workspace data loading now has an explicit source-first contract: prefer Bear
  source metadata, then fall back to exported Markdown only when needed.
- Source-first review surfaces now gate file actions against real export-file
  existence: `Open in Editor` / `Show in Finder` stay disabled until the
  exported file actually exists, while `Open in Bear` remains available for
  source-backed notes.
- Workspace reveal actions follow the same rule now. If the exported file does
  not exist yet, `Reveal Note in Finder` must disable instead of silently
  falling back to a parent folder.
- Missing-source-link affordances are now conditional. The workspace and note
  browser only advertise rebuild/link-repair actions when reviewed notes
  actually lack Bear IDs.
- Language switching now publishes a shared refresh signal. Open workspace,
  dashboard, note-browser, and settings windows must rerender copy from that
  signal without discarding in-progress UI state.
- `overlaps_settings` remains available as a review marker, but the primary UI
  should currently have zero features in that state.
- `settings.check_updates` is an external release-page link, not an in-app
  updater.

## Manual release checklist

Run this after changes that touch GUI behavior or export orchestration:

1. Launch `B2OUMenuBar`.
2. Verify `Export Now`, `Pause`, `Workspace`, and `Dashboard` all open or act.
3. In Workspace, verify `Export Selected` and `Export Full Scope` behave
   differently and report conflicts cleanly.
4. In Workspace, verify persistent rule edits are routed through
   `Preferences` rather than being written inline.
5. Disconnect the Bear source and confirm status text changes to an unavailable
   state instead of showing a false healthy connection.
6. Reconnect the source and verify the next export updates the last-export
   status.
7. Switch the menu language while Workspace, Dashboard, Note Browser, and
   Settings are open; confirm their labels update without resetting open drafts
   or selection state.

## Change policy

When a new GUI action is added, update both of these in the same change:

1. `Sources/B2OUAppSupport/FeatureContract.swift`
2. `Sources/B2OUWorkflowTests`

If a feature cannot be backed by code yet, do not surface it in the primary UI.
