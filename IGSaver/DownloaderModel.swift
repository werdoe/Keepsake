import Foundation
import SwiftUI

@MainActor
final class DownloaderModel: ObservableObject {
    enum SaveState {
        case saving
        case saved
        case failed(String)
    }

    @Published var linkText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var result: FetchResult?
    @Published var saveStates: [UUID: SaveState] = [:]
    @Published var isLoggedIn = InstagramClient.shared.isLoggedIn
    @Published var isSavingAll = false

    private var fetchTask: Task<Void, Never>?

    func refreshLoginState() async {
        await InstagramSession.syncFromWebView()
        isLoggedIn = InstagramClient.shared.isLoggedIn
    }

    func logOut() async {
        await InstagramSession.logOut()
        isLoggedIn = InstagramClient.shared.isLoggedIn
    }

    func paste(_ text: String) {
        linkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        fetch()
    }

    func fetch() {
        fetchTask?.cancel()
        errorMessage = nil
        guard let link = InstagramLink.parse(linkText) else {
            result = nil
            errorMessage = linkText.isEmpty ? nil : IGError.badLink.errorDescription
            return
        }
        isLoading = true
        result = nil
        saveStates = [:]
        fetchTask = Task {
            do {
                let fetched = try await InstagramClient.shared.fetch(link)
                guard !Task.isCancelled else { return }
                result = fetched
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }

    func clear() {
        fetchTask?.cancel()
        linkText = ""
        result = nil
        errorMessage = nil
        saveStates = [:]
        isLoading = false
    }

    func save(_ item: MediaItem) async {
        if case .saving = saveStates[item.id] { return }
        if case .saved = saveStates[item.id] { return }
        saveStates[item.id] = .saving
        do {
            try await PhotoSaver.save(item)
            saveStates[item.id] = .saved
        } catch {
            saveStates[item.id] = .failed(error.localizedDescription)
        }
    }

    func saveAll() async {
        guard let items = result?.items else { return }
        isSavingAll = true
        // One at a time keeps them in order in Photos and avoids hammering the CDN.
        for item in items {
            await save(item)
        }
        isSavingAll = false
    }

    var savedCount: Int {
        saveStates.values.filter { if case .saved = $0 { return true } else { return false } }.count
    }
}
