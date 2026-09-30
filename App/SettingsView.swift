import ActivityKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var model: SaveModel
    @ObservedObject private var network = NetworkMonitor.shared
    @Binding var loginPlatform: Platform?

    @State private var loggedIn: Set<Platform> = []
    @State private var confirmClear = false
    @State private var backupURL: URL?
    @State private var showImporter = false

    private var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var body: some View {
        NavigationStack {
            Form {
                downloadsSection
                photoInfoSection
                shareSection
                liveActivitySection
                accountsSection
                privacySection
                librarySection
                aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear your Library?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Library", role: .destructive) { history.clear() }
            } message: {
                Text("Your photos and videos stay where they were saved.")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do {
                        let added = try history.importBackup(from: url)
                        model.show(added == 0 ? "Nothing new in that backup" : "Restored \(added) save\(added == 1 ? "" : "s")")
                    } catch {
                        model.show("That file isn't a Keepsake Library backup.")
                    }
                case .failure:
                    break
                }
            }
            .onChange(of: loginPlatform) { _, platform in
                if platform == nil { refreshLogins() }
            }
            .onAppear { refreshLogins() }
        }
    }

    // MARK: - Sections

    private var downloadsSection: some View {
        Section {
            Picker("Quality", selection: $settings.quality) {
                ForEach(QualityPreference.allCases) { q in Text(q.title).tag(q) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Picker(selection: $settings.destination) {
                ForEach(SaveDestination.allCases) { d in Text(d.title).tag(d) }
            } label: {
                settingLabel("Save to", "tray.and.arrow.down.fill", .teal)
            }

            Toggle(isOn: $settings.wifiOnly) {
                settingLabel("Wi-Fi only", "wifi", .blue)
            }
            if settings.destination.includesPhotos {
                Toggle(isOn: $settings.saveToAlbum) {
                    settingLabel("Also add to a “Keepsake” album", "rectangle.stack.badge.plus", .indigo)
                }
                if settings.saveToAlbum {
                    Toggle(isOn: $settings.albumPerAccount) {
                        settingLabel("One album per account", "person.crop.rectangle.stack.fill", .purple)
                    }
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(settings.quality.detail)
                Text(settings.destination.detail)
                Label(network.label, systemImage: network.symbol)
                    .foregroundStyle(settings.wifiOnly && network.kind == .cellular ? .orange : .secondary)
                if settings.destination.includesPhotos {
                    Text(settings.albumPerAccount && settings.saveToAlbum
                         ? "Everything saved to Photos appears in Recents, and also in an album named after the account (e.g. “@username”) inside a Keepsake folder in Photos › Albums. Needs full Photos access."
                         : "Everything saved to Photos appears in Recents. The album is an extra: it also groups Keepsake saves in one place (Photos › Albums › Keepsake). It needs full Photos access.")
                }
            }
        }
    }

    private var photoInfoSection: some View {
        Section {
            Toggle(isOn: $settings.embedCaption) {
                settingLabel("Add caption & link to photos", "text.quote", .orange)
            }
            Toggle(isOn: $settings.keepOriginalDate) {
                settingLabel("Use the post's date", "calendar", .red)
            }
        } header: {
            Text("Photo Info")
        } footer: {
            Text("The caption and original link are written into each photo's details. With “Use the post's date”, saves sit in Photos at the date they were posted, not the day you saved them.")
        }
    }

    private var shareSection: some View {
        Section {
            Toggle(isOn: $settings.shareAutoSave) {
                settingLabel("Save automatically", "bolt.fill", .orange)
            }
            NavigationLink {
                ShareSetupView()
            } label: {
                settingLabel("Add Keepsake to the share sheet", "square.and.arrow.up", .teal)
            }
        } header: {
            Text("Share Sheet")
        } footer: {
            Text(settings.shareAutoSave
                 ? "Sharing a link to Keepsake saves everything right away."
                 : "Sharing a link to Keepsake shows a preview first.")
        }
    }

    private var liveActivitySection: some View {
        Section {
            Toggle(isOn: $settings.liveActivities) {
                settingLabel("Progress in Dynamic Island", "capsule.fill", .purple)
            }
        } header: {
            Text("Live Activity")
        } footer: {
            Text(activitiesEnabled
                 ? "Shows download progress in the Dynamic Island and on the Lock Screen. Downloads keep going when you leave the app."
                 : "Live Activities are turned off for Keepsake in iOS Settings › Keepsake.")
        }
    }

    private var accountsSection: some View {
        Section {
            ForEach([Platform.instagram, .threads, .facebook]) { platform in
                Button {
                    if loggedIn.contains(platform) {
                        Task {
                            await AccountSession.logOut(platform)
                            withAnimation { refreshLogins() }
                        }
                    } else {
                        loginPlatform = platform
                    }
                } label: {
                    HStack {
                        settingLabel(platform.name, platform.symbol, platform.tint == .primary ? .gray : platform.tint)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(loggedIn.contains(platform) ? "Log Out" : "Log In")
                                .foregroundStyle(loggedIn.contains(platform) ? .red : Brand.blue)
                            Text(platform.loginHelp)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Optional. Public posts and TikTok work without logging in. Logging in lets Keepsake open private and friends-only posts the way the app would. Consider spare accounts: platforms may flag accounts that download a lot.")
        }
    }

    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.lockLibrary },
                set: { newValue in
                    // Confirm it's you before turning the lock on or off.
                    Task {
                        if await LibraryLock.authenticate(reason: newValue ? "Lock your Library" : "Unlock your Library") {
                            settings.lockLibrary = newValue
                        }
                    }
                })) {
                settingLabel("Lock Library with \(LibraryLock.biometryName)", LibraryLock.biometrySymbol, .green)
            }
            Toggle(isOn: $settings.haptics) {
                settingLabel("Haptics", "hand.tap.fill", .pink)
            }
        } header: {
            Text("Privacy & Feel")
        }
    }

    private var librarySection: some View {
        Section {
            Toggle(isOn: $settings.keepHistory) {
                settingLabel("Keep a Library of saves", "clock.arrow.circlepath", .green)
            }
            Button {
                backupURL = try? history.exportBackup()
            } label: {
                settingLabel("Back Up Library", "externaldrive.fill.badge.icloud", .blue)
            }
            .foregroundStyle(.primary)
            .disabled(history.entries.isEmpty)
            if let backupURL {
                ShareLink(item: backupURL) {
                    Label("Save or Send Backup…", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                showImporter = true
            } label: {
                settingLabel("Restore from Backup", "arrow.down.doc.fill", .indigo)
            }
            .foregroundStyle(.primary)
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                settingLabel("Clear Library", "trash", .red)
            }
            .disabled(history.entries.isEmpty)
        } header: {
            Text("Library")
        } footer: {
            Text("A backup is one file with your Library and thumbnails. Keep it in iCloud Drive, or restore it on another iPhone. Automatic iCloud sync isn't possible for sideloaded apps.")
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                SupportedLinksView()
            } label: {
                settingLabel("Supported Links", "link", .gray)
            }
            Button {
                settings.hasOnboarded = false
            } label: {
                settingLabel("Show Welcome Again", "sparkles", .yellow)
            }
            .foregroundStyle(.primary)
            HStack {
                settingLabel("Version", "info.circle", .gray)
                Spacer()
                Text(appVersion).foregroundStyle(.secondary)
            }
        } header: {
            Text("About")
        } footer: {
            Text("Keepsake is for personal use. Only save what you have the right to keep, and ask before reposting other people's work.")
                .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func refreshLogins() {
        loggedIn = Set(Platform.allCases.filter { Accounts.isLoggedIn($0) })
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func settingLabel(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

// MARK: - Face ID / passcode

enum LibraryLock {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Passcode"
        }
    }

    static var biometrySymbol: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }
}

// MARK: - Share sheet setup guide

struct ShareSetupView: View {
    @State private var highlight = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                shareSheetMock
                VStack(alignment: .leading, spacing: 16) {
                    guideStep(1, "In Instagram, Threads, Facebook or TikTok, tap Share on a post, reel, video or story.")
                    guideStep(2, "Choose “Share to…”, “More” or “Other” to open the iOS share sheet.")
                    guideStep(3, "Scroll the row of apps to the end and tap More.")
                    guideStep(4, "Tap Edit, add Keepsake to Favourites and drag it near the top.")
                    guideStep(5, "Next time, just tap Keepsake. It saves on its own.")
                }
                .padding(20)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Share Sheet")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { highlight = true }
    }

    private var shareSheetMock: some View {
        VStack(spacing: 14) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 36, height: 5)
            HStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { i in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill([Color.green, Color.blue, Color.orange][i].gradient)
                            .frame(width: 58, height: 58)
                        Capsule().fill(.secondary.opacity(0.3)).frame(width: 40, height: 6)
                    }
                    .opacity(0.5)
                }
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Brand.gradient)
                            .frame(width: 58, height: 58)
                        KeepsakeMark(size: 40, monochrome: true)
                    }
                    .scaleEffect(highlight ? 1.08 : 1)
                    .shadow(color: Brand.blue.opacity(highlight ? 0.5 : 0), radius: 12)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: highlight)
                    Text("Keepsake").font(.caption2.weight(.semibold))
                }
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func guideStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Brand.gradient, in: Circle())
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}

struct SupportedLinksView: View {
    var body: some View {
        List {
            ForEach(Platform.allCases) { platform in
                Section {
                    Text(platform.supportedKinds)
                    Text(example(for: platform))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                } header: {
                    Label(platform.name, systemImage: platform.symbol)
                }
            }
            Section {
                Text("Profile links save the latest posts. Share links (…/share/…) are followed automatically. Private accounts need you to log in and follow them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Supported Links")
    }

    private func example(for platform: Platform) -> String {
        switch platform {
        case .instagram: return "instagram.com/p/…  /reel/…  /stories/…  /username"
        case .threads: return "threads.com/@user/post/…  /share/…  /@user"
        case .facebook: return "facebook.com/reel/…  /watch?v=…  /share/…  fb.watch/…"
        case .tiktok: return "tiktok.com/@user/video/…  vm.tiktok.com/…"
        }
    }
}
