import UIKit

@MainActor
final class FeedViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let repository: FeedRepository
    private let imagePipeline: any ImagePipeline
    private lazy var prefetchCoordinator = FeedPrefetchCoordinator(imagePipeline: imagePipeline)
    private var entries: [PreparedFeedEntry] = []
    private var requestedIndexes = Set<Int>()
    private var loadTask: Task<Void, Never>?
    private var preparedEnvironment: FeedLayoutEnvironment?
    private var previousContentOffsetY: CGFloat = 0

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
        navigationItem.prompt = entries.isEmpty ? "Preparing 500 exact layouts…" : nil
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
                let snapshot = await repository.snapshot()
                guard let self, self.preparedEnvironment == environment else { return }
                self.entries = snapshot
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
        guard !entries.isEmpty else { return }
        let visibleRows = tableView.indexPathsForVisibleRows?.map(\.row).sorted() ?? []
        let visible: Range<Int>
        if let first = visibleRows.first, let last = visibleRows.last {
            visible = first..<(last + 1)
        } else {
            visible = 0..<min(8, entries.count)
        }
        _ = prefetchCoordinator.update(visible: visible, requested: requestedIndexes, direction: direction)
    }
}

extension FeedViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        entries[indexPath.row].layout.height
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FeedCell", for: indexPath) as! FeedCell
        cell.apply(entries[indexPath.row], pipeline: imagePipeline)
        cell.onAction = { [weak self] action in self?.handle(action) }
        return cell
    }

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
