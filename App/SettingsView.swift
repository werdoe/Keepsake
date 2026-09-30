import ActivityKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @ObservedObject private var network = NetworkMonitor.shared
    @Binding var showAccounts: Bool

    @State private var loggedIn = InstagramExtractor.isLoggedIn
    @State private var confirmClear = false

    private var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(QualityPreference.allCases) { q in Text(q.title).tag(q) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    Toggle(isOn: $settings.wifiOnly) {
                        settingLabel("Wi-Fi only", "wifi", .blue)
                    }
                    Toggle(isOn: $settings.saveToAlbum) {
                        settingLabel("Save into “Keepsake” album", "rectangle.stack.badge.plus", .indigo)
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.quality.detail)
                        Label(network.label, systemImage: network.symbol)
                            .foregroundStyle(settings.wifiOnly && network.kind == .cellular ? .orange : .secondary)
                        if settings.saveToAlbum {
                            Text("Keeping saves in an album needs full Photos access. If you allow only “Add Photos”, they still save to Recents.")
                        }
                    }
                }

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

                Section {
                    Toggle(isOn: $settings.liveActivities) {
                        settingLabel("Progress in Dynamic Island", "capsule.fill", .purple)
                    }
                } header: {
                    Text("Live Activity")
                } footer: {
                    if !activitiesEnabled {
                        Text("Live Activities are turned off for Keepsake in iOS Settings › Keepsake.")
                    } else {
                        Text("Shows download progress in the Dynamic Island and on the Lock Screen when you leave the app.")
                    }
                }

                Section {
                    Button {
                        if loggedIn {
                            Task {
                                await InstagramSession.logOut()
                                withAnimation { loggedIn = InstagramExtractor.isLoggedIn }
                            }
                        } else {
                            showAccounts = true
                        }
                    } label: {
                        HStack {
                            settingLabel("Instagram", Platform.instagram.symbol, Platform.instagram.tint)
                            Spacer()
                            Text(loggedIn ? "Log Out" : "Log In")
                                .foregroundStyle(loggedIn ? .red : Brand.blue)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Only needed for Instagram stories, highlights and private accounts you follow. Threads and Facebook work without logging in. Consider a spare account: Instagram may flag accounts that download a lot.")
                }

                Section("General") {
                    Toggle(isOn: $settings.haptics) {
                        settingLabel("Haptics", "hand.tap.fill", .pink)
                    }
                    Toggle(isOn: $settings.keepHistory) {
                        settingLabel("Keep a Library of saves", "clock.arrow.circlepath", .green)
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        settingLabel("Clear Library", "trash", .red)
                    }
                    .disabled(history.entries.isEmpty)
                    Button {
                        settings.hasOnboarded = false
                    } label: {
                        settingLabel("Show Welcome Again", "sparkles", .yellow)
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    NavigationLink {
                        SupportedLinksView()
                    } label: {
                        settingLabel("Supported Links", "link", .gray)
                    }
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
            .navigationTitle("Settings")
            .confirmationDialog("Clear your Library?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Library", role: .destructive) { history.clear() }
            } message: {
                Text("Your photos and videos stay in Photos.")
            }
            .onChange(of: showAccounts) { _, showing in
                if !showing { loggedIn = InstagramExtractor.isLoggedIn }
            }
            .onAppear { loggedIn = InstagramExtractor.isLoggedIn }
        }
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

// MARK: - Share sheet setup guide

struct ShareSetupView: View {
    @State private var highlight = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                shareSheetMock
                VStack(alignment: .leading, spacing: 16) {
                    guideStep(1, "In Instagram, Threads or Facebook, tap Share on a post, reel or story.")
                    guideStep(2, "Choose “Share to…” or “More” to open the iOS share sheet.")
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
                Text("Facebook stories and private posts aren't available to Keepsake, because Facebook only shows them to its own app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Supported Links")
    }

    private func example(for platform: Platform) -> String {
        switch platform {
        case .instagram: return "instagram.com/p/…  /reel/…  /stories/…"
        case .threads: return "threads.com/@user/post/…"
        case .facebook: return "facebook.com/reel/…  /watch?v=…  fb.watch/…"
        }
    }
}
