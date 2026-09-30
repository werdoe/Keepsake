import SwiftUI

/// Saves many links, or several accounts' current Instagram stories, in one go.
@MainActor
final class BatchModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case links, stories
        var id: String { rawValue }
        var title: String { self == .links ? "Links" : "Stories" }
    }

    enum Status: Equatable {
        case queued
        case fetching
        case saving(Double)
        case done(Int)
        case skipped(String)
        case failed(String)
    }

    struct Job: Identifiable {
        let id = UUID()
        let input: String
        var title: String
        var status: Status = .queued
    }

    @Published var mode: Mode = .links
    @Published var text = ""
    @Published var skipDuplicates = true
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @Published private(set) var finishedTick = 0

    private var task: Task<Void, Never>?
    private let liveActivity = LiveActivityController()

    /// Links (or story URLs built from usernames) found in the text box.
    var inputs: [String] {
        switch mode {
        case .links:
            var seen = Set<String>()
            return MediaLink.extractURLs(from: text).map(\.absoluteString).filter { seen.insert($0).inserted }
        case .stories:
            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
            var seen = Set<String>()
            return text.components(separatedBy: separators)
                .map { word -> String in
                    var name = word.trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
                    if let url = URL(string: word), url.host?.contains("instagram.com") == true {
                        name = url.pathComponents.filter { $0 != "/" && $0 != "stories" }.first ?? ""
                    }
                    return name
                }
                .filter { MediaLink.isUsername($0) && seen.insert($0.lowercased()).inserted }
                .map { "https://www.instagram.com/stories/\($0)/" }
        }
    }

    var completedCount: Int {
        jobs.filter { if case .done = $0.status { return true } else { return false } }.count
    }

    func start() {
        let inputs = self.inputs
        guard !inputs.isEmpty, !isRunning else { return }
        jobs = inputs.map { Job(input: $0, title: Self.label(for: $0)) }
        isRunning = true
        liveActivity.start(title: "\(inputs.count) \(mode == .stories ? "accounts" : "links")", platform: .instagram, total: inputs.count)

        task = Task {
            for index in jobs.indices {
                if Task.isCancelled { break }
                await run(index)
            }
            let saved = jobs.reduce(0) { total, job in
                if case .done(let n) = job.status { return total + n } else { return total }
            }
            liveActivity.finish(success: saved > 0, message: "Saved \(saved) item\(saved == 1 ? "" : "s")", total: jobs.count)
            isRunning = false
            finishedTick += 1
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ index: Int) async {
        let total = jobs.count
        jobs[index].status = .fetching
        do {
            let bundle = try await MediaFetcher.fetch(jobs[index].input)
            jobs[index].title = "\(bundle.platform.name) · \(bundle.title)"
            if skipDuplicates, let earlier = HistoryStore.shared.previousSave(of: bundle.key) {
                jobs[index].status = .skipped("Saved \(earlier.date.formatted(.relative(presentation: .named)))")
                return
            }
            let result = try await SavePipeline.save(bundle.items, from: bundle, downloader: BackgroundDownloader.shared) { [weak self] p in
                Task { @MainActor in
                    guard let self, self.jobs.indices.contains(index) else { return }
                    self.jobs[index].status = .saving(p.fraction)
                    let overall = (Double(index) + p.fraction) / Double(total)
                    self.liveActivity.update(SaveProgress(completed: index, total: total, fraction: overall,
                                                          phase: .downloading, currentItemID: nil, itemFraction: p.fraction))
                }
            }
            jobs[index].status = .done(result.savedItemIDs.count)
        } catch is CancellationError {
            jobs[index].status = .skipped("Cancelled")
        } catch {
            jobs[index].status = .failed(KeepsakeError.from(error).localizedDescription)
        }
    }

    private static func label(for input: String) -> String {
        guard let url = URL(string: input) else { return input }
        if url.path.contains("/stories/"), let name = url.pathComponents.dropFirst(2).first {
            return "@\(name) · stories"
        }
        return (url.host ?? "") + url.path
    }
}

struct BatchView: View {
    @StateObject private var model = BatchModel()
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(BatchModel.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)

                    Text(model.mode == .links
                         ? "Paste as many links as you like: posts, reels, TikToks, profiles. One per line, or all in one go."
                         : "Type Instagram usernames to save everyone's current stories. Separate them with spaces or new lines.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if model.mode == .stories && !Accounts.isLoggedIn(.instagram) {
                        Label("Stories need you to log in to Instagram in Settings › Accounts.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.text)
                            .focused($editorFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 150)
                            .padding(10)
                        if model.text.isEmpty {
                            Text(model.mode == .links ? "https://…\nhttps://…" : "username1 username2")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(model.isRunning)

                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            Task { @MainActor in
                                let joined = strings.joined(separator: "\n")
                                model.text = model.text.isEmpty ? joined : model.text + "\n" + joined
                            }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                        .tint(Brand.blue)
                        Spacer()
                        Text("\(model.inputs.count) found")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: model.inputs.count)
                    }

                    Toggle("Skip ones I've already saved", isOn: $model.skipDuplicates)
                        .disabled(model.isRunning)

                    if model.isRunning {
                        Button(role: .destructive) { model.cancel() } label: {
                            Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Button {
                            editorFocused = false
                            model.start()
                        } label: {
                            Label("Save \(model.inputs.count == 1 ? "1 item" : "All \(model.inputs.count)")", systemImage: "square.stack.3d.down.right.fill")
                        }
                        .buttonStyle(GradientButtonStyle())
                        .disabled(model.inputs.isEmpty)
                        .opacity(model.inputs.isEmpty ? 0.5 : 1)
                    }

                    if !model.jobs.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(model.jobs) { job in
                                JobRow(job: job)
                                if job.id != model.jobs.last?.id { Divider().padding(.leading, 44) }
                            }
                        }
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(20)
                .animation(.snappy, value: model.jobs.map(\.status))
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Batch Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sensoryFeedback(.success, trigger: model.finishedTick) { _, _ in settings.haptics }
        }
    }
}

private struct JobRow: View {
    let job: BatchModel.Job

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var icon: some View {
        switch job.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .fetching:
            ProgressView()
        case .saving(let p):
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.03, p)).stroke(Brand.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(3)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .skipped:
            Image(systemName: "arrow.uturn.forward.circle.fill").foregroundStyle(.secondary).font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.title3)
        }
    }

    private var detail: String {
        switch job.status {
        case .queued: return "Waiting"
        case .fetching: return "Finding media…"
        case .saving(let p): return "Saving · \(Int(p * 100))%"
        case .done(let n): return "Saved \(n) item\(n == 1 ? "" : "s")"
        case .skipped(let why): return "Skipped · \(why)"
        case .failed(let message): return message
        }
    }
}
