import UIKit

// 表示这个类的状态和方法默认在主线程访问 解决的是 App 启动后，微博数据怎样进入 UITableView
@MainActor
final class FeedViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
#if DEBUG
    private let fpsMonitor = FeedFPSMonitorView()
#endif
    private let repository: FeedRepository  // Repository 负责把原始微博加工成 UI 可以直接使用的完整结果
    private let imagePipeline: any ImagePipeline  // 负责头像和微博图片：下载，解码，缓存，预取 可替换 可以替换成 YYWebImage
    private let layoutCache = FeedLayoutCache()  // 缓存已经算好的 Cell Layout 包括 cell 高度，头像位置，表情位置，图片位置，工具栏位置，点击区域，故事板的替代
    private lazy var prefetchCoordinator = FeedPrefetchCoordinator(imagePipeline: imagePipeline)  // 负责判断接下来应该提前准备哪些 Cell 和图片
    private let timelineStore = FeedTimelineStore() // 列表当前的数据仓库
    private var requestedIndexes = Set<Int>()
    private var loadTask: Task<Void, Never>?
    private var preparedEnvironment: FeedLayoutEnvironment?
    private var previousContentOffsetY: CGFloat = 0
    private lazy var reprepareExecutor = FeedReprepareExecutor(capacity: 16, concurrency: 2)  // 控制后台任务数量 为了防止快速滚动时创建几百个布局任务

    init(repository: FeedRepository = FeedRepository(), imagePipeline: any ImagePipeline = SystemImagePipeline()) {
        self.repository = repository
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = "Swift Weibo"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {  // 只加载一次
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        tableView.backgroundColor = .systemGroupedBackground
        tableView.accessibilityIdentifier = "feed.table"
        tableView.separatorStyle = .none
        tableView.register(FeedCell.self, forCellReuseIdentifier: "FeedCell") // 注册可复用 Cell
        tableView.dataSource = self // 有多少行、每行显示什么
        tableView.delegate = self // 高度、点击和滚动事件
        tableView.prefetchDataSource = self // 高度、点击和滚动事件
        tableView.contentInsetAdjustmentBehavior = .always
        view.addSubview(tableView)
#if DEBUG
        view.addSubview(fpsMonitor)
#endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
#if DEBUG
        fpsMonitor.start(on: view.window?.screen ?? UIScreen.main)
#endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
#if DEBUG
        fpsMonitor.stop()
#endif
    }

    override func viewDidLayoutSubviews() {
        // 必须先得到真实屏幕宽度，才能计算 Cell Layout。
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
#if DEBUG
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        fpsMonitor.frame = CGRect(x: safeFrame.minX + 10, y: safeFrame.maxY - 52, width: 150, height: 44)
        view.bringSubviewToFront(fpsMonitor)
#endif
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

    // 布局环境快照 屏幕宽度 屏幕缩放 字体大小类型 深浅色主题
    private func layoutEnvironment() -> FeedLayoutEnvironment {
        FeedLayoutEnvironment.resolve(
            width: view.bounds.width,
            scale: view.window?.screen.scale ?? UIScreen.main.scale,
            contentSizeCategory: traitCollection.preferredContentSizeCategory,
            themeVersion: traitCollection.userInterfaceStyle == .dark ? 1 : 0,
            algorithmVersion: 1
        )
    }

    // 每次布局后检查环境，只有影响 Cell Layout 的环境真正变化时才重新准备。
    private func prepareForCurrentEnvironmentIfNeeded() {
        let environment = layoutEnvironment()
        // 防止重复准备
        guard environment.containerPixelWidth > 0, environment != preparedEnvironment else { return }
        preparedEnvironment = environment
        prepareTimeline(environment: environment)
    }

    // 数据加载的真正入口
    private func prepareTimeline(environment: FeedLayoutEnvironment) {
        // 首先取消上一次任务
        // ex: 正在为竖屏计算 Layout
        //     → 用户旋转成横屏
        //     → 取消旧任务
        loadTask?.cancel()
        cancelAllRepreparation()
        navigationItem.prompt = timelineStore.count == 0 ? "Preparing 500 exact layouts…" : nil
        let repository = repository
        let resourceURLs = (0..<8).compactMap { Bundle.main.url(forResource: "weibo_\($0)", withExtension: "json") } // 找到原 Demo 的八个 JSON 文件 微博数据
        // FeedViewController 是 @MainActor，但读取八个 JSON 文件不能放在主线程。
        // 当前异步任务先暂停，主线程可以继续处理动画、触摸和刷新；后台完成后再恢复。
        /*
         主线程
           创建 Task
               ↓
         Task.detached 后台线程
           读取文件
           JSONSerialization
           JSONDecoder
           扩展到 500 条
               ↓
         await .value
           把结果交回调用流程
        */
        loadTask = Task { [weak self] in
            do {
                guard resourceURLs.count == 8 else { throw CocoaError(.fileNoSuchFile) }
                let page = try await Task.detached(priority: .userInitiated) {
                    try Self.loadDemoPage(resourceURLs: resourceURLs, minimumCount: 500)
                }.value
                try Task.checkCancellation()
                let publication = try await repository.apply(page: page, environment: environment) // Repository 会为每一条微博执行 解析正文 解析转发正文 计算 Layout 生成 PreparedFeedEntry
                try Task.checkCancellation()
                guard let snapshot = await repository.transferPreparedEntries(matching: publication.token, environment: environment) else { throw CancellationError() } // 这个完成结果是否仍然属于当前最新的一次请求？
                guard let self, self.preparedEnvironment == environment else { return }
                let isInitialLoad = self.timelineStore.count == 0
                // 上面 Repository 完成准备
                // → 更新 TimelineStore
                // → 保存 LayoutCache
                // → 告诉预取器新数据
                // → reloadData
                self.timelineStore.replace(with: snapshot)
                for entry in snapshot { self.layoutCache.insert(entry.layout, cost: max(1, Int(entry.layout.height * CGFloat(environment.containerPixelWidth)))) }
                self.requestedIndexes.removeAll()
                self.prefetchCoordinator.setEntries(snapshot)
                self.navigationItem.prompt = nil
                self.tableView.reloadData()
                if isInitialLoad {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.view.layoutIfNeeded()
                        self.tableView.setContentOffset(
                            CGPoint(
                                x: 0,
                                y: -self.tableView.adjustedContentInset.top - WeiboVisualMetrics.topMargin
                            ),
                            animated: false
                        )
                    }
                }
                self.updatePrefetchWindow(direction: .forward)
            } catch is CancellationError {
                // Width/environment changed while preparation was in flight.
            } catch {
                guard let self else { return }
                self.navigationItem.prompt = "Unable to load bundled timeline"
            }
        }
    }

    // 强制检查自己不在主线程 nonisolated 表示这个方法不受 FeedViewController 的 MainActor 隔离约束。
    nonisolated static func loadDemoPage(resourceURLs: [URL], minimumCount: Int) throws -> FeedPage {
        precondition(!Thread.isMainThread, "Bundled JSON I/O and decoding must stay off-main") // 如果未来有人误把它放回主线程，Debug 运行时会直接暴露问题。
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
        while statuses.count < minimumCount {  // 原 Demo 数据数量不足以稳定测试长列表性能，所以复制微博到至少 500 条。
            for original in originals where statuses.count < minimumCount {
                var copy = original
                let sourceID = String(describing: original["idstr"] ?? original["id"] ?? ordinal)
                let derivedID = "\(sourceID)-demo-\(ordinal)" // 每个副本必须生成新的 ID
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
        let available = max(0, reprepareExecutor.capacityForTesting - reprepareExecutor.occupiedCountForTesting)
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
                FeedEmoticonResolver.clearDecodedCache()
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

#if DEBUG
/// A lightweight development overlay. It measures main-run-loop display-link
/// delivery, which is useful for spotting regressions but is not a GPU benchmark.
@MainActor
private final class FeedFPSMonitorView: UILabel {
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval = 0
    private var sampleStartTimestamp: CFTimeInterval = 0
    private var frameCount = 0
    private var hitchCount = 0
    private var maximumFrameDuration: CFTimeInterval = 0
    private var targetFPS = 60

    init() {
        super.init(frame: .zero)
        numberOfLines = 2
        textAlignment = .center
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = 7
        clipsToBounds = true
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "feed.fpsMonitor"
        text = "FPS --/--\nHitch 0  Max --ms"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start(on screen: UIScreen) {
        guard displayLink == nil else { return }
        targetFPS = max(screen.maximumFramesPerSecond, 1)
        resetSample()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(min(30, targetFPS)),
                maximum: Float(targetFPS),
                preferred: Float(targetFPS)
            )
        } else {
            link.preferredFramesPerSecond = targetFPS
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resetSample()
    }

    @objc private func tick(_ link: CADisplayLink) {
        if previousTimestamp == 0 {
            previousTimestamp = link.timestamp
            sampleStartTimestamp = link.timestamp
            return
        }

        let frameDuration = link.timestamp - previousTimestamp
        previousTimestamp = link.timestamp
        frameCount += 1
        maximumFrameDuration = max(maximumFrameDuration, frameDuration)

        let expectedDuration = 1.0 / Double(targetFPS)
        if frameDuration > expectedDuration * 1.5 {
            hitchCount += 1
        }

        let elapsed = link.timestamp - sampleStartTimestamp
        guard elapsed >= 0.5 else { return }
        let fps = min(Int((Double(frameCount) / elapsed).rounded()), targetFPS)
        let maximumMilliseconds = Int((maximumFrameDuration * 1_000).rounded())
        text = "FPS \(fps)/\(targetFPS)\nHitch \(hitchCount)  Max \(maximumMilliseconds)ms"
        accessibilityLabel = "FPS \(fps) of \(targetFPS), hitches \(hitchCount), maximum frame \(maximumMilliseconds) milliseconds"

        frameCount = 0
        hitchCount = 0
        maximumFrameDuration = 0
        sampleStartTimestamp = link.timestamp
    }

    private func resetSample() {
        previousTimestamp = 0
        sampleStartTimestamp = 0
        frameCount = 0
        hitchCount = 0
        maximumFrameDuration = 0
    }
}
#endif

extension FeedViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { timelineStore.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        timelineStore.height(at: indexPath.row)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FeedCell", for: indexPath) as! FeedCell
        cell.accessibilityIdentifier = "feed.cell.\(indexPath.row)"
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
        let record = timelineStore.record(at: index)
        guard let environment = preparedEnvironment, environment == record.expectedLayoutIdentity.environment else { return }
        reprepareExecutor.submit(index: index, record: record, priority: priority) { [weak self] index, generation, result in
            guard let self, case let .success(entry) = result,
                  self.timelineStore.install(entry, at: index, generation: generation) else { return }
            let indexPath = IndexPath(row: index, section: 0)
            guard self.tableView.numberOfSections > 0,
                  self.tableView.numberOfRows(inSection: 0) > index else { return }
            self.tableView.reloadRows(at: [indexPath], with: .none)
        }
    }

    private func cancelRepreparation(at index: Int) { reprepareExecutor.cancel(index: index) }
    private func cancelAllRepreparation() { reprepareExecutor.cancelAll() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let direction: FeedScrollDirection = scrollView.contentOffset.y >= previousContentOffsetY ? .forward : .backward
        previousContentOffsetY = scrollView.contentOffset.y
        updatePrefetchWindow(direction: direction)
    }

    func handle(_ action: FeedAction) {
        switch action {
        case let .expand(itemID):
            guard let index = timelineStore.expand(itemID: itemID) else { return }
            cancelRepreparation(at: index)
            reprepareRow(at: index, priority: .visible)
        case let .url(url):
            showActionDetail(title: "Link", detail: url.absoluteString)
        case let .user(name):
            showActionDetail(title: "Profile", detail: name)
        case let .topic(topic):
            showActionDetail(title: "Topic", detail: topic)
        case let .tag(tag):
            showActionDetail(title: "Tag", detail: tag)
        case let .media(urls, index):
            guard urls.indices.contains(index) else { return }
            let controller = FeedImagePreviewController(
                urls: urls,
                initialIndex: index,
                imagePipeline: imagePipeline
            )
            if let navigationController {
                navigationController.pushViewController(controller, animated: true)
            } else {
                present(UINavigationController(rootViewController: controller), animated: true)
            }
        case .repost:
            showActionDetail(title: "Repost", detail: "Ready to repost")
        case .comment:
            showActionDetail(title: "Comment", detail: "Write a comment")
        case .like:
            showActionDetail(title: "Liked", detail: "Like applied locally")
        }
    }

    private func showActionDetail(title: String, detail: String) {
        let controller = FeedActionDetailViewController(title: title, detail: detail)
        if let navigationController { navigationController.pushViewController(controller, animated: true) }
        else { present(UINavigationController(rootViewController: controller), animated: true) }
    }
}

@MainActor
private final class FeedImagePreviewController: UIViewController {
    private let urls: [URL]
    private let initialIndex: Int
    private let imagePipeline: any ImagePipeline
    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private var loadTask: Task<Void, Never>?

    init(urls: [URL], initialIndex: Int, imagePipeline: any ImagePipeline) {
        self.urls = urls
        self.initialIndex = initialIndex
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = urls.count > 1 ? "\(initialIndex + 1) / \(urls.count)" : "Photo"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.accessibilityIdentifier = "feed.imagePreview"
        imageView.accessibilityLabel = "Full size image"
        imageView.isAccessibilityElement = true
        view.addSubview(imageView)
        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true
        activityIndicator.startAnimating()
        view.addSubview(activityIndicator)
        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        imageView.frame = view.bounds
        activityIndicator.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    deinit { loadTask?.cancel() }

    private func loadImage() {
        guard urls.indices.contains(initialIndex) else { return }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let size = view.bounds.isEmpty ? UIScreen.main.bounds.size : view.bounds.size
        let request = ImageRequest(
            url: urls[initialIndex],
            targetPixelSize: PixelSize(
                width: max(1, Int((size.width * scale).rounded())),
                height: max(1, Int((size.height * scale).rounded()))
            ),
            contentMode: .aspectFit,
            processorVersion: 1
        )
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await imagePipeline.image(for: request)
                try Task.checkCancellation()
                imageView.image = UIImage(cgImage: response.image)
                activityIndicator.stopAnimating()
            } catch is CancellationError {
                return
            } catch {
                activityIndicator.stopAnimating()
                imageView.accessibilityLabel = "Image failed to load"
            }
        }
    }
}

private final class FeedActionDetailViewController: UIViewController {
    private let detailText: String
    init(title: String, detail: String) {
        detailText = detail
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = detailText
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.frame = view.bounds.insetBy(dx: 24, dy: 24)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
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
