import UIKit

@MainActor
private protocol MasonryCollectionLayoutDelegate: AnyObject {
    func collectionView(
        _ collectionView: UICollectionView,
        masonryLayout: MasonryCollectionLayout,
        heightForItemAt indexPath: IndexPath,
        itemWidth: CGFloat
    ) -> CGFloat
}

/// A compact Pinterest-style layout. Every item is appended to the currently
/// shortest column, so a short card never reserves empty space beneath itself.
@MainActor
private final class MasonryCollectionLayout: UICollectionViewLayout {
    var sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 20, right: 12)
    var columnSpacing: CGFloat = 10
    var itemSpacing: CGFloat = 10

    private var cachedAttributes: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var preparedWidth: CGFloat = 0
    private var preparedItemCount = -1

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let width = collectionView.bounds.width
        guard width != preparedWidth || itemCount != preparedItemCount || cachedAttributes.isEmpty else { return }

        preparedWidth = width
        preparedItemCount = itemCount
        cachedAttributes.removeAll(keepingCapacity: true)
        let columns = collectionView.traitCollection.horizontalSizeClass == .regular ? 3 : 2
        let availableWidth = width - sectionInset.left - sectionInset.right - columnSpacing * CGFloat(columns - 1)
        let itemWidth = floor(max(1, availableWidth) / CGFloat(columns))
        var columnBottoms = Array(repeating: sectionInset.top, count: columns)
        let delegate = collectionView.delegate as? MasonryCollectionLayoutDelegate

        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let column = columnBottoms.indices.min { columnBottoms[$0] < columnBottoms[$1] } ?? 0
            let x = sectionInset.left + CGFloat(column) * (itemWidth + columnSpacing)
            let height = max(1, delegate?.collectionView(
                collectionView,
                masonryLayout: self,
                heightForItemAt: indexPath,
                itemWidth: itemWidth
            ) ?? itemWidth)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = CGRect(x: x, y: columnBottoms[column], width: itemWidth, height: height)
            cachedAttributes.append(attributes)
            columnBottoms[column] = attributes.frame.maxY + itemSpacing
        }
        contentHeight = max(sectionInset.top, (columnBottoms.max() ?? sectionInset.top) - itemSpacing) + sectionInset.bottom
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: max(collectionView?.bounds.height ?? 0, contentHeight))
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cachedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cachedAttributes.first { $0.indexPath == indexPath }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    override func invalidateLayout() {
        super.invalidateLayout()
        cachedAttributes.removeAll(keepingCapacity: true)
        preparedItemCount = -1
    }
}

private enum FeedCollectionLayoutStyle {
    case list
    case grid
}

/// Each collection layout lives in its own collection view controller. UIKit
/// can then coordinate the two layouts with the navigation push/pop animation.
@MainActor
private final class FeedCollectionViewController: UICollectionViewController {
    private let style: FeedCollectionLayoutStyle
    private weak var feedController: FeedViewController?
    private lazy var showGridButton = UIBarButtonItem(
        image: UIImage(systemName: "square.grid.2x2"),
        style: .plain,
        target: self,
        action: #selector(showGridLayout)
    )

    init(style: FeedCollectionLayoutStyle, feedController: FeedViewController) {
        self.style = style
        self.feedController = feedController
        let layout: UICollectionViewLayout
        switch style {
        case .list:
            let flowLayout = UICollectionViewFlowLayout()
            flowLayout.scrollDirection = .vertical
            flowLayout.minimumLineSpacing = 10
            flowLayout.minimumInteritemSpacing = 10
            layout = flowLayout
        case .grid:
            layout = MasonryCollectionLayout()
        }
        super.init(collectionViewLayout: layout)
        // The first collection screen is pushed from a regular UIViewController,
        // so only the grid destination opts into layout-to-layout navigation.
        useLayoutToLayoutNavigationTransitions = style == .grid
        title = style == .list ? "Collection List" : "Collection Grid"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()

        if style == .list {
            showGridButton.accessibilityLabel = "Show grid collection"
            showGridButton.accessibilityIdentifier = "feed.collection.navigation.grid"
            navigationItem.rightBarButtonItem = showGridButton
        }
    }

    private func configureCollectionView() {
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.accessibilityIdentifier = style == .list
            ? "feed.collection.list"
            : "feed.collection.grid"
        collectionView.accessibilityValue = style == .list ? "list-layout" : "grid-layout"
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.register(FeedCollectionCell.self, forCellWithReuseIdentifier: "FeedCollectionCell")
        collectionView.dataSource = feedController
        collectionView.delegate = feedController
        collectionView.prefetchDataSource = feedController
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureCollectionView()
        feedController?.attach(collectionView: collectionView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Layout-to-layout navigation may hand the participating collection view
        // back after the transition completes, so restore page-specific metadata.
        configureCollectionView()
        feedController?.attach(collectionView: collectionView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        feedController?.collectionViewDidLayout(collectionView)
    }

    @objc private func showGridLayout() {
        guard style == .list, let feedController else { return }
        let controller = FeedCollectionViewController(style: .grid, feedController: feedController)
        controller.useLayoutToLayoutNavigationTransitions = true
        navigationController?.pushViewController(controller, animated: true)
    }
}

/// A second demo keeps both layouts in one collection view controller and
/// drives the layout change from an explicit UIView animation block.
@MainActor
private final class SingleFeedCollectionViewController: UICollectionViewController {
    private weak var feedController: FeedViewController?
    private let listLayout = UICollectionViewFlowLayout()
    private let gridLayout = MasonryCollectionLayout()
    private var style: FeedCollectionLayoutStyle = .list
    private var isTransitioning = false
    private lazy var toggleLayoutButton = UIBarButtonItem(
        image: UIImage(systemName: "square.grid.2x2"),
        style: .plain,
        target: self,
        action: #selector(toggleLayout)
    )

    init(feedController: FeedViewController) {
        self.feedController = feedController
        listLayout.scrollDirection = .vertical
        listLayout.minimumLineSpacing = 10
        listLayout.minimumInteritemSpacing = 10
        super.init(collectionViewLayout: listLayout)
        title = "Single VC Layouts"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.accessibilityIdentifier = "feed.collection.single"
        collectionView.accessibilityValue = "list-layout"
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.register(FeedCollectionCell.self, forCellWithReuseIdentifier: "FeedCollectionCell")
        collectionView.dataSource = feedController
        collectionView.delegate = feedController
        collectionView.prefetchDataSource = feedController
        toggleLayoutButton.accessibilityIdentifier = "feed.collection.single.toggle"
        navigationItem.rightBarButtonItem = toggleLayoutButton
        updateToggleButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        feedController?.attach(collectionView: collectionView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        feedController?.attach(collectionView: collectionView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        feedController?.collectionViewDidLayout(collectionView)
    }

    @objc private func toggleLayout() {
        guard !isTransitioning else { return }
        let targetStyle: FeedCollectionLayoutStyle = style == .list ? .grid : .list
        let targetLayout: UICollectionViewLayout = targetStyle == .grid ? gridLayout : listLayout
        isTransitioning = true
        toggleLayoutButton.isEnabled = false
        collectionView.accessibilityValue = targetStyle == .grid
            ? "transitioning-to-grid"
            : "transitioning-to-list"

        let completeTransition = { [weak self] in
            guard let self else { return }
            self.style = targetStyle
            self.isTransitioning = false
            self.collectionView.accessibilityValue = targetStyle == .grid ? "grid-layout" : "list-layout"
            self.updateToggleButton()
            self.feedController?.attach(collectionView: self.collectionView)
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            collectionView.setCollectionViewLayout(targetLayout, animated: false)
            completeTransition()
            return
        }

        UIView.animate(
            withDuration: 0.45,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.collectionView.setCollectionViewLayout(targetLayout, animated: false)
            self.collectionView.layoutIfNeeded()
        } completion: { _ in
            completeTransition()
        }
    }

    private func updateToggleButton() {
        toggleLayoutButton.isEnabled = !isTransitioning
        toggleLayoutButton.image = UIImage(
            systemName: style == .list ? "square.grid.2x2" : "list.bullet.rectangle"
        )
        toggleLayoutButton.accessibilityLabel = style == .list
            ? "Animate to grid layout"
            : "Animate to list layout"
    }
}

// 表示这个类的状态和方法默认在主线程访问 解决的是 App 启动后，微博数据怎样进入 UITableView
@MainActor
final class FeedViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private weak var activeCollectionView: UICollectionView?
    private lazy var collectionModeButton = UIBarButtonItem(
        image: UIImage(systemName: "rectangle.grid.1x2"),
        style: .plain,
        target: self,
        action: #selector(showCollectionMode)
    )
    private lazy var singleCollectionModeButton = UIBarButtonItem(
        image: UIImage(systemName: "arrow.triangle.2.circlepath"),
        style: .plain,
        target: self,
        action: #selector(showSingleCollectionMode)
    )
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
        collectionModeButton.accessibilityLabel = "Open two-controller collection layouts"
        collectionModeButton.accessibilityIdentifier = "feed.mode.collection"
        singleCollectionModeButton.accessibilityLabel = "Open single-controller collection layouts"
        singleCollectionModeButton.accessibilityIdentifier = "feed.mode.collection.single"
        navigationItem.rightBarButtonItems = [singleCollectionModeButton, collectionModeButton]
#if DEBUG
        view.addSubview(fpsMonitor)
#endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activeCollectionView = nil
        tableView.reloadData()
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
        activeCollectionView?.collectionViewLayout.invalidateLayout()
    }

    @objc private func showCollectionMode() {
        let controller = FeedCollectionViewController(style: .list, feedController: self)
        navigationController?.pushViewController(controller, animated: true)
    }

    @objc private func showSingleCollectionMode() {
        let controller = SingleFeedCollectionViewController(feedController: self)
        navigationController?.pushViewController(controller, animated: true)
    }

    fileprivate func attach(collectionView: UICollectionView) {
        activeCollectionView = collectionView
        collectionView.reloadData()
        updatePrefetchWindow(direction: .forward)
    }

    fileprivate func collectionViewDidLayout(_ collectionView: UICollectionView) {
        prepareForCurrentEnvironmentIfNeeded(
            width: collectionView.bounds.width,
            scale: collectionView.window?.screen.scale ?? UIScreen.main.scale,
            traitCollection: collectionView.traitCollection
        )
    }

    deinit { loadTask?.cancel() }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        Task { @MainActor [weak self] in await self?.handleMemoryPressure() }
    }

    // 布局环境快照 屏幕宽度 屏幕缩放 字体大小类型 深浅色主题
    private func layoutEnvironment(
        width: CGFloat? = nil,
        scale: CGFloat? = nil,
        traitCollection: UITraitCollection? = nil
    ) -> FeedLayoutEnvironment {
        let traits = traitCollection ?? self.traitCollection
        return FeedLayoutEnvironment.resolve(
            width: width ?? view.bounds.width,
            scale: scale ?? view.window?.screen.scale ?? UIScreen.main.scale,
            contentSizeCategory: traits.preferredContentSizeCategory,
            themeVersion: traits.userInterfaceStyle == .dark ? 1 : 0,
            algorithmVersion: 1
        )
    }

    // 每次布局后检查环境，只有影响 Cell Layout 的环境真正变化时才重新准备。
    private func prepareForCurrentEnvironmentIfNeeded(
        width: CGFloat? = nil,
        scale: CGFloat? = nil,
        traitCollection: UITraitCollection? = nil
    ) {
        let environment = layoutEnvironment(width: width, scale: scale, traitCollection: traitCollection)
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
                self.activeCollectionView?.reloadData()
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
        let visibleRows = visibleIndexes()
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
        let visibleRows = Set(visibleIndexes())
        let visibleIdentities = Set(visibleRows.compactMap { timelineStore.prepared(at: $0)?.layout.identity })
        let coordinator = FeedMemoryPressureCoordinator(
            discardNonvisibleBitmaps: { [weak self] retained in
                AsyncRenderLayer.discardNonvisibleBitmaps(retaining: retained)
                guard let self else { return }
                for cell in self.visibleFeedCells() {
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

    private func visibleIndexes() -> [Int] {
        if let activeCollectionView {
            return activeCollectionView.indexPathsForVisibleItems.map(\.item).sorted()
        }
        return tableView.indexPathsForVisibleRows?.map(\.row).sorted() ?? []
    }

    private func visibleFeedCells() -> [FeedCell] {
        guard activeCollectionView == nil else { return [] }
        return tableView.visibleCells.compactMap { $0 as? FeedCell }
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
            if let collectionView = self.activeCollectionView {
                guard collectionView.numberOfSections > 0,
                      collectionView.numberOfItems(inSection: 0) > index else { return }
                collectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
            } else {
                guard self.tableView.numberOfSections > 0,
                      self.tableView.numberOfRows(inSection: 0) > index else { return }
                self.tableView.reloadRows(at: [indexPath], with: .none)
            }
        }
    }

    private func reprepareExpandedRow(at index: Int, expandedItemID: FeedID) {
        let record = timelineStore.record(at: index)
        guard let environment = preparedEnvironment,
              environment == record.expectedLayoutIdentity.environment else { return }
        reprepareExecutor.submit(index: index, record: record, priority: .visible) { [weak self] index, generation, result in
            guard let self, case let .success(entry) = result,
                  self.timelineStore.install(entry, at: index, generation: generation) else { return }
            if let collectionView = self.activeCollectionView {
                guard collectionView.numberOfSections > 0,
                      collectionView.numberOfItems(inSection: 0) > index else { return }
                let updates = {
                    collectionView.collectionViewLayout.invalidateLayout()
                    collectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
                    collectionView.layoutIfNeeded()
                }
                if UIAccessibility.isReduceMotionEnabled {
                    UIView.performWithoutAnimation(updates)
                } else {
                    UIView.animate(
                        withDuration: 0.3,
                        delay: 0,
                        options: [.curveEaseInOut, .beginFromCurrentState],
                        animations: updates
                    )
                }
                return
            }
            let indexPath = IndexPath(row: index, section: 0)
            guard let cell = self.tableView.cellForRow(at: indexPath) as? FeedCell else { return }
            cell.applyIncremental(entry, expandedItemID: expandedItemID)
            let updates = {
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
                self.tableView.layoutIfNeeded()
            }
            if UIAccessibility.isReduceMotionEnabled {
                UIView.performWithoutAnimation(updates)
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: updates)
            }
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
            reprepareExpandedRow(at: index, expandedItemID: itemID)
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

extension FeedViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching, MasonryCollectionLayoutDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        timelineStore.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "FeedCollectionCell", for: indexPath) as! FeedCollectionCell
        cell.accessibilityIdentifier = "feed.collection.cell.\(indexPath.item)"
        if let entry = timelineStore.prepared(at: indexPath.item) {
            cell.apply(entry, pipeline: imagePipeline)
        } else {
            let record = timelineStore.record(at: indexPath.item)
            cell.applyPlaceholder(identity: record.identity, height: record.exactHeight, width: collectionView.bounds.width)
            reprepareRow(at: indexPath.item, priority: .visible)
        }
        cell.onAction = { [weak self] action in self?.handle(action) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let horizontalInset: CGFloat = 12
        if collectionViewLayout is UICollectionViewFlowLayout {
            let width = max(1, collectionView.bounds.width - horizontalInset * 2)
            return CGSize(width: width, height: collectionCardHeight(at: indexPath.item, width: width, in: collectionView))
        }
        return .zero
    }

    fileprivate func collectionView(
        _ collectionView: UICollectionView,
        masonryLayout: MasonryCollectionLayout,
        heightForItemAt indexPath: IndexPath,
        itemWidth: CGFloat
    ) -> CGFloat {
        collectionCardHeight(at: indexPath.item, width: itemWidth, in: collectionView)
    }

    private func collectionCardHeight(at index: Int, width: CGFloat, in collectionView: UICollectionView) -> CGFloat {
        let cardContentInset: CGFloat = 6
        let sourceHeight = timelineStore.height(at: index)
        let sourceWidth = timelineStore.prepared(at: index)?.layout.profile.frame.width
            ?? max(1, collectionView.bounds.width)
        let contentWidth = max(1, width - cardContentInset * 2)
        let scale = contentWidth / max(1, sourceWidth)
        return ceil(sourceHeight * scale + cardContentInset * 2)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        UIEdgeInsets(top: 12, left: 12, bottom: 20, right: 12)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let entry = timelineStore.prepared(at: indexPath.item) else { return }
        showActionDetail(title: entry.item.user.name, detail: entry.item.text)
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        requestedIndexes.formUnion(indexPaths.map(\.item))
        updatePrefetchWindow(direction: collectionView.contentOffset.y >= previousContentOffsetY ? .forward : .backward)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let indexes = Set(indexPaths.map(\.item))
        requestedIndexes.subtract(indexes)
        prefetchCoordinator.cancel(indexes: indexes)
    }
}

@MainActor
private final class FeedCollectionCell: UICollectionViewCell {
    private let contentNode = FeedContentView()
    private var contentSize: CGSize = .zero
    private var representedID: FeedID?
    private var generation: UInt = 0
    private var imageTasks: [Task<Void, Never>] = []
    var onAction: ((FeedAction) -> Void)? {
        didSet { contentNode.onAction = onAction }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        contentNode.layer.anchorPoint = .zero
        contentNode.clipsToBounds = false
        contentView.addSubview(contentNode)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 16).cgPath
        guard contentSize.width > 0, contentSize.height > 0 else {
            contentNode.frame = .zero
            return
        }
        let inset: CGFloat = 6
        let scale = max(0.01, (bounds.width - inset * 2) / contentSize.width)
        contentNode.transform = .identity
        contentNode.frame = CGRect(origin: CGPoint(x: inset, y: inset), size: contentSize)
        contentNode.transform = CGAffineTransform(scaleX: scale, y: scale)
        contentNode.frame.origin = CGPoint(x: inset, y: inset)
    }

    func apply(_ entry: PreparedFeedEntry, pipeline: any ImagePipeline) {
        cancelImageTasks()
        contentNode.cancelRendering()
        generation &+= 1
        let capturedGeneration = generation
        representedID = entry.item.id
        contentSize = CGSize(width: entry.layout.profile.frame.width, height: entry.layout.height)
        contentNode.transform = .identity
        contentNode.frame = CGRect(origin: .zero, size: contentSize)
        contentNode.apply(entry)
        let scale = CGFloat(max(entry.layout.identity.environment.displayScale, 1))
        contentNode.display(entry: entry, generation: capturedGeneration, scale: scale)
        for (url, frame, layer) in contentNode.imageBindings(for: entry, scale: scale) {
            let request = ImageRequest(
                url: url,
                targetPixelSize: PixelSize(
                    width: max(1, Int((frame.width * scale).rounded())),
                    height: max(1, Int((frame.height * scale).rounded()))
                ),
                contentMode: .aspectFill,
                processorVersion: 1
            )
            requestImage(request, into: layer, entry: entry, generation: capturedGeneration, pipeline: pipeline)
        }
        setNeedsLayout()
    }

    func applyPlaceholder(identity: FeedContentIdentity, height: CGFloat, width: CGFloat) {
        cancelImageTasks()
        contentNode.clear()
        generation &+= 1
        representedID = identity.itemID
        contentSize = CGSize(width: width, height: height)
        contentNode.transform = .identity
        contentNode.frame = CGRect(origin: .zero, size: contentSize)
        contentNode.backgroundColor = .systemGray6
        contentNode.isAccessibilityElement = true
        contentNode.accessibilityLabel = "Loading feed content"
        setNeedsLayout()
    }

    private func requestImage(
        _ request: ImageRequest,
        into layer: CALayer,
        entry: PreparedFeedEntry,
        generation capturedGeneration: UInt,
        pipeline: any ImagePipeline
    ) {
        let task = Task { [weak self, weak layer] in
            do {
                let response = try await pipeline.image(for: request)
                try Task.checkCancellation()
                guard let self, let layer, self.representedID == entry.item.id,
                      self.generation == capturedGeneration, response.request == request else { return }
                layer.contentsScale = CGFloat(max(entry.layout.identity.environment.displayScale, 1))
                layer.contents = response.image
            } catch {
                guard let self, let layer, self.representedID == entry.item.id,
                      self.generation == capturedGeneration else { return }
                layer.backgroundColor = UIColor.systemRed.withAlphaComponent(0.16).cgColor
            }
        }
        imageTasks.append(task)
    }

    private func cancelImageTasks() {
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        representedID = nil
        generation &+= 1
        cancelImageTasks()
        contentSize = .zero
        contentNode.transform = .identity
        contentNode.clear()
    }
}
