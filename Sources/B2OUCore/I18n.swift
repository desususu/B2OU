// I18n.swift — Internationalization support for B2OU.
//
// Provides translated strings for English and Chinese, with automatic
// system-language detection and runtime switching via the menu bar.

import Foundation

// MARK: - Language Preference Persistence

private let prefKey = "B2OULanguage"

public func readLanguagePreference() -> String? {
    UserDefaults.standard.string(forKey: prefKey)
}

public func writeLanguagePreference(_ lang: String) {
    UserDefaults.standard.set(lang, forKey: prefKey)
}

// MARK: - System Language Detection

public func detectSystemLanguage() -> String {
    let preferred = Locale.preferredLanguages
    if let primary = preferred.first?.lowercased(), primary.hasPrefix("zh") {
        return "zh"
    }
    return "en"
}

// MARK: - Global State

private var currentLang: String = "en"

public func initLanguage() -> String {
    if let saved = readLanguagePreference(), saved == "en" || saved == "zh" {
        currentLang = saved
    } else {
        currentLang = detectSystemLanguage()
    }
    return currentLang
}

public func setLanguage(_ lang: String) {
    currentLang = (lang == "en" || lang == "zh") ? lang : "en"
    writeLanguagePreference(currentLang)
}

public func getLanguage() -> String {
    currentLang
}

public func t(_ key: String) -> String {
    let table = strings[currentLang] ?? strings["en"]!
    return table[key] ?? strings["en"]![key] ?? key
}

// MARK: - String Tables

public let strings: [String: [String: String]] = [
    "en": [
        // Menu items
        "menu.starting": "Starting...",
        "menu.export_now": "Export Now",
        "menu.pause": "Pause",
        "menu.resume": "Resume",
        "menu.open_folder": "Open Export Folder",
        "menu.profile": "Profile",
        "menu.start_at_login": "Start at Login",
        "menu.change_folder": "Change Export Folder...",
        "menu.configure": "Configure Profile...",
        "menu.edit_config": "Edit Config File...",
        "menu.quit": "Quit",
        "menu.language": "Language",
        "menu.setup": "Set Up...",
        "menu.reload": "Reload",
        "menu.no_profile": "No profile loaded",
        "menu.notes_exported": "{count} notes exported",
        "menu.exporting_to": "Exporting to {folder}",
        "menu.last_export": "Last export: {time}",
        "menu.just_now": "just now",
        "menu.min_ago": "{mins} min ago",

        // Language names
        "lang.en": "English",
        "lang.zh": "\u{4e2d}\u{6587}",
        "lang.auto": "Auto (System)",

        // Wizard
        "wizard.welcome_title": "Welcome to B2OU",
        "wizard.welcome_msg": "B2OU keeps your Bear notes automatically backed up as Markdown files.\n\nHow would you like to set it up?",
        "wizard.quick": "Quick Setup (Recommended)",
        "wizard.advanced": "Advanced Setup",
        "wizard.quick_title": "Quick Setup",
        "wizard.quick_msg": "Just pick a folder and you're done.\n\nB2OU will export all your Bear notes as clean Markdown files, automatically keep them up to date, and start at login.",
        "wizard.choose_folder": "Choose Folder",
        "wizard.cancelled_title": "Setup Cancelled",
        "wizard.cancelled_msg": "You can set up later from the menu bar.",
        "wizard.ready": "Ready",
        "wizard.ready_msg": "Your notes are being exported to:\n{path}",
        "wizard.pick_prompt": "Choose where to save your Bear notes:",
        "wizard.pick_advanced": "Choose the export destination folder:",

        // Settings panel
        "settings.title": "B2OU Settings",
        "settings.export_folder": "Export Folder",
        "settings.export_folder_md": "Markdown Folder",
        "settings.change": "Change...",
        "settings.format": "Export Format",
        "settings.format_md": "Markdown (.md)",
        "settings.format_tb": "TextBundle (.textbundle)",
        "settings.format_both": "Both (MD + TB)",
        "settings.export_folder_tb": "TextBundle Folder",
        "settings.folder_not_same": "When exporting both formats, the TextBundle folder must be different from the Markdown folder.",
        "settings.yaml": "YAML Front Matter",
        "settings.tag_folders": "Organize by Tag Folders",
        "settings.hide_tags": "Hide Tags in Notes",
        "settings.auto_start": "Start at Login",
        "settings.naming": "File Naming",
        "settings.naming_title": "title",
        "settings.naming_slug": "slug",
        "settings.naming_date": "date-title",
        "settings.naming_id": "id",
        "settings.on_delete": "When Note Deleted",
        "settings.delete_trash": "trash",
        "settings.delete_remove": "remove",
        "settings.delete_keep": "keep",
        "settings.exclude_tags": "Exclude Tags",
        "settings.exclude_placeholder": "e.g. private, draft, work/internal",
        "settings.exclude_example": "Example: private, draft, work/internal\nNotes with these tags will not be exported.",
        "settings.cancel": "Cancel",
        "settings.apply": "Apply",
        "settings.applied_title": "Settings applied",
        "settings.applied_msg": "Exporting to: {path}",
        "settings.applied_msg_both": "Exporting to:\nMarkdown: {path_md}\nTextBundle: {path_tb}",
        "settings.folder_changed": "Export folder changed",
        "settings.folder_changed_msg": "Now exporting to: {path}",
        "settings.folder_not_found": "Folder not found",
        "settings.folder_not_found_msg": "Export folder does not exist yet:\n{path}\n\nIt will be created on the first export.",
        "settings.folder_tb_missing": "Please choose a TextBundle export folder when exporting both formats.",
        "settings.folder_md_missing": "Please choose a Markdown export folder.",
        "settings.folder_tb_conflict": "Markdown and TextBundle folders must be different.",
        "settings.format_none": "Please select at least one export format.",

        // Scheduled backup
        "settings.backup": "Scheduled Backup",
        "settings.backup_interval": "Backup Interval",
        "settings.backup_off": "Off",
        "settings.backup_30m": "Every 30 minutes",
        "settings.backup_1h": "Every hour",
        "settings.backup_2h": "Every 2 hours",
        "settings.backup_6h": "Every 6 hours",
        "settings.backup_12h": "Every 12 hours",
        "settings.backup_24h": "Every 24 hours",
        "settings.backup_folder": "Backup Folder",
        "settings.backup_default": "(default: .b2ou-backups in export folder)",
        "menu.last_backup": "Last backup: {time}",

        // Help text
        "help.backup_interval": "Periodically create a snapshot of the Bear database as a standalone SQLite file.\n\nBackups are lightweight and run in the background without interfering with exports. Old backups are automatically rotated (up to 24 kept).\n\nThe backup folder is set to .b2ou-backups inside the export folder by default.",
        "help.format": "Markdown (.md): Plain Markdown files with a shared images folder. Best for Obsidian.\n\nTextBundle (.textbundle): Each note is a bundle with embedded images. Best for Ulysses.\n\nBoth: Export to separate Markdown and TextBundle folders.",
        "help.yaml": "Add YAML front matter (title, tags, dates) at the top of each exported note.\n\nUseful for static site generators (Hugo, Jekyll) and Obsidian metadata queries.",
        "help.tag_folders": "Create subfolders based on Bear tags.\n\nFor example, a note tagged #work/meetings will be placed in work/meetings/ folder.\nNotes with multiple tags are copied to each tag folder.",
        "help.hide_tags": "Remove #tag lines from the exported Markdown content.\n\nTags are still preserved in YAML front matter if enabled.",
        "help.naming": "How exported files are named:\n\n\u{2022} title \u{2014} My Note Title.md\n\u{2022} slug \u{2014} my-note-title.md\n\u{2022} date-title \u{2014} 2024-01-15-my-note-title.md\n\u{2022} id \u{2014} 12345678.md (Bear UUID prefix)",
        "help.on_delete": "What happens to exported files when the original Bear note is trashed:\n\n\u{2022} trash \u{2014} Move to .b2ou-trash/ (recoverable)\n\u{2022} remove \u{2014} Delete permanently\n\u{2022} keep \u{2014} Never remove stale files",
        "help.exclude_tags": "Comma-separated list of Bear tags to exclude from export.\n\nExample: private, draft, work/internal\n\nNotes with any of these tags will be skipped entirely.\nNested tags use / as separator (e.g. work/internal).",
        "help.auto_start": "Automatically launch B2OU when you log in to your Mac.\n\nCreates a LaunchAgent that starts the menu-bar app at login.",
        "help.export_folder_md": "The folder where Markdown files will be exported.\n\nChoose any folder \u{2014} a common choice is a folder inside your Obsidian vault or iCloud Drive.",
        "help.export_folder_tb": "TextBundle output folder used when exporting both formats.\n\nIt must be different from the Markdown folder.",
    ],

    "zh": [
        "menu.starting": "\u{542f}\u{52a8}\u{4e2d}...",
        "menu.export_now": "\u{7acb}\u{5373}\u{5bfc}\u{51fa}",
        "menu.pause": "\u{6682}\u{505c}",
        "menu.resume": "\u{7ee7}\u{7eed}",
        "menu.open_folder": "\u{6253}\u{5f00}\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}",
        "menu.profile": "\u{914d}\u{7f6e}\u{6587}\u{4ef6}",
        "menu.start_at_login": "\u{5f00}\u{673a}\u{542f}\u{52a8}",
        "menu.change_folder": "\u{66f4}\u{6539}\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}...",
        "menu.configure": "\u{914d}\u{7f6e}\u{5f53}\u{524d}\u{65b9}\u{6848}...",
        "menu.edit_config": "\u{7f16}\u{8f91}\u{914d}\u{7f6e}\u{6587}\u{4ef6}...",
        "menu.quit": "\u{9000}\u{51fa}",
        "menu.language": "\u{8bed}\u{8a00}",
        "menu.setup": "\u{8bbe}\u{7f6e}...",
        "menu.reload": "\u{91cd}\u{65b0}\u{52a0}\u{8f7d}",
        "menu.no_profile": "\u{672a}\u{52a0}\u{8f7d}\u{914d}\u{7f6e}",
        "menu.notes_exported": "\u{5df2}\u{5bfc}\u{51fa} {count} \u{7bc7}\u{7b14}\u{8bb0}",
        "menu.exporting_to": "\u{5bfc}\u{51fa}\u{5230} {folder}",
        "menu.last_export": "\u{4e0a}\u{6b21}\u{5bfc}\u{51fa}: {time}",
        "menu.just_now": "\u{521a}\u{521a}",
        "menu.min_ago": "{mins} \u{5206}\u{949f}\u{524d}",

        "lang.en": "English",
        "lang.zh": "\u{4e2d}\u{6587}",
        "lang.auto": "\u{81ea}\u{52a8} (\u{7cfb}\u{7edf}\u{8bed}\u{8a00})",

        "wizard.welcome_title": "\u{6b22}\u{8fce}\u{4f7f}\u{7528} B2OU",
        "wizard.welcome_msg": "B2OU \u{53ef}\u{4ee5}\u{81ea}\u{52a8}\u{5c06} Bear \u{7b14}\u{8bb0}\u{5907}\u{4efd}\u{4e3a} Markdown \u{6587}\u{4ef6}\u{3002}\n\n\u{8bf7}\u{9009}\u{62e9}\u{8bbe}\u{7f6e}\u{65b9}\u{5f0f}:",
        "wizard.quick": "\u{5feb}\u{901f}\u{8bbe}\u{7f6e} (\u{63a8}\u{8350})",
        "wizard.advanced": "\u{9ad8}\u{7ea7}\u{8bbe}\u{7f6e}",
        "wizard.quick_title": "\u{5feb}\u{901f}\u{8bbe}\u{7f6e}",
        "wizard.quick_msg": "\u{53ea}\u{9700}\u{9009}\u{62e9}\u{4e00}\u{4e2a}\u{6587}\u{4ef6}\u{5939}\u{5373}\u{53ef}\u{5b8c}\u{6210}\u{3002}\n\nB2OU \u{4f1a}\u{5c06}\u{6240}\u{6709} Bear \u{7b14}\u{8bb0}\u{5bfc}\u{51fa}\u{4e3a} Markdown \u{6587}\u{4ef6}\u{ff0c}\u{5e76}\u{81ea}\u{52a8}\u{4fdd}\u{6301}\u{540c}\u{6b65}\u{3002}",
        "wizard.choose_folder": "\u{9009}\u{62e9}\u{6587}\u{4ef6}\u{5939}",
        "wizard.cancelled_title": "\u{8bbe}\u{7f6e}\u{5df2}\u{53d6}\u{6d88}",
        "wizard.cancelled_msg": "\u{60a8}\u{53ef}\u{4ee5}\u{7a0d}\u{540e}\u{901a}\u{8fc7}\u{83dc}\u{5355}\u{680f}\u{8fdb}\u{884c}\u{8bbe}\u{7f6e}\u{3002}",
        "wizard.ready": "\u{5c31}\u{7eea}",
        "wizard.ready_msg": "\u{7b14}\u{8bb0}\u{6b63}\u{5728}\u{5bfc}\u{51fa}\u{5230}:\n{path}",
        "wizard.pick_prompt": "\u{9009}\u{62e9}\u{4fdd}\u{5b58} Bear \u{7b14}\u{8bb0}\u{7684}\u{4f4d}\u{7f6e}:",
        "wizard.pick_advanced": "\u{9009}\u{62e9}\u{5bfc}\u{51fa}\u{76ee}\u{6807}\u{6587}\u{4ef6}\u{5939}:",

        "settings.title": "B2OU \u{8bbe}\u{7f6e}",
        "settings.export_folder": "\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}",
        "settings.export_folder_md": "Markdown \u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}",
        "settings.change": "\u{66f4}\u{6539}...",
        "settings.format": "\u{5bfc}\u{51fa}\u{683c}\u{5f0f}",
        "settings.format_md": "Markdown (.md)",
        "settings.format_tb": "TextBundle (.textbundle)",
        "settings.format_both": "\u{540c}\u{65f6}\u{5bfc}\u{51fa}\u{ff08}Markdown + TextBundle\u{ff09}",
        "settings.export_folder_tb": "TextBundle \u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}",
        "settings.folder_not_same": "\u{540c}\u{65f6}\u{5bfc}\u{51fa}\u{65f6}\u{ff0c}TextBundle \u{6587}\u{4ef6}\u{5939}\u{5fc5}\u{987b}\u{4e0e} Markdown \u{6587}\u{4ef6}\u{5939}\u{4e0d}\u{540c}\u{3002}",
        "settings.yaml": "YAML \u{5143}\u{6570}\u{636e}",
        "settings.tag_folders": "\u{6309}\u{6807}\u{7b7e}\u{5206}\u{6587}\u{4ef6}\u{5939}",
        "settings.hide_tags": "\u{9690}\u{85cf}\u{7b14}\u{8bb0}\u{4e2d}\u{7684}\u{6807}\u{7b7e}",
        "settings.auto_start": "\u{5f00}\u{673a}\u{542f}\u{52a8}",
        "settings.naming": "\u{6587}\u{4ef6}\u{547d}\u{540d}",
        "settings.naming_title": "\u{6807}\u{9898}",
        "settings.naming_slug": "\u{77ed}\u{6807}\u{8bc6}",
        "settings.naming_date": "\u{65e5}\u{671f}-\u{6807}\u{9898}",
        "settings.naming_id": "ID",
        "settings.on_delete": "\u{7b14}\u{8bb0}\u{5220}\u{9664}\u{65f6}",
        "settings.delete_trash": "\u{79fb}\u{5230}\u{56de}\u{6536}\u{7ad9}",
        "settings.delete_remove": "\u{6c38}\u{4e45}\u{5220}\u{9664}",
        "settings.delete_keep": "\u{4fdd}\u{7559}\u{6587}\u{4ef6}",
        "settings.exclude_tags": "\u{6392}\u{9664}\u{6807}\u{7b7e}",
        "settings.exclude_placeholder": "\u{4f8b}\u{5982}: private, draft, work/internal",
        "settings.exclude_example": "\u{793a}\u{4f8b}: private, draft, work/internal\n\u{5305}\u{542b}\u{8fd9}\u{4e9b}\u{6807}\u{7b7e}\u{7684}\u{7b14}\u{8bb0}\u{5c06}\u{4e0d}\u{4f1a}\u{88ab}\u{5bfc}\u{51fa}\u{3002}",
        "settings.cancel": "\u{53d6}\u{6d88}",
        "settings.apply": "\u{5e94}\u{7528}",
        "settings.applied_title": "\u{8bbe}\u{7f6e}\u{5df2}\u{5e94}\u{7528}",
        "settings.applied_msg": "\u{5bfc}\u{51fa}\u{5230}: {path}",
        "settings.applied_msg_both": "\u{5bfc}\u{51fa}\u{5230}:\nMarkdown: {path_md}\nTextBundle: {path_tb}",
        "settings.folder_changed": "\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}\u{5df2}\u{66f4}\u{6539}",
        "settings.folder_changed_msg": "\u{73b0}\u{5728}\u{5bfc}\u{51fa}\u{5230}: {path}",
        "settings.folder_not_found": "\u{6587}\u{4ef6}\u{5939}\u{672a}\u{627e}\u{5230}",
        "settings.folder_not_found_msg": "\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}\u{5c1a}\u{4e0d}\u{5b58}\u{5728}:\n{path}\n\n\u{5c06}\u{5728}\u{9996}\u{6b21}\u{5bfc}\u{51fa}\u{65f6}\u{81ea}\u{52a8}\u{521b}\u{5efa}\u{3002}",
        "settings.folder_tb_missing": "\u{8bf7}\u{4e3a}\u{201c}\u{540c}\u{65f6}\u{5bfc}\u{51fa}\u{201d}\u{9009}\u{62e9}\u{4e00}\u{4e2a} TextBundle \u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}\u{3002}",
        "settings.folder_md_missing": "\u{8bf7}\u{9009}\u{62e9} Markdown \u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}\u{3002}",
        "settings.folder_tb_conflict": "Markdown \u{548c} TextBundle \u{7684}\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}\u{5fc5}\u{987b}\u{4e0d}\u{540c}\u{3002}",
        "settings.format_none": "\u{8bf7}\u{81f3}\u{5c11}\u{9009}\u{62e9}\u{4e00}\u{79cd}\u{5bfc}\u{51fa}\u{683c}\u{5f0f}\u{3002}",

        "settings.backup": "\u{5b9a}\u{65f6}\u{5907}\u{4efd}",
        "settings.backup_interval": "\u{5907}\u{4efd}\u{95f4}\u{9694}",
        "settings.backup_off": "\u{5173}\u{95ed}",
        "settings.backup_30m": "\u{6bcf} 30 \u{5206}\u{949f}",
        "settings.backup_1h": "\u{6bcf}\u{5c0f}\u{65f6}",
        "settings.backup_2h": "\u{6bcf} 2 \u{5c0f}\u{65f6}",
        "settings.backup_6h": "\u{6bcf} 6 \u{5c0f}\u{65f6}",
        "settings.backup_12h": "\u{6bcf} 12 \u{5c0f}\u{65f6}",
        "settings.backup_24h": "\u{6bcf} 24 \u{5c0f}\u{65f6}",
        "settings.backup_folder": "\u{5907}\u{4efd}\u{6587}\u{4ef6}\u{5939}",
        "settings.backup_default": "(\u{9ed8}\u{8ba4}: \u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}\u{4e2d}\u{7684} .b2ou-backups)",
        "menu.last_backup": "\u{4e0a}\u{6b21}\u{5907}\u{4efd}: {time}",

        "help.backup_interval": "\u{5b9a}\u{671f}\u{5c06} Bear \u{6570}\u{636e}\u{5e93}\u{521b}\u{5efa}\u{4e3a}\u{72ec}\u{7acb}\u{7684} SQLite \u{5feb}\u{7167}\u{6587}\u{4ef6}\u{3002}\n\n\u{5907}\u{4efd}\u{8f7b}\u{91cf}\u{8fd0}\u{884c}\u{ff0c}\u{4e0d}\u{4f1a}\u{5f71}\u{54cd}\u{5bfc}\u{51fa}\u{3002}\u{65e7}\u{5907}\u{4efd}\u{81ea}\u{52a8}\u{8f6e}\u{6362}\u{ff08}\u{6700}\u{591a}\u{4fdd}\u{7559} 24 \u{4efd}\u{ff09}\u{3002}\n\n\u{5907}\u{4efd}\u{6587}\u{4ef6}\u{5939}\u{9ed8}\u{8ba4}\u{4e3a}\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}\u{4e2d}\u{7684} .b2ou-backups\u{3002}",
        "help.format": "Markdown (.md): \u{7eaf} Markdown \u{6587}\u{4ef6}\u{ff0c}\u{56fe}\u{7247}\u{5b58}\u{653e}\u{5728}\u{5171}\u{4eab}\u{6587}\u{4ef6}\u{5939}\u{4e2d}\u{3002}\u{9002}\u{5408} Obsidian\u{3002}\n\nTextBundle (.textbundle): \u{6bcf}\u{7bc7}\u{7b14}\u{8bb0}\u{5305}\u{542b}\u{5185}\u{5d4c}\u{56fe}\u{7247}\u{3002}\u{9002}\u{5408} Ulysses\u{3002}\n\n\u{540c}\u{65f6}\u{5bfc}\u{51fa}: \u{9700}\u{5206}\u{522b}\u{4f7f}\u{7528} Markdown \u{548c} TextBundle \u{7684}\u{4e24}\u{4e2a}\u{6587}\u{4ef6}\u{5939}\u{3002}",
        "help.yaml": "\u{5728}\u{6bcf}\u{7bc7}\u{5bfc}\u{51fa}\u{7b14}\u{8bb0}\u{9876}\u{90e8}\u{6dfb}\u{52a0} YAML \u{5143}\u{6570}\u{636e}\u{ff08}\u{6807}\u{9898}\u{3001}\u{6807}\u{7b7e}\u{3001}\u{65e5}\u{671f}\u{ff09}\u{3002}\n\n\u{9002}\u{7528}\u{4e8e}\u{9759}\u{6001}\u{7f51}\u{7ad9}\u{751f}\u{6210}\u{5668} (Hugo, Jekyll) \u{548c} Obsidian \u{5143}\u{6570}\u{636e}\u{67e5}\u{8be2}\u{3002}",
        "help.tag_folders": "\u{6839}\u{636e} Bear \u{6807}\u{7b7e}\u{521b}\u{5efa}\u{5b50}\u{6587}\u{4ef6}\u{5939}\u{3002}\n\n\u{4f8b}\u{5982}\u{ff0c}\u{6807}\u{8bb0}\u{4e3a} #work/meetings \u{7684}\u{7b14}\u{8bb0}\u{4f1a}\u{653e}\u{5728} work/meetings/ \u{6587}\u{4ef6}\u{5939}\u{4e2d}\u{3002}\n\u{6709}\u{591a}\u{4e2a}\u{6807}\u{7b7e}\u{7684}\u{7b14}\u{8bb0}\u{4f1a}\u{590d}\u{5236}\u{5230}\u{6bcf}\u{4e2a}\u{6807}\u{7b7e}\u{6587}\u{4ef6}\u{5939}\u{3002}",
        "help.hide_tags": "\u{4ece}\u{5bfc}\u{51fa}\u{7684} Markdown \u{5185}\u{5bb9}\u{4e2d}\u{79fb}\u{9664} #\u{6807}\u{7b7e}\u{3002}\n\n\u{5982}\u{679c}\u{542f}\u{7528}\u{4e86} YAML \u{5143}\u{6570}\u{636e}\u{ff0c}\u{6807}\u{7b7e}\u{4ecd}\u{4f1a}\u{4fdd}\u{7559}\u{5728}\u{5143}\u{6570}\u{636e}\u{4e2d}\u{3002}",
        "help.naming": "\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{7684}\u{547d}\u{540d}\u{65b9}\u{5f0f}:\n\n\u{2022} \u{6807}\u{9898} \u{2014} \u{6211}\u{7684}\u{7b14}\u{8bb0}.md\n\u{2022} \u{77ed}\u{6807}\u{8bc6} \u{2014} my-note-title.md\n\u{2022} \u{65e5}\u{671f}-\u{6807}\u{9898} \u{2014} 2024-01-15-my-note-title.md\n\u{2022} ID \u{2014} 12345678.md (Bear UUID \u{524d}\u{7f00})",
        "help.on_delete": "\u{5f53} Bear \u{4e2d}\u{7684}\u{7b14}\u{8bb0}\u{88ab}\u{5220}\u{9664}\u{65f6}\u{ff0c}\u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{7684}\u{5904}\u{7406}\u{65b9}\u{5f0f}:\n\n\u{2022} \u{56de}\u{6536}\u{7ad9} \u{2014} \u{79fb}\u{5230} .b2ou-trash/\u{ff08}\u{53ef}\u{6062}\u{590d}\u{ff09}\n\u{2022} \u{6c38}\u{4e45}\u{5220}\u{9664} \u{2014} \u{5f7b}\u{5e95}\u{5220}\u{9664}\n\u{2022} \u{4fdd}\u{7559} \u{2014} \u{4e0d}\u{5220}\u{9664}\u{65e7}\u{6587}\u{4ef6}",
        "help.exclude_tags": "\u{7528}\u{9017}\u{53f7}\u{5206}\u{9694}\u{7684} Bear \u{6807}\u{7b7e}\u{5217}\u{8868}\u{ff0c}\u{8fd9}\u{4e9b}\u{6807}\u{7b7e}\u{7684}\u{7b14}\u{8bb0}\u{4e0d}\u{4f1a}\u{88ab}\u{5bfc}\u{51fa}\u{3002}\n\n\u{793a}\u{4f8b}: private, draft, work/internal\n\n\u{5305}\u{542b}\u{4efb}\u{4f55}\u{8fd9}\u{4e9b}\u{6807}\u{7b7e}\u{7684}\u{7b14}\u{8bb0}\u{5c06}\u{88ab}\u{8df3}\u{8fc7}\u{3002}\n\u{5d4c}\u{5957}\u{6807}\u{7b7e}\u{4f7f}\u{7528} / \u{5206}\u{9694}\u{ff08}\u{4f8b}\u{5982} work/internal\u{ff09}\u{3002}",
        "help.auto_start": "\u{767b}\u{5f55} Mac \u{65f6}\u{81ea}\u{52a8}\u{542f}\u{52a8} B2OU\u{3002}\n\n\u{4f1a}\u{521b}\u{5efa}\u{4e00}\u{4e2a} LaunchAgent\u{ff0c}\u{5728}\u{767b}\u{5f55}\u{65f6}\u{542f}\u{52a8}\u{83dc}\u{5355}\u{680f}\u{5e94}\u{7528}\u{3002}",
        "help.export_folder_md": "\u{5bfc}\u{51fa} Markdown \u{7b14}\u{8bb0}\u{7684}\u{76ee}\u{6807}\u{6587}\u{4ef6}\u{5939}\u{3002}\n\n\u{53ef}\u{4ee5}\u{9009}\u{62e9}\u{4efb}\u{610f}\u{6587}\u{4ef6}\u{5939}\u{ff0c}\u{5e38}\u{89c1}\u{9009}\u{62e9}\u{662f} Obsidian \u{4fdd}\u{5e93}\u{6216} iCloud Drive \u{4e2d}\u{7684}\u{6587}\u{4ef6}\u{5939}\u{3002}",
        "help.export_folder_tb": "\u{5f53}\u{9009}\u{62e9}\u{201c}\u{540c}\u{65f6}\u{5bfc}\u{51fa}\u{201d}\u{65f6}\u{ff0c}TextBundle \u{7684}\u{5bfc}\u{51fa}\u{76ee}\u{5f55}\u{3002}\n\n\u{5fc5}\u{987b}\u{4e0e} Markdown \u{5bfc}\u{51fa}\u{6587}\u{4ef6}\u{5939}\u{4e0d}\u{540c}\u{3002}",
    ],
]
