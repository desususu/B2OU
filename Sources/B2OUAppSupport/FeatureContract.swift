import Foundation

public enum B2OUFeatureSurface: String, CaseIterable, Equatable, Sendable {
    case menuPanel = "menu_panel"
    case workspace = "workspace"
    case settings = "settings"
    case dashboard = "dashboard"
    case noteBrowser = "note_browser"
}

public enum B2OUFeatureState: String, Equatable, Sendable {
    case implemented = "implemented"
    case externalLink = "external_link"
    case overlapsSettings = "overlaps_settings"
    case missingBackend = "missing_backend"
}

public struct B2OUFeatureContract: Identifiable, Equatable, Sendable {
    public let id: String
    public let surface: B2OUFeatureSurface
    public let title: String
    public let state: B2OUFeatureState
    public let reachableFromPrimaryUI: Bool
    public let entrypoint: String
    public let backend: String
    public let notes: String

    public init(
        id: String,
        surface: B2OUFeatureSurface,
        title: String,
        state: B2OUFeatureState,
        reachableFromPrimaryUI: Bool,
        entrypoint: String,
        backend: String,
        notes: String
    ) {
        self.id = id
        self.surface = surface
        self.title = title
        self.state = state
        self.reachableFromPrimaryUI = reachableFromPrimaryUI
        self.entrypoint = entrypoint
        self.backend = backend
        self.notes = notes
    }
}

public let b2ouFeatureContracts: [B2OUFeatureContract] = [
    B2OUFeatureContract(
        id: "menu.export_now",
        surface: .menuPanel,
        title: "Export Now",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.triggerExportNow()",
        backend: "ExportWatcher.exportNow()",
        notes: "Immediate full-scope export through the active watcher."
    ),
    B2OUFeatureContract(
        id: "menu.pause_resume",
        surface: .menuPanel,
        title: "Pause / Resume",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onTogglePause()",
        backend: "ExportWatcher.paused",
        notes: "Pauses or resumes background watching without changing profile settings."
    ),
    B2OUFeatureContract(
        id: "menu.open_folder",
        surface: .menuPanel,
        title: "Open Folder",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onOpenFolder()",
        backend: "NSWorkspace.shared.open(exportPath)",
        notes: "Reveals the current export destination."
    ),
    B2OUFeatureContract(
        id: "menu.workspace",
        surface: .menuPanel,
        title: "Workspace",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onExportWorkspace()",
        backend: "NoteStore.scan(config:) + ExportWorkspace window",
        notes: "Launches the review/export workspace after scanning the current source."
    ),
    B2OUFeatureContract(
        id: "menu.dashboard",
        surface: .menuPanel,
        title: "Dashboard",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onDashboard()",
        backend: "NoteStore.scan(config:) + Dashboard window",
        notes: "Surfaces note health metrics and links into the note browser."
    ),
    B2OUFeatureContract(
        id: "menu.change_folder",
        surface: .menuPanel,
        title: "Change Folder",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onChangeFolder()",
        backend: "writeProfileConfig(profileName:update:) + reloadProfiles()",
        notes: "Persists a new export root for the active profile without resetting its other rules."
    ),
    B2OUFeatureContract(
        id: "menu.configure",
        surface: .menuPanel,
        title: "Configure",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onConfigure()",
        backend: "SettingsPanel + applySettings()",
        notes: "Primary persistent settings editor."
    ),
    B2OUFeatureContract(
        id: "menu.edit_config",
        surface: .menuPanel,
        title: "Edit Config",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onEditConfig()",
        backend: "findConfig() + NSWorkspace.shared.open(configPath)",
        notes: "Opens the TOML file directly for manual editing."
    ),
    B2OUFeatureContract(
        id: "menu.profile_switch",
        surface: .menuPanel,
        title: "Select Profile / Reload Profiles",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.setProfile() / reloadProfiles()",
        backend: "loadProfiles() + ExportWatcher rebind",
        notes: "Switches the active profile and rebuilds watcher state."
    ),
    B2OUFeatureContract(
        id: "menu.language",
        surface: .menuPanel,
        title: "Language",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onSetEnglish() / onSetChinese()",
        backend: "setLanguage() + b2ouLanguageDidChange notification + live window refresh",
        notes: "Updates the menu and live GUI windows without resetting in-window review state."
    ),
    B2OUFeatureContract(
        id: "workspace.export_selected",
        surface: .workspace,
        title: "Export Selected",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.exportSelectedNotes(bearIDs:)",
        backend: "ExportConfig.onlyNoteUUIDs + exportNotes(config:)",
        notes: "Runs scoped export and merges sidecar bindings for selected Bear IDs."
    ),
    B2OUFeatureContract(
        id: "workspace.export_full_scope",
        surface: .workspace,
        title: "Export Full Scope",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.exportAllFromWorkspace()",
        backend: "ExportWatcher.exportNow()",
        notes: "Delegates to the same full export path used by the menu action."
    ),
    B2OUFeatureContract(
        id: "workspace.refresh_bear",
        surface: .workspace,
        title: "Refresh Bear",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.scanAndShowWorkspace()",
        backend: "NoteStore.scan(config:, allowExportFallback: false)",
        notes: "Reloads review data from the configured Bear source only."
    ),
    B2OUFeatureContract(
        id: "workspace.open_preferences",
        surface: .workspace,
        title: "Open Preferences",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.onConfigure()",
        backend: "SettingsPanel + applySettings()",
        notes: "Routes persistent profile edits to the shared settings surface."
    ),
    B2OUFeatureContract(
        id: "workspace.rebuild_state",
        surface: .workspace,
        title: "Rebuild Source Links",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "AppDelegate.rebuildWorkspaceState()",
        backend: "BearCLIClient.listNoteMetadata() + rebuildSyncStatePlan(write:)",
        notes: "Conditionally appears when reviewed notes have missing Bear links and rebuilds .b2ou/state.json with confirmation for risky plans."
    ),
    B2OUFeatureContract(
        id: "workspace.reveal_exported_file",
        surface: .workspace,
        title: "Reveal Exported File",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "Workspace preview overflow menu",
        backend: "NSWorkspace.shared.activateFileViewerSelecting([note.filePath])",
        notes: "Only enabled when the reviewed note already has a real exported file on disk."
    ),
    B2OUFeatureContract(
        id: "settings.check_updates",
        surface: .settings,
        title: "Check for Updates",
        state: .externalLink,
        reachableFromPrimaryUI: true,
        entrypoint: "SettingsPanel about card button",
        backend: "NSWorkspace.shared.open(releasesURL)",
        notes: "External release page only, not an in-app updater."
    ),
    B2OUFeatureContract(
        id: "settings.project_page",
        surface: .settings,
        title: "Project Page",
        state: .externalLink,
        reachableFromPrimaryUI: true,
        entrypoint: "SettingsPanel about card button",
        backend: "NSWorkspace.shared.open(projectURL)",
        notes: "External project homepage only."
    ),
    B2OUFeatureContract(
        id: "dashboard.note_browser",
        surface: .dashboard,
        title: "Open Note Browser",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "showDashboard(store:) -> showNotePreview(store:)",
        backend: "NotePreview window",
        notes: "Dashboard drills into the note browser and filtered review flows."
    ),
    B2OUFeatureContract(
        id: "dashboard.open_exported_file",
        surface: .dashboard,
        title: "Open Exported File",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "NoteOfDayView open editor action",
        backend: "NSWorkspace.shared.open(note.filePath)",
        notes: "Only enabled when the exported file actually exists on disk."
    ),
    B2OUFeatureContract(
        id: "note_browser.open_exported_file",
        surface: .noteBrowser,
        title: "Open Exported File",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "NoteDetailView open editor action",
        backend: "NSWorkspace.shared.open(note.filePath)",
        notes: "Only enabled when the selected exported file exists."
    ),
    B2OUFeatureContract(
        id: "note_browser.reveal_exported_file",
        surface: .noteBrowser,
        title: "Reveal Exported File",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "NoteDetailView reveal Finder action",
        backend: "NSWorkspace.shared.activateFileViewerSelecting([note.filePath])",
        notes: "Only enabled when the selected exported file exists."
    ),
    B2OUFeatureContract(
        id: "note_browser.open_in_bear",
        surface: .noteBrowser,
        title: "Open in Bear",
        state: .implemented,
        reachableFromPrimaryUI: true,
        entrypoint: "NoteDetailView.openInBear(_:)",
        backend: "bear://x-callback-url/open-note?id=...",
        notes: "Requires a sidecar or source-backed Bear ID."
    ),
]

public func primaryUIFeatureContracts() -> [B2OUFeatureContract] {
    b2ouFeatureContracts.filter(\.reachableFromPrimaryUI)
}
