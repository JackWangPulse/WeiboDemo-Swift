import UIKit

@MainActor
final class FeedViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let repository: FeedRepository
    private let imagePipeline: any ImagePipeline
    private let layoutCache = FeedLayoutCache()
    private lazy var prefetchCoordinator = FeedPrefetchCoordinator(imagePipeline: imagePipeline)
    private let timelineStore = FeedTimelineStore()
    private var requestedIndexes = Set<Int>()
    private var loadTask: Task<Void, Never>?
    private var preparedEnvironment: FeedLayoutEnvironment?
    private var previousContentOffsetY: CGFloat = 0
    private var reprepareTasks: [Int: Task<Void, Never>] = [:]
    private let reprepareCapacity = 16

    init(repository: FeedRepository = FeedRepository(), imagePipeline: any ImagePipeline = SystemImagePipeline()) {
        self.repository = repository
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = "Swift Weibo"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorStyle = .none
        tableView.register(FeedCell.self, forCellReuseIdentifier: "FeedCell")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.contentInsetAdjustmentBehavior = .always
        view.addSubview(tableView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        prepareForCurrentEnvironmentIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        prepareForCurrentEnvironmentIfNeeded()
    }

    deinit { loadTask?.cancel() }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        Task { @MainActor [weak self] in await self?.handleMemoryPressure() }
    }

    private func layoutEnvironment() -> FeedLayoutEnvironment {
        FeedLayoutEnvironment(
            width: view.bounds.width,
            scale: view.window?.screen.scale ?? UIScreen.main.scale,
            contentSizeCategory: traitCollection.preferredContentSizeCategory,
            themeVersion: traitCollection.userInterfaceStyle == .dark ? 1 : 0,
            algorithmVersion: 1
        )
    }

    private func prepareForCurrentEnvironmentIfNeeded() {
        let environment = layoutEnvironment()
        guard environment.containerPixelWidth > 0, environment != preparedEnvironment else { return }
        preparedEnvironment = environment
        prepareTimeline(environment: environment)
    }

    private func prepareTimeline(environment: FeedLayoutEnvironment) {
        loadTask?.cancel()
        cancelAllRepreparation()
        navigationItem.prompt = timelineStore.count == 0 ? "Preparing 500 exact layouts…" : nil
        let repository = repository
        let resourceURLs = (0..<8).compactMap { Bundle.main.url(forResource: "weibo_\($0)", withExtension: "json") }
        loadTask = Task { [weak self] in
            do {
                guard resourceURLs.count == 8 else { throw CocoaError(.fileNoSuchFile) }
                let page = try await Task.detached(priority: .userInitiated) {
                    try Self.loadDemoPage(resourceURLs: resourceURLs, minimumCount: 500)
                }.value
                try Task.checkCancellation()
                _ = try await repository.apply(page: page, environment: environment)
                try Task.checkCancellation()
                let snapshot = await repository.transferPreparedEntries()
                guard let self, self.preparedEnvironment == environment else { return }
                self.timelineStore.replace(with: snapshot)
                for entry in snapshot { self.layoutCache.insert(entry.layout, cost: max(1, Int(entry.layout.height * CGFloat(environment.containerPixelWidth)))) }
                self.requestedIndexes.removeAll()
                self.prefetchCoordinator.setEntries(snapshot)
                self.navigationItem.prompt = nil
                self.tableView.reloadData()
                self.updatePrefetchWindow(direction: .forward)
            } catch is CancellationError {
                // Width/environment changed while preparation was in flight.
            } catch {
                guard let self else { return }
                self.navigationItem.prompt = "Unable to load bundled timeline"
            }
        }
    }

    nonisolated static func loadDemoPage(resourceURLs: [URL], minimumCount: Int) throws -> FeedPage {
        precondition(!Thread.isMainThread, "Bundled JSON I/O and decoding must stay off-main")
        var originals = [[String: Any]]()
        for url in resourceURLs {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let statuses = root["statuses"] as? [[String: Any]] else { continue }
            originals.append(contentsOf: statuses)
        }
        guard !originals.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        var statuses = [[String: Any]]()
        statuses.reserveCapacity(max(minimumCount, originals.count))
        var ordinal = 0
        while statuses.count < minimumCount {
            for original in originals where statuses.count < minimumCount {
                var copy = original
                let sourceID = String(describing: original["idstr"] ?? original["id"] ?? ordinal)
                let derivedID = "\(sourceID)-demo-\(ordinal)"
                copy["id"] = derivedID
                copy["idstr"] = derivedID
                copy["mid"] = derivedID
                statuses.append(copy)
                ordinal += 1
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["statuses": statuses])
        return try JSONDecoder.weibo.decode(FeedPage.self, from: data)
    }

    private func updatePrefetchWindow(direction: FeedScrollDirection) {
        guard timelineStore.count > 0 else { return }
        let visibleRows = tableView.indexPathsForVisibleRows?.map(\.row).sorted() ?? []
        let visible: Range<Int>
        if let first = visibleRows.first, let last = visibleRows.last {
            visible = first..<(last + 1)
        } else {
            visible = 0..<min(8, timelineStore.count)
        }
        let update = prefetchCoordinator.update(visible: visible, requested: requestedIndexes, direction: direction)
        for index in update.cancelled where !visible.contains(index) { cancelRepreparation(at: index) }
        let available = max(0, reprepareCapacity - reprepareTasks.count)
        for job in update.jobs.lazy.filter({ $0.kind == .layout && self.timelineStore.prepared(at: $0.index) == nil }).prefix(available) {
            reprepareRow(at: job.index, priority: job.priority)
        }
    }

    private func handleMemoryPressure() async {
        let visibleRows = Set(tableView.indexPathsForVisibleRows?.map(\.row) ?? [])
        let visibleIdentities = Set(visibleRows.compactMap { timelineStore.prepared(at: $0)?.layout.identity })
        let coordinator = FeedMemoryPressureCoordinator(
            discardNonvisibleBitmaps: { [weak self] retained in
                AsyncRenderLayer.discardNonvisibleBitmaps(retaining: retained)
                guard let self else { return }
                for cell in self.tableView.visibleCells.compactMap({ $0 as? FeedCell }) {
                    guard let id = cell.representedID,
                          retained.contains(where: { $0.content.itemID == id }) else {
                        cell.contentNode.cancelRendering()
                        continue
                    }
                }
            },
            clearDecodedImages: { [imagePipeline] in
                if let pipeline = imagePipeline as? SystemImagePipeline { await pipeline.clearDecodedCache() }
            },
            discardDistantLayouts: { [weak self, layoutCache] retained in
                layoutCache.removeAllExcept(retained)
                self?.timelineStore.evictDistantLayouts(retaining: retained)
            },
            cancelLowPriorityPrefetch: { [weak self, imagePipeline] in
                self?.prefetchCoordinator.shedLowPriorityWork(retaining: visibleRows)
                if let pipeline = imagePipeline as? SystemImagePipeline { await pipeline.cancelAllPrefetch() }
            }
        )
        await coordinator.handle(retaining: visibleIdentities)
    }

    func triggerMemoryPressureForTesting() async { await handleMemoryPressure() }
}

extension FeedViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { timelineStore.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        timelineStore.height(at: indexPath.row)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FeedCell", for: indexPath) as! FeedCell
        if let entry = timelineStore.prepared(at: indexPath.row) {
            cell.apply(entry, pipeline: imagePipeline)
        } else {
            let record = timelineStore.record(at: indexPath.row)
            cell.applyPlaceholder(identity: record.identity, height: record.exactHeight, width: view.bounds.width)
            reprepareRow(at: indexPath.row, priority: .visible)
        }
        cell.onAction = { [weak self] action in self?.handle(action) }
        return cell
    }

    private func reprepareRow(at index: Int, priority: FeedPreparationPriority) {
        guard reprepareTasks[index] == nil, reprepareTasks.count < reprepareCapacity else { return }
        let record = timelineStore.record(at: index)
        let expectedGeneration = record.generation
        guard let environment = preparedEnvironment, environment == record.expectedLayoutIdentity.environment else { return }
        let taskPriority: TaskPriority = priority == .visible ? .userInitiated : .utility
        let task = Task(priority: taskPriority) { [weak self] in
            defer { self?.reprepareTasks.removeValue(forKey: index) }
            do {
                let entry = try await Task.detached(priority: .userInitiated) {
                    let parsed = FeedTextParser().parse(record.item.text)
                    let parsedRepost = record.item.repost.map { FeedTextParser().parse($0.text) }
                    let layout = try await FeedLayoutEngine().layout(identity: record.identity, item: record.item, parsedBody: parsed, parsedRepost: parsedRepost, environment: environment)
                    return PreparedFeedEntry(item: record.item, identity: record.identity, parsed: parsed, layout: layout)
                }.value
                try Task.checkCancellation()
                guard let self, self.timelineStore.install(entry, at: index, generation: expectedGeneration) else { return }
                if let cell = self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? FeedCell {
                    cell.apply(entry, pipeline: self.imagePipeline)
                }
            } catch {}
        }
        reprepareTasks[index] = task
    }

    private func cancelRepreparation(at index: Int) { reprepareTasks.removeValue(forKey: index)?.cancel() }
    private func cancelAllRepreparation() { reprepareTasks.values.forEach { $0.cancel() }; reprepareTasks.removeAll() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let direction: FeedScrollDirection = scrollView.contentOffset.y >= previousContentOffsetY ? .forward : .backward
        previousContentOffsetY = scrollView.contentOffset.y
        updatePrefetchWindow(direction: direction)
    }

    private func handle(_ action: FeedAction) {
        guard case let .url(url) = action else { return }
        UIApplication.shared.open(url)
    }
}

extension FeedViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        requestedIndexes.formUnion(indexPaths.map(\.row))
        updatePrefetchWindow(direction: tableView.contentOffset.y >= previousContentOffsetY ? .forward : .backward)
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        let indexes = Set(indexPaths.map(\.row))
        requestedIndexes.subtract(indexes)
        prefetchCoordinator.cancel(indexes: indexes)
    }
}
