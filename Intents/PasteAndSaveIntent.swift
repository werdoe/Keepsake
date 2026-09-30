import AppIntents
import Foundation

/// "Paste & Save": opens Keepsake and saves the link on your clipboard.
/// Used by the home screen widget, the Control Center control, Shortcuts and the Action button.
struct PasteAndSaveIntent: AppIntent {
    static var title: LocalizedStringResource = "Paste & Save"
    static var description = IntentDescription("Opens Keepsake and saves the link on your clipboard.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // The app picks this up when it becomes active (reading the clipboard needs the app in front).
        AppGroup.defaults.set(Date(), forKey: "pendingPasteSave")
        return .result()
    }
}
