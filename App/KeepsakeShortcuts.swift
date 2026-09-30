import AppIntents

/// Siri / Shortcuts / Action button phrases.
struct KeepsakeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PasteAndSaveIntent(),
                    phrases: ["Save my clipboard with \(.applicationName)", "\(.applicationName) paste and save"],
                    shortTitle: "Paste & Save",
                    systemImageName: "arrow.down.circle.fill")
    }
}
