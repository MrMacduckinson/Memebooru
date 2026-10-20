import Foundation
import Observation
import SwiftUI
import AVFoundation
import VideoToolbox
import MemebooruCore
import MemebooruPlatformApple

/// UI tests launch the app with `-uiTestCollection <path>` (Debug builds only): it opens that collection,
/// remembers nothing (preferences go to a throwaway domain) and stays off the network.
enum UITesting {
    static let collection: URL? = {
        #if DEBUG
        UserDefaults.standard.string(forKey: "uiTestCollection").map { URL(fileURLWithPath: $0) }
        #else
        nil
        #endif
    }()
    static var active: Bool { collection != nil }
}

/// Where the app keeps its preferences: the user's own, or — under UI tests — a fresh set each launch.
enum AppDefaults {
    nonisolated(unsafe) static let store: UserDefaults = {
        guard UITesting.active else { return .standard }
        let name = "dev.mrmacduckinson.memebooru.uitest-prefs"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }()
}

/// App-wide state: the open collection, search results, staging, thumbnails.
@Observable @MainActor
final class Library {
    private(set) var collection: Collection?
    private(set) var staging: StagingArea?
    /// Mac: ffmpeg/ffprobe ship inside the app (Contents/Helpers), Homebrew's are the fallback.
    /// iOS: FFmpeg is linked into the app and runs in-process.
    let platform: Platform = {
        var p = PlatformApple.make(ffmpegDirs: [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")])
        #if os(iOS) && canImport(MBFFmpeg)
        p.transcoder = FFmpegTranscoder(runner: InProcessFFmpegRunner())
        #endif
        return p
    }()
    let sync = SyncController()
    var analyzer: MediaAnalyzer { MediaAnalyzer(platform: platform) }

    // search
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    private(set) var results: [Meme] = []
    private(set) var nextCursor: MemeCursor?
    private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?

    // staging / dedup
    private(set) var stagedItems: [StagedItem] = [] { didSet { shownStagedCache = nil } }
    /// Staging shows one kind (thousands of imported tweets bury everything else) and/or matching words.
    var stagingKind: MemeKind? = AppDefaults.store.string(forKey: "stagingKind").flatMap(MemeKind.init(rawValue:)) {
        didSet { AppDefaults.store.set(stagingKind?.rawValue, forKey: "stagingKind") }
    }
    var stagingFilter: String = AppDefaults.store.string(forKey: "stagingFilter") ?? "" {
        didSet { AppDefaults.store.set(stagingFilter, forKey: "stagingFilter") }
    }
    /// Staging as a grid of thumbnails like Posts (true) or as a list of rows with editors.
    var stagingGrid: Bool = AppDefaults.store.object(forKey: "stagingGrid") == nil || AppDefaults.store.bool(forKey: "stagingGrid") {
        didSet { AppDefaults.store.set(stagingGrid, forKey: "stagingGrid") }
    }
    /// The staged item open on its own page (like a post's page), if any.
    var openStaged: String?
    /// Staging grid in selection mode (to combine pictures, or commit / discard several at once);
    /// the chosen items in the order they were picked (the order they're combined in).
    var stagingSelecting = false { didSet { if !stagingSelecting { stagingSelection = [] } } }
    var stagingSelection: [String] = []
    /// The combined-picture editor, when open.
    var compositeEditor: CompositeTarget?
    /// The crop / trim editor, when open.
    var editTarget: EditTarget?
    /// Pictures added through "Добавить › Коллаж…" go straight into the combined-picture editor.
    var presentCombineImporter = false
    private(set) var duplicateClusters: [DuplicateCluster] = []
    private(set) var tags: [TagRowModel] = []
    internal(set) var busy: String?          // progress label
    private(set) var busyProgress = 0       // items done so far (for live count)
    private(set) var busyCancellable = false
    private var activeTask: Task<Void, Never>?
    private var wayback: WaybackWorker?
    internal(set) var lastUndoLabel: String?
    private(set) var waybackPending = 0
    /// Set while archive.org is refusing (429s): when the next try is due.
    private(set) var waybackRetryAt: Date?
    var waybackEnabled: Bool = AppDefaults.store.object(forKey: "waybackEnabled") as? Bool ?? true {
        didSet { AppDefaults.store.set(waybackEnabled, forKey: "waybackEnabled") }
    }
    var errorMessage: String?
    /// One-line information strip (e.g. "2 files are in uncommon formats"); `noticeAction` opens what it's about.
    var notice: String?
    var noticeAction: Section?
    /// Every picture made from a media file (thumbnails, posters, frames) — see `MediaLoader`.
    let loader = MediaLoader()
    /// Bumped when tweet chains change (a quote or parent loaded), so open cards rebuild.
    var threadVersion = 0
    /// Bumped whenever the staged list is reloaded (chains of staged tweets are read from it).
    private(set) var stagingVersion = 0
    /// Videos being turned into playable previews right now (sha256s).
    private(set) var previewsInFlight: Set<String> = []
    private(set) var previewsReady = 0

    func cancelActiveImport() { activeTask?.cancel(); busy = "Останавливаем…" }

    // navigation
    var selection: MemeID?
    var section: Section = .gallery
    /// Stack of open post-detail views, presented as an interactive overlay (browser-style back-swipe).
    var detailStack: [MemeID] = []
    /// Bumped to request an animated pop of the top detail; the navigator runs the animation then removes it.
    private(set) var popToken = 0
    var wantSearchFocus = false
    var zoomIndex: Int = AppDefaults.store.object(forKey: "zoomIndex") as? Int ?? 3 {
        didSet { AppDefaults.store.set(zoomIndex, forKey: "zoomIndex") }
    }
    var zoom: CGFloat { Theme.zoomSteps[max(0, min(Theme.zoomSteps.count - 1, zoomIndex))] }
    func zoomIn() { zoomIndex = min(Theme.zoomSteps.count - 1, zoomIndex + 1) }
    func zoomOut() { zoomIndex = max(0, zoomIndex - 1) }
    func zoomReset() { zoomIndex = 3 }
    var presentFileImporter = false
    var presentCollectionPicker = false
    var presentXLogin = false
    // Loaded lazily on first x.com use, never at launch — reading the keychain eagerly pops a password
    // prompt every launch under ad-hoc dev signing (the app identity changes each build).
    private(set) var xSession: XSession?
    private var xSessionLoaded = false
    var xLoggedIn: Bool { xSession != nil }
    func loadXSessionIfNeeded() { if !xSessionLoaded { xSession = XKeychain.load(); xSessionLoaded = true } }

    enum Section: Hashable { case gallery, staging, duplicates, tags, sync, history }

    // Caches filled while views draw: not observed, or every fill would redraw every view.
    @ObservationIgnored private var aspectCache: [MemeID: CGFloat] = [:]
    @ObservationIgnored var extrasCache: [String: [StagedExtra]] = [:]
    @ObservationIgnored private var committing: Set<String> = []
    @ObservationIgnored private var shownStagedCache: (kind: MemeKind?, filter: String, items: [StagedItem])?

    // MARK: - Open

    func openLastOrDefault() {
        // Unit tests run inside the app: they open their own throwaway collections, never the real one.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        defer { applyLaunchArguments() }
        // UI tests: their own throwaway collection, never remembered as the one to open next time.
        if let url = UITesting.collection {
            // …and never the user's own, even if a test is pointed at it by mistake.
            let own = [UserDefaults.standard.string(forKey: "collectionPath"), SharedCollection.url?.path].compactMap { $0 }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if own.contains(url.standardizedFileURL.path) { errorMessage = "UI tests can't open your own collection."; return }
            open(url, remember: false); return
        }
        #if os(iOS)
        // iOS: always the App Group collection, so the Share Extension writes to the same place.
        if let url = SharedCollection.url { open(url); return }
        #endif
        if let path = AppDefaults.store.string(forKey: "collectionPath"), Collection.exists(at: URL(fileURLWithPath: path)) {
            open(URL(fileURLWithPath: path)); return
        }
        let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Memebooru/Default.memebooru")
        open(SharedCollection.url ?? fallback)
    }

    /// `remember`: open this one again at the next launch.
    func open(_ url: URL, remember: Bool = true) {
        SharedCollection.shareMachineID()
        do {
            let c = try Collection.openOrCreate(at: url)
            if c.deviceName == ProcessInfo.processInfo.hostName {
                #if os(iOS)
                try? c.renameDevice(UIDevice.current.name)
                #else
                if let n = Host.current().localizedName { try? c.renameDevice(n) }
                #endif
            }
            collection = c
            staging = StagingArea(collection: c, analyzer: analyzer)
            if remember { AppDefaults.store.set(url.path, forKey: "collectionPath") }
            loader.forgetAll()
            aspectCache = [:]
            reloadAll()
            if !UITesting.active { sync.attach(c) }   // UI tests stay off the network
            c.staging.pruneTrash()
            refreshUndo()
            startWayback()
            fillStagedMediaSizes()
        } catch { errorMessage = "\(error)" }
    }

    /// Staged tweets from before media sizes were kept get them once, in the background.
    /// Posts' files saved without a size are measured, so they never change shape on screen.
    private func fillStagedMediaSizes() {
        guard let staging, let c = collection else { return }
        let analyzer = analyzer
        Task {
            let n = await MediaLoader.run { (try? staging.fillMediaSizes()) ?? 0 }
            if n > 0 { reloadStaging() }
            let m = await MediaLoader.run { (try? c.fillMissingMediaSizes(analyzer: analyzer)) ?? 0 }
            if m > 0 { aspectCache = [:]; runSearch(reset: true) }
        }
    }

    /// Debug helpers for screenshots: `-section duplicates -scan`, `-query "stalin"`, `-open <memeIDPrefix>`.
    private func applyLaunchArguments() {
        let d = UserDefaults.standard
        #if DEBUG
        if let dir = d.string(forKey: "selfTestDir") { runMediaSelfTest(URL(fileURLWithPath: dir)) }
        // -commitStaged <file name>: convert + keep original, then open the new post (UI checks without taps).
        if let name = d.string(forKey: "commitStaged"), let staging, let item = stagedItems.first(where: { $0.originalName == name }) {
            Task.detached {
                let meme = try? staging.commit(item.id, convert: true, keepOriginal: true)
                await MainActor.run {
                    self.reloadStaging(); self.runSearch(reset: true); self.reloadTags()
                    if let meme { self.detailStack = [meme.id] }
                }
            }
        }
        #endif
        if let s = d.string(forKey: "section") {
            switch s { case "staging": section = .staging; case "duplicates": section = .duplicates; case "tags": section = .tags; case "sync": section = .sync; case "history": section = .history; default: break }
        }
        if let q = d.string(forKey: "query") { query = q }
        if d.bool(forKey: "focusSearch") { wantSearchFocus = true }
        if d.bool(forKey: "scan") { scanDuplicates() }
        if let code = d.string(forKey: "syncCode") { sync.listener?.setCode(code); sync.refresh() }
        #if DEBUG
        // -stagingSelect <n>: the grid choosing its first n pictures; -combineFirst <n>: the editor on them.
        let pictures = stagedItems.filter(Library.combinable)
        if d.integer(forKey: "stagingSelect") > 0 {
            section = .staging; stagingSelecting = true; stagingSelection = pictures.prefix(d.integer(forKey: "stagingSelect")).map(\.id)
        }
        // -editFirst image|video|audio|gif: the crop / trim editor on the first staged item of that kind.
        if let k = d.string(forKey: "editFirst").flatMap(MemeKind.init(rawValue:)), let item = stagedItems.first(where: { $0.kind == k }) {
            section = .staging; editTarget = .staged(item.id)
        }
        if d.integer(forKey: "combineFirst") > 1 { compositeEditor = .new(pictures.prefix(d.integer(forKey: "combineFirst")).map(\.id)) }
        #endif
        // -openStaged first | <id prefix>: a staged item's page.
        if let p = d.string(forKey: "openStaged") {
            section = .staging
            openStaged = (p == "first" ? shownStaged.first : shownStaged.first { $0.id.hasPrefix(p) })?.id
        }
        if let prefix = d.string(forKey: "open"), let m = results.first(where: { $0.id.rawValue.hasPrefix(prefix) }) { detailStack = [m.id] }
    }

    func reloadAll() {
        runSearch(reset: true)
        reloadStaging()
        reloadTags()
    }

    var name: String { collection?.name ?? "Memebooru" }
    var memeCount: Int { (try? collection?.memes.count()) ?? 0 }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.runSearch(reset: true)
        }
    }

    func runSearch(reset: Bool) {
        guard let c = collection else { return }
        do {
            let page = try c.search.search(query, limit: 80, after: reset ? nil : nextCursor)
            results = reset ? page.memes : results + page.memes
            nextCursor = page.next
        } catch { errorMessage = "\(error)" }
    }

    func loadMoreIfNeeded(current: Meme) {
        guard let last = results.last, last.id == current.id, nextCursor != nil else { return }
        runSearch(reset: false)
    }

    /// Tap on a tag anywhere → gallery filtered by that tag.
    func search(tag name: String) {
        detailStack = []
        openStaged = nil
        section = .gallery
        query = name
    }

    /// Search box binding: typing shows results immediately, wherever you were.
    var typedQuery: String {
        get { query }
        set {
            query = newValue
            if section != .gallery || !detailStack.isEmpty || openStaged != nil { section = .gallery; detailStack = []; openStaged = nil }
        }
    }

    /// Top-nav navigation: switch section, pop any pushed detail page.
    func go(_ s: Section) {
        detailStack = []
        openStaged = nil
        section = s
        if s == .staging { reloadStaging() }
        if s == .history { reloadUndoHistory() }
    }

    /// Replace tags from two text lines: the normal-tag line and the meta line.
    func setTags(_ id: MemeID, normal: String, meta: String) {
        guard let c = collection else { return }
        do {
            let wantNormal = normal.split(separator: " ").map(String.init)
            let wantMeta = meta.split(separator: " ").map(String.init)
            let wanted = try (wantNormal.map { try c.tags.ensure($0, kind: .normal) } + wantMeta.map { try c.tags.ensure($0, kind: .meta) })
            let wantedIDs = Set(wanted.map(\.id))
            for t in try c.memes.tags(of: id) where !wantedIDs.contains(t.id) { try c.memes.removeTag(id, t.name) }
            for t in wanted { try c.memes.addTag(id, t.name, kind: t.kind) }
            reloadTags()
        } catch { errorMessage = "\(error)" }
    }

    func suggestions(for prefix: String) -> [TagSuggestion] {
        (try? collection?.tags.suggest(prefix: prefix, limit: 12)) ?? []
    }

    // MARK: - Meme access

    func meme(_ id: MemeID) -> Meme? { try? collection?.memes.get(id) }
    func tags(of id: MemeID) -> [Tag] { (try? collection?.memes.tags(of: id)) ?? [] }
    func assets(of id: MemeID) -> [Asset] { (try? collection?.memes.assets(of: id)) ?? [] }
    func primaryAsset(of id: MemeID) -> Asset? { try? collection?.memes.primaryAsset(of: id) }
    func relations(of id: MemeID) -> [Relation] { (try? collection?.memes.relations(of: id)) ?? [] }

    func fileURL(_ a: Asset) -> URL? { collection?.media.url(sha256: a.sha256, ext: a.ext) }

    // MARK: - Audio preview (inline play from the gallery / cards)
    private var audioPlayer: AVPlayer?
    private var audioEndObserver: NSObjectProtocol?
    private(set) var audioPlayingID: MemeID?

    func toggleAudioPreview(_ id: MemeID) {
        if audioPlayingID == id { stopAudioPreview(); return }
        stopAudioPreview()
        guard let a = primaryAsset(of: id), let url = fileURL(a), FileManager.default.fileExists(atPath: url.path) else { return }
        let p = AVPlayer(url: url); p.play()
        audioPlayer = p; audioPlayingID = id
        audioEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            self?.stopAudioPreview()
        }
    }
    func stopAudioPreview() {
        audioPlayer?.pause(); audioPlayer = nil; audioPlayingID = nil
        if let o = audioEndObserver { NotificationCenter.default.removeObserver(o); audioEndObserver = nil }
    }

    /// The meme's thumbnail if it's already made (memory or disk) — never makes one; see `loadThumbnail`.
    func thumbnail(for meme: Meme) -> PlatformImage? {
        guard let c = collection, let a = primaryAsset(of: meme.id) else { return nil }
        let key = "thumb:" + a.sha256
        if let img = loader.cached(key) { return img }
        guard let img = PlatformImage(contentsOfFile: c.media.thumbURL(sha256: a.sha256).path) else { return nil }
        loader.store(img, for: key)
        return img
    }

    /// The meme's thumbnail, made on the media pool if it doesn't exist yet (any format, ffmpeg when the OS can't).
    func loadThumbnail(_ meme: Meme) async -> PlatformImage? {
        if let img = thumbnail(for: meme) { return img }
        guard let c = collection, let a = primaryAsset(of: meme.id) else { return nil }
        let analyzer = analyzer, file = c.media.url(sha256: a.sha256, ext: a.ext), media = c.media, sha = a.sha256, kind = meme.kind
        let img = await loader.image("thumb:" + sha) {
            (try? analyzer.ensureThumbnail(for: file, sha256: sha, kind: kind, in: media)).flatMap { PlatformImage(contentsOfFile: $0.path) }
        }
        if img != nil { aspectCache[meme.id] = nil }      // the real shape is known now
        return img
    }

    /// Full-size picture for the viewer. Files the OS image reader can't open (SVG on iOS, rarer
    /// formats) are rasterized through the media tools once and cached.
    /// Read once and kept, so redrawing a page never re-reads its pictures from disk.
    func displayImage(_ url: URL) -> PlatformImage? {
        let key = "display:" + url.path
        if let img = loader.cached(key) { return img }
        if let img = PlatformImage(contentsOfFile: url.path) { loader.store(img, for: key); return img }
        guard let bitmap = try? analyzer.converter.raster(url, maxSide: 2048),
              let png = (try? platform.thumbs.encode(bitmap, as: .png, quality: 1)) ?? nil,
              let img = PlatformImage(data: png) else { return nil }
        loader.store(img, for: key)
        return img
    }

    /// After a post's file changed shape (a combined picture laid out again).
    func forgetAspect(_ id: MemeID) { aspectCache[id] = nil }

    /// Width / height of the primary asset (from DB, else from the thumbnail). Cards get 4:3.
    func aspect(for meme: Meme) -> CGFloat {
        if let a = aspectCache[meme.id] { return a }
        var a: CGFloat
        switch meme.kind {
        case .text, .article: a = 1.1            // near-square text card (content centered fills it)
        case .audio: a = 1.0                     // square audio card
        case .tweet: a = 0.75                    // portrait card
        default:
            a = 4.0 / 3.0
            if let asset = primaryAsset(of: meme.id) {
                if let w = asset.width, let h = asset.height, w > 0, h > 0 { a = CGFloat(w) / CGFloat(h) }
                else if let c = collection, let size = MediaLoader.pixelSize(c.media.url(sha256: asset.sha256, ext: asset.ext))
                            ?? MediaLoader.pixelSize(c.media.thumbURL(sha256: asset.sha256)) {
                    a = size.width / size.height
                }
                else { return a }                    // thumbnail still being made: don't remember the guess
            }
        }
        aspectCache[meme.id] = a
        return a
    }

    func update(_ meme: Meme) {
        do { try collection?.memes.update(meme); refreshResult(meme.id) } catch { errorMessage = "\(error)" }
    }

    func setTags(_ id: MemeID, _ names: [String], defaultKind: TagKind = .normal) {
        do { try collection?.memes.setTags(id, names, defaultKind: defaultKind); reloadTags() } catch { errorMessage = "\(error)" }
    }

    func addTag(_ id: MemeID, _ name: String, kind: TagKind) {
        do { try collection?.memes.addTag(id, name, kind: kind); reloadTags() } catch { errorMessage = "\(error)" }
    }

    func removeTag(_ id: MemeID, _ name: String) {
        do { try collection?.memes.removeTag(id, name); reloadTags() } catch { errorMessage = "\(error)" }
    }

    func setTagKind(_ tag: Tag, _ kind: TagKind) {
        do { try collection?.tags.setKind(tag, kind); reloadTags() } catch { errorMessage = "\(error)" }
    }

    func delete(_ id: MemeID) {
        do {
            lastUndoLabel = try collection?.deleteMeme(id)
            results.removeAll { $0.id == id }
            if selection == id { selection = nil }
            refreshUndo()
        } catch { errorMessage = "\(error)" }
    }

    func addRelation(_ r: Relation) {
        do { try collection?.memes.addRelation(r) } catch { errorMessage = "\(error)" }
    }

    private func threadLoader() -> TweetThreadLoader? {
        guard let c = collection, let staging else { return nil }
        let http = platform.http
        let importer = TweetImporter(staging: staging, source: FxTwitterSource(http: http), http: http)
        return TweetThreadLoader(collection: c, importer: importer)
    }

    /// Tweet this one quotes (if loaded).
    func quotedTweet(of id: MemeID) -> Meme? {
        guard let r = relations(of: id).first(where: { $0.from == id && $0.kind == .quote }) else { return nil }
        return meme(r.to)
    }
    /// Tweet this one directly replies to (if loaded).
    func replyParent(of id: MemeID) -> Meme? {
        guard let r = relations(of: id).first(where: { $0.from == id && $0.kind == .replyTo }) else { return nil }
        return meme(r.to)
    }
    /// Ancestors up the reply chain, nearest first.
    func replyAncestors(of id: MemeID) -> [Meme] {
        var out: [Meme] = []; var cur = id; var guardN = 0
        while let p = replyParent(of: cur), guardN < 50 { out.append(p); cur = p.id; guardN += 1 }
        return out
    }
    func threadPending(of id: MemeID) -> (parent: Bool, quoted: Bool) {
        (try? threadLoader()?.pending(for: id)) ?? (false, false)
    }

    func loadReplyParent(of id: MemeID) { runThread("Загружаем предыдущий твит…") { try await $0.loadReplyParent(of: id) } }
    func loadReplyChain(of id: MemeID) { runThread("Загружаем цепочку…") { _ = try await $0.loadReplyChain(of: id) } }
    func loadQuoted(of id: MemeID) { runThread("Загружаем цитируемый твит…") { _ = try await $0.loadQuoted(of: id) } }

    private func runThread(_ label: String, _ body: @escaping @Sendable (TweetThreadLoader) async throws -> Void) {
        guard let loader = threadLoader() else { return }
        busy = label
        Task.detached {
            let result = await Result { try await body(loader) }
            await MainActor.run {
                self.busy = nil
                if case .failure(let e) = result { self.errorMessage = "\(e)" }
                self.threadVersion += 1
                self.runSearch(reset: true)
            }
        }
    }

    /// "Добавить отдельно от твита": stage the tweet's photos/videos as plain memes to tag and commit.
    /// Returns the number of media items staged.
    @discardableResult
    func extractTweetMedia(_ id: MemeID) -> Int {
        guard let staging, let meme = meme(id) else { return 0 }
        let date = Date(timeIntervalSince1970: Double(meme.createdAt) / 1000)
        var handle = ""
        if case .tweet(let p) = meme.payload { handle = p.handle }
        var n = 0
        for a in assets(of: id) where a.role == .media || (a.role == .primary && MediaType.detect(ext: a.ext) != nil) {
            let url = collection!.media.url(sha256: a.sha256, ext: a.ext)
            do {
                if try staging.addFromCollectionFile(url, source: handle.isEmpty ? "tweet" : "x:@\(handle)", date: date,
                                                     extraTags: handle.isEmpty ? [] : ["@\(handle.lowercased())"]) != nil { n += 1 }
            } catch { errorMessage = "\(error)" }
        }
        if n > 0 { reloadStaging(); section = .staging } else { errorMessage = "В этом твите нет изображения или видео." }
        return n
    }

    private func refreshResult(_ id: MemeID) {
        if let i = results.firstIndex(where: { $0.id == id }), let m = meme(id) { results[i] = m }
    }

    // MARK: - Undo (persists across restarts)

    /// The undo bar is a transient toast for an action done in THIS session — it must not reappear on
    /// launch just because old deletes sit in the history. So we only refresh the history list here and
    /// never revive the label from `lastUndoable()`.
    func refreshUndo() { reloadUndoHistory() }
    func dismissUndo() { lastUndoLabel = nil }

    // MARK: - Undo history (Recently deleted)

    /// Batch list only (cheap). Item previews are loaded per-batch when a row is expanded.
    private(set) var undoBatches: [UndoLog.Batch] = []

    func reloadUndoHistory() { undoBatches = (try? collection?.undo.allBatches()) ?? [] }

    /// The reversible items of a batch, each paired with its (soft-deleted) meme for a preview thumbnail.
    func undoEntries(of batchID: Int64) -> [UndoEntryVM] {
        guard let c = collection else { return [] }
        return ((try? c.undo.entries(of: batchID)) ?? []).map { e in
            UndoEntryVM(entry: e, meme: e.memeID.flatMap { try? c.memes.get(MemeID($0)) })
        }
    }

    func restoreUndoEntry(_ entryID: Int64) {
        do { try collection?.undo.restoreEntry(entryID); reloadAll(); refreshUndo() } catch { errorMessage = "\(error)" }
    }
    func restoreUndoBatch(_ batchID: Int64) {
        do { try collection?.undo.undo(batchID); reloadAll(); refreshUndo() } catch { errorMessage = "\(error)" }
    }

    /// Pausing keeps the queue: resuming carries on with the same tweets.
    func setWayback(enabled: Bool) {
        waybackEnabled = enabled
        refreshWayback()
    }

    func refreshWayback() {
        guard let c = collection else { return }
        waybackPending = (try? c.wayback.pendingCount()) ?? 0
        waybackRetryAt = (try? c.wayback.nextRetryAt()).flatMap { $0 }.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// Open a post's detail view on top of the current one (or the gallery).
    func openDetail(_ id: MemeID) { detailStack.append(id) }
    /// Replace the current detail with another (prev/next navigation — doesn't grow the stack).
    func openDetailReplacing(_ id: MemeID) {
        if detailStack.isEmpty { detailStack = [id] } else { detailStack[detailStack.count - 1] = id }
    }
    /// The meme `delta` positions away in the current search results (−1 = previous, +1 = next).
    func neighbor(of id: MemeID, _ delta: Int) -> MemeID? {
        guard let i = results.firstIndex(where: { $0.id == id }) else { return nil }
        let j = i + delta
        return results.indices.contains(j) ? results[j].id : nil
    }
    /// Request an animated pop of the top detail (Back button). The navigator plays the slide-out.
    func popDetail() { if !detailStack.isEmpty || openStaged != nil { popToken += 1 } }
    /// Remove the top detail immediately (called by the navigator at the end of its animation).
    func popDetailImmediate() {
        if !detailStack.isEmpty { detailStack.removeLast() } else { openStaged = nil }
    }
    func undoLast() {
        do { _ = try collection?.undoLast(); lastUndoLabel = nil; refreshUndo(); reloadAll() } catch { errorMessage = "\(error)" }
    }

    // MARK: - Wayback background worker

    /// (Re)starts the archiver for the open collection (the worker itself lives in the core; the server runs it too).
    func startWayback() {
        guard let c = collection, !UITesting.active else { return }   // UI tests never talk to archive.org
        wayback?.stop()
        refreshWayback()
        let w = WaybackWorker(collection: c, http: platform.http)
        w.isEnabled = { AppDefaults.store.object(forKey: "waybackEnabled") as? Bool ?? true }
        w.onJob = { [weak self] _, _ in
            Task { @MainActor in self?.refreshWayback() }
        }
        w.start()
        wayback = w
    }

    // MARK: - Bulk staging actions (undoable)

    func commitAllClean() {
        guard let c = collection else { return }
        let clean = stagedItems.filter { duplicates(of: $0).isEmpty }
        guard !clean.isEmpty else { return }
        let converting = clean.filter(\.willConvert).count
        busy = converting > 0 ? "Конвертируем файлов: \(converting)…" : "Сохраняем…"
        busyCancellable = true
        let analyzer = analyzer, total = clean.count
        activeTask = Task.detached {
            let result = Result {
                try c.commitStaged(clean, analyzer: analyzer, onProgress: { n in
                    if n % 10 == 0 || n == total { Task { @MainActor in self.busy = "Сохраняем \(n) из \(total)…" } }
                }, isCancelled: { Task.isCancelled })
            }
            await MainActor.run {
                self.busy = nil; self.busyCancellable = false; self.activeTask = nil
                switch result {
                case .success(let label): self.lastUndoLabel = label
                case .failure(let e): self.errorMessage = "\(e)"
                }
                self.reloadStaging(); self.runSearch(reset: true); self.reloadTags(); self.refreshUndo()
            }
        }
    }
    func discardAllStaged() {
        guard let c = collection, !stagedItems.isEmpty else { return }
        do { lastUndoLabel = try c.discardStaged(stagedItems); reloadStaging(); refreshUndo() }
        catch { errorMessage = "\(error)" }
    }
    func deleteAllTweets() {
        guard let c = collection else { return }
        let ids = (try? c.search.search("tweet", limit: 100_000).memes.filter { $0.kind == .tweet }.map(\.id)) ?? []
        guard !ids.isEmpty else { errorMessage = "Нет твитов для удаления."; return }
        do { lastUndoLabel = try c.deleteMemes(ids, label: "Удалить твиты: \(ids.count)"); reloadAll(); refreshUndo() }
        catch { errorMessage = "\(error)" }
    }

    // MARK: - x.com

    func setXSession(_ s: XSession) { XKeychain.save(s); xSession = s; xSessionLoaded = true }
    func logoutX() { XKeychain.clear(); xSession = nil; xSessionLoaded = true }

    func importLikes() { importX(.likes) }
    func importBookmarks() { importX(.bookmarks) }

    /// All of them, straight into the collection: paced like scrolling, 429s waited out, resumable
    /// (stop any time; the next run continues), later runs only fetch what's new. One undo step.
    private func importX(_ feed: XImporter.Feed) {
        loadXSessionIfNeeded()
        guard let c = collection, let staging, let session = xSession else { presentXLogin = true; return }
        guard activeTask == nil else { return }
        let name = feed == .likes ? "понравившиеся" : "закладки"
        busy = "Импортируем x.com — \(name)…"
        busyCancellable = true
        let http = platform.http
        activeTask = Task.detached { [staging] in
            var client = XClient(http: http, session: session, endpoints: XEndpointDefaults.endpoints())
            client.onEndpointsDiscovered = { XEndpointDefaults.save($0) }
            var importer = XImporter(staging: staging, client: client, http: http)
            let last = ProgressBox()
            let result = await Result {
                try await importer.importFeed(feed, limit: 0, extraTags: [feed == .likes ? "liked" : "bookmarked"],
                                              onProgress: { p in
                    last.value = p
                    Task { @MainActor in self.busy = xImportLabel(name, p) }
                })
            }
            await MainActor.run {
                self.busy = nil; self.busyCancellable = false; self.activeTask = nil
                self.reloadAll(); self.reloadStaging()
                switch result {
                case .success(let p):
                    if p.staged == 0 && p.skipped == 0 {
                        self.errorMessage = "x.com вернул пустой список: \(name). Возможно, он закрыт, пуст или срок сеанса истёк."
                    } else {
                        self.notice = xImportSummary(name, p, stopped: false)
                    }
                case .failure(let e) where e is CancellationError || Task.isCancelled:
                    self.notice = xImportSummary(name, last.value ?? .init(), stopped: true)
                case .failure(let e):
                    let saved = last.value?.staged ?? 0
                    self.errorMessage = "\(e)" + (saved > 0 ? "\n\nСохранено до остановки: \(saved). Повторите импорт для продолжения." : "")
                }
                self.noticeAction = .staging
            }
        }
    }

    // MARK: - Staging

    func reloadStaging() {
        stagedItems = ((try? staging?.list()) ?? []).filter { !committing.contains($0.id) }
        extrasCache = [:]
        stagingVersion += 1
        if let id = openStaged, !stagedItems.contains(where: { $0.id == id }) { openStaged = nil }
        refreshWayback()
    }

    func stage(urls: [URL], then: (@MainActor ([StagedItem]) -> Void)? = nil) {
        guard let staging else { return }
        busy = "Импортируем…"
        Task.detached { [staging] in
            let report = try? FolderImporter(staging: staging).importFiles(urls)
            await MainActor.run {
                self.busy = nil
                self.reloadStaging()
                if let r = report, !r.skipped.isEmpty { self.errorMessage = "Пропущено файлов: \(r.skipped.count)" }
                let uncommon = report?.staged.filter { $0.compatibility == .uncommon }.count ?? 0
                if uncommon > 0 {
                    self.notice = "Файлов в необычных форматах: \(uncommon). Перед сохранением можно конвертировать их во входящих."
                    self.noticeAction = .staging
                }
                self.section = .staging
                then?(report?.staged ?? [])
            }
        }
    }

    func stage(text: String) {
        do { try staging?.add(text: text, source: "paste"); reloadStaging(); section = .staging } catch { errorMessage = "\(error)" }
    }

    func importTweet(_ url: String) {
        guard let staging else { return }
        busy = "Загружаем твит…"
        let http = platform.http
        Task.detached { [staging] in
            let importer = TweetImporter(staging: staging, source: FxTwitterSource(http: http), http: http)
            do { _ = try await importer.importTweet(url) } catch { await MainActor.run { self.errorMessage = "\(error)" } }
            await MainActor.run { self.busy = nil; self.reloadStaging(); self.section = .staging }
        }
    }

    func importTelegramExport(_ dir: URL) {
        guard let staging else { return }
        busy = "Импортируем архив Telegram…"
        Task.detached { [staging] in
            do { _ = try TelegramExportImporter(staging: staging).importExport(at: dir) } catch { await MainActor.run { self.errorMessage = "\(error)" } }
            await MainActor.run { self.busy = nil; self.reloadStaging(); self.section = .staging }
        }
    }

    func updateStaged(_ item: StagedItem) {
        do { try staging?.update(item); reloadStaging() } catch { errorMessage = "\(error)" }
    }

    /// A staged picture or video's thumbnail (kept in memory only; the file may never be committed).
    func loadStagedThumbnail(_ item: StagedItem) async -> PlatformImage? {
        guard [.image, .gif, .video].contains(item.kind), let url = stagedFileURL(item) else { return nil }
        let analyzer = analyzer, kind = item.kind
        return await loader.image("staged:" + item.sha256) {
            (try? analyzer.thumbnail(url, kind: kind)).flatMap { $0 }.flatMap { PlatformImage(data: $0) }
        }
    }

    func duplicates(of item: StagedItem) -> [DuplicateHit] { (try? staging?.duplicates(of: item)) ?? [] }

    func stagedFileURL(_ item: StagedItem) -> URL? { staging?.fileURL(item) }

    /// Commits in the background; the item leaves the list at once, so reviewing never waits on a commit.
    func commit(_ item: StagedItem) {
        guard let staging else { return }
        committing.insert(item.id)
        stagedItems.removeAll { $0.id == item.id }
        if item.willConvert { busy = "Конвертируем \(item.formatLabel) → \(item.popularTarget?.label ?? "")…" }
        Task {
            let result = await MediaLoader.run { Result { try staging.commit(item.id) } }
            committing.remove(item.id)
            if item.willConvert { busy = nil }
            if case .failure(let e) = result { errorMessage = "\(e)" }
            reloadStaging(); runSearch(reset: true); reloadTags()
        }
    }

    #if DEBUG
    /// Debug-only (`-selfTestDir <folder>`): exercises the media pipeline on this device — probe, frame,
    /// popular conversion for every file in the folder, twice (the second pass proves in-process ffmpeg
    /// runs again cleanly) — writes `<folder>/selftest-<platform>.txt`, then stages the files.
    func runMediaSelfTest(_ dir: URL) {
        let analyzer = analyzer
        let staging = staging
        Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            let t = analyzer.platform.transcoder
            lines.append("transcoder: \(t.map { String(describing: type(of: $0)) } ?? "none")")
            if let f = t as? FFmpegTranscoder { lines.append("runner: \(type(of: f.runner)), encoders: \(f.encoders.count), has h264_videotoolbox: \(f.encoders.contains("h264_videotoolbox")), libmp3lame: \(f.encoders.contains("libmp3lame")), libvpx-vp9: \(f.encoders.contains("libvpx-vp9"))") }
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { MediaType.detect(url: $0) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for pass in 1...2 {
                for f in files {
                    let kind = MediaType.detect(url: f)!.kind
                    let start = Date()
                    var parts = ["pass \(pass) \(f.lastPathComponent):"]
                    let info = analyzer.analyze(f, kind: kind)
                    parts.append("codecs=\(info.codecs ?? "-") size=\(info.width ?? 0)x\(info.height ?? 0) dur=\(info.durationMs ?? 0) phash=\(info.phash != nil)")
                    parts.append("thumb=\((try? analyzer.thumbnail(f, kind: kind)).flatMap { $0 }.map { "\($0.count)B" } ?? "none")")
                    if FormatPolicy.compatibility(kind: kind, ext: f.pathExtension, codecs: info.codecs) == .uncommon,
                       let target = FormatPolicy.popularTarget(kind: kind, ext: f.pathExtension, codecs: info.codecs) {
                        do {
                            let out = try analyzer.converter.convertToTemporary(f, kind: kind, to: target)
                            let probe = try? t?.probe(out)
                            parts.append("→ \(target.label): \(probe?.codecs ?? "?")")
                            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
                        } catch { parts.append("→ \(target.label) FAILED: \(error)") }
                    }
                    parts.append(String(format: "%.2fs", Date().timeIntervalSince(start)))
                    lines.append(parts.joined(separator: " "))
                }
            }
            #if os(iOS)
            let platformName = "ios"
            #else
            let platformName = "macos"
            #endif
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("selftest-\(platformName).txt"), atomically: true, encoding: .utf8)
            if let staging { for f in files { _ = try? staging.add(file: f, source: "selftest") } }
            await MainActor.run { self.reloadStaging() }
        }
    }
    #endif

    // MARK: - Formats

    var canConvert: Bool { platform.transcoder != nil }

    func formats(of id: MemeID) -> (primary: Asset?, original: Asset?) {
        (try? collection?.formats(of: id)) ?? (nil, nil)
    }

    /// Store a meme that only exists in an uncommon format in its popular format too.
    func convertMeme(_ id: MemeID, keepOriginal: Bool, done: @escaping @MainActor () -> Void = {}) {
        guard let c = collection, let p = formats(of: id).primary, let meme = meme(id),
              let target = FormatPolicy.popularTarget(kind: meme.kind, ext: p.ext, codecs: p.codecs) else { return }
        busy = "Конвертируем \(p.formatLabel) → \(target.label)…"
        let analyzer = analyzer
        Task.detached {
            let result = Result { try c.convertMeme(id, keepOriginal: keepOriginal, analyzer: analyzer) }
            await MainActor.run {
                self.busy = nil
                if case .failure(let e) = result { self.errorMessage = "\(e)" }
                self.loader.forgetAll()
                self.aspectCache = [:]
                self.runSearch(reset: true)
                done()
            }
        }
    }

    /// iOS: a finished export waiting to be handed to the share sheet.
    var sharedExport: SharedFile?
    struct SharedFile: Identifiable { let url: URL; var id: String { url.path } }

    /// iOS has no save panel: export into a temporary folder, then offer it through the share sheet.
    func exportForSharing(_ id: MemeID, as choice: ExportChoice) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        export(id, as: choice, to: dir) { url in self.sharedExport = SharedFile(url: url) }
    }

    /// Writes an exported copy to `url` (never stored in the collection).
    func export(_ id: MemeID, as choice: ExportChoice, to url: URL, then: (@MainActor (URL) -> Void)? = nil) {
        guard let c = collection else { return }
        if case .format(let f) = choice { busy = "Экспортируем в \(f.label)…" } else { busy = "Экспортируем…" }
        let analyzer = analyzer
        Task.detached {
            let result = Result { try c.export(id, as: choice, to: url, analyzer: analyzer) }
            await MainActor.run {
                self.busy = nil
                switch result {
                case .success(let out):
                    if let then { then(out) } else { self.notice = "Экспортировано: \(out.lastPathComponent)"; self.noticeAction = nil }
                case .failure(let e): self.errorMessage = "\(e)"
                }
            }
        }
    }

    /// Whether AVFoundation can play this file as is. Anything else is played from a converted preview.
    nonisolated static func avPlayable(_ a: Asset) -> Bool { avPlayable(ext: a.ext, codecs: a.codecs) }

    nonisolated static func avPlayable(ext: String, codecs: String?) -> Bool {
        let ext = ext.lowercased()
        guard ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus"].contains(ext) else { return false }
        guard let p = MediaProbe(codecs: codecs) else { return true }   // not probed: trust the container
        let videoOK: Set<String> = ["h264", "hevc", "mpeg4", "prores", "mjpeg"]
        if let v = p.video, !videoOK.contains(v) && !(v == "av1" && hardwareAV1) { return ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus"].contains(ext) }
        return true
    }
    nonisolated static let hardwareAV1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    func previewURL(_ a: Asset) -> URL? { collection?.thumbsURL.appendingPathComponent("previews/\(a.sha256).mp4") }

    /// A URL the player can open for this video: the file itself, or its cached H.264 preview.
    /// nil while the preview doesn't exist yet — call `requestPreview` (e.g. from `.task`).
    func playableURL(for a: Asset) -> URL? {
        _ = previewsReady   // re-evaluate views when a preview lands
        guard let file = fileURL(a) else { return nil }
        if Self.avPlayable(a) { return file }
        guard let preview = previewURL(a), FileManager.default.fileExists(atPath: preview.path) else { return nil }
        return preview
    }

    /// Starts making the playable preview of a video the system player can't open (no-op otherwise).
    func requestPreview(_ a: Asset) {
        guard !Self.avPlayable(a), let file = fileURL(a), let preview = previewURL(a),
              !FileManager.default.fileExists(atPath: preview.path) else { return }
        makePreview(a, from: file, to: preview)
    }

    private func makePreview(_ a: Asset, from file: URL, to preview: URL) {
        guard canConvert, !previewsInFlight.contains(a.sha256) else { return }
        previewsInFlight.insert(a.sha256)
        let converter = analyzer.converter
        Task {
            await MediaLoader.run {
                try? FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = preview.deletingPathExtension().appendingPathExtension("part.mp4")
                let ok = (try? converter.convert(file, kind: .video, to: .mp4H264, dest: tmp)) != nil
                if ok { try? FileManager.default.moveItem(at: tmp, to: preview) } else { try? FileManager.default.removeItem(at: tmp) }
            }
            previewsInFlight.remove(a.sha256); previewsReady += 1
        }
    }

    func discard(_ item: StagedItem) {
        do { lastUndoLabel = try collection?.discardStaged([item]); reloadStaging(); refreshUndo() } catch { errorMessage = "\(error)" }
    }

    /// What Staging shows now: the chosen kind, matching the filter words, in list order.
    var shownStaged: [StagedItem] {
        _ = stagedItems
        if let c = shownStagedCache, c.kind == stagingKind, c.filter == stagingFilter { return c.items }
        let items = Self.matching(stagingKind.map { k in stagedItems.filter { $0.kind == k } } ?? stagedItems, stagingFilter)
        shownStagedCache = (stagingKind, stagingFilter, items)
        return items
    }

    /// Words to find in the text, the file name or the tweet's author (all of them, any case).
    nonisolated static func matching(_ items: [StagedItem], _ filter: String) -> [StagedItem] {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { i in
            var hay = [i.textVerbatim, i.textExact, i.originalName, i.context].compactMap { $0 }.joined(separator: " ")
            if case .tweet(let p) = i.payload { hay += " @\(p.handle) \(p.authorName)" }
            hay = hay.lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// The shown staged item `delta` places from `id`.
    func stagedNeighbor(of id: String, _ delta: Int) -> StagedItem? {
        let shown = shownStaged
        guard let i = shown.firstIndex(where: { $0.id == id }), shown.indices.contains(i + delta) else { return nil }
        return shown[i + delta]
    }

    /// Commit or discard the open item and go straight on to the next one (or back to the grid at the end).
    func commitAndAdvance(_ item: StagedItem) {
        openStaged = (stagedNeighbor(of: item.id, 1) ?? stagedNeighbor(of: item.id, -1))?.id
        commit(item)
    }
    func discardAndAdvance(_ item: StagedItem) {
        openStaged = (stagedNeighbor(of: item.id, 1) ?? stagedNeighbor(of: item.id, -1))?.id
        discard(item)
    }

    // MARK: - Duplicates

    func scanDuplicates() {
        guard let c = collection else { return }
        busy = "Проверяем…"
        let images = platform.images
        Task.detached {
            let clusters = (try? DuplicateScanner(collection: c).clusters()) ?? []
            let scanner = ContainmentScanner(collection: c, decode: { (try? images.decode($0, maxSide: 512)).map { GrayImage($0) } })
            let found = (try? scanner.scan()) ?? []
            let vms: [ContainmentVM] = found.compactMap { r in
                guard let a = try? c.memes.get(r.container), let b = try? c.memes.get(r.contained) else { return nil }
                return ContainmentVM(container: a, contained: b, inliers: r.inliers)
            }
            await MainActor.run { self.duplicateClusters = clusters; self.containments = vms; self.busy = nil }
        }
    }

    // MARK: - Containment (crops)

    private(set) var containments: [ContainmentVM] = []

    /// Record "container contains contained" and drop the pair from the review list.
    func markContains(_ vm: ContainmentVM) {
        addRelation(Relation(from: vm.container.id, to: vm.contained.id, kind: .contains))
        containments.removeAll { $0.id == vm.id }
    }
    /// The crop is redundant: record the relation, then soft-delete the contained (smaller) image.
    func deleteCrop(_ vm: ContainmentVM) {
        addRelation(Relation(from: vm.container.id, to: vm.contained.id, kind: .contains))
        delete(vm.contained.id)
        containments.removeAll { $0.id == vm.id }
    }
    func dismissContainment(_ vm: ContainmentVM) {
        do { try collection.map { try DuplicateScanner(collection: $0).dismiss(vm.container.id, vm.contained.id) } } catch { errorMessage = "\(error)" }
        containments.removeAll { $0.id == vm.id }
    }

    func keep(_ id: MemeID, in cluster: DuplicateCluster) {
        guard let c = collection else { return }
        do {
            try DuplicateScanner(collection: c).resolve(cluster, keeping: id, memes: c.memes)
            let gone = Set(cluster.members.filter { $0 != id })
            results.removeAll { gone.contains($0.id) }
            duplicateClusters.removeAll { $0 == cluster }
        } catch { errorMessage = "\(error)" }
    }

    func markVariants(_ cluster: DuplicateCluster) {
        guard let c = collection else { return }
        do { try DuplicateScanner(collection: c).markVariants(cluster, memes: c.memes); duplicateClusters.removeAll { $0 == cluster } }
        catch { errorMessage = "\(error)" }
    }

    func dismiss(_ cluster: DuplicateCluster) {
        guard let c = collection else { return }
        do { try DuplicateScanner(collection: c).dismiss(cluster); duplicateClusters.removeAll { $0 == cluster } }
        catch { errorMessage = "\(error)" }
    }

    // MARK: - Tags

    /// Reload the tag index into the model. Called on collection open and after any tag mutation,
    /// so views read `library.tags` directly and never flash a stale/empty count.
    func reloadTags() {
        guard let c = collection else { tags = []; return }
        tags = (try? c.tags.all().map {
            TagRowModel(tag: $0,
                        usage: (try? c.tags.usage(of: $0)) ?? 0,
                        usageAll: (try? c.tags.rawUsage(of: $0)) ?? 0,
                        aliases: (try? c.tags.aliases(of: $0)) ?? [])
        }) ?? []
    }

    func addAlias(_ alias: String, to tag: Tag) {
        do { try collection?.tags.addAlias(alias, to: tag); reloadTags() } catch { errorMessage = "\(error)" }
    }

    func removeAlias(_ alias: String) {
        do { try collection?.tags.removeAlias(alias); reloadTags() } catch { errorMessage = "\(error)" }
    }

    func merge(_ source: Tag, into target: Tag) {
        do { try collection?.tags.merge(source, into: target); reloadTags() } catch { errorMessage = "\(error)" }
    }
}

/// One row of the tag index: tag + usage count + aliases. Lives in the model so the Tags page
/// renders from already-loaded data (no load-on-appear flash).
struct TagRowModel: Identifiable {
    let tag: Tag; let usage: Int; let usageAll: Int; let aliases: [String]
    var id: Int64 { tag.id }
    /// A tag only present on soft-deleted memes.
    var isDead: Bool { usage == 0 && usageAll > 0 }
}

/// A detected crop: `container` (the larger image) holds `contained` (the crop) as a sub-region.
struct ContainmentVM: Identifiable {
    let container: Meme; let contained: Meme; let inliers: Int
    var id: String { container.id.rawValue + "|" + contained.id.rawValue }
}

/// One restorable item in the undo history, with its (soft-deleted) meme for a preview.
struct UndoEntryVM: Identifiable {
    let entry: UndoLog.Entry
    let meme: Meme?
    var id: Int64 { entry.id }
}

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension Image { init(platform: PlatformImage) { self.init(nsImage: platform) } }
#else
import UIKit
typealias PlatformImage = UIImage
extension Image { init(platform: PlatformImage) { self.init(uiImage: platform) } }
#endif


/// Thread-safe counter for live import progress.
final class ImportProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var _v = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _v }
    func bump() { lock.lock(); _v += 1; lock.unlock() }
}


/// Last progress seen by a background import (read once it ends).
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: XImporter.Progress?
    var value: XImporter.Progress? { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

private func megabytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func xImportLabel(_ name: String, _ p: XImporter.Progress) -> String {
    if let until = p.waitingUntil {
        return "x.com ограничил частоту запросов. Продолжим в \(until.formatted(date: .omitted, time: .shortened)); сохранено \(p.staged) — \(name)"
    }
    return "Импорт x.com — \(name): во входящих \(p.staged), в цепочках \(p.chain), уже есть \(p.skipped), \(megabytes(p.bytes))"
}

private func xImportSummary(_ name: String, _ p: XImporter.Progress, stopped: Bool) -> String {
    var s = stopped ? "Остановлено. Во входящих \(p.staged) — \(name). Для продолжения повторите импорт."
                    : p.caughtUp && p.staged == 0 ? "Новых элементов нет: \(name)."
                    : "Во входящих \(p.staged) — \(name), твитов в цепочках: \(p.chain) (\(megabytes(p.bytes)))" + (p.skipped > 0 ? "; уже были в коллекции: \(p.skipped)." : ".")
    if p.chainMissing > 0 { s += " Недоступных твитов в цепочках x.com: \(p.chainMissing)." }
    if p.mediaMissing > 0 { s += " Не удалось загрузить часть медиа: \(p.mediaMissing)." }
    return s
}
