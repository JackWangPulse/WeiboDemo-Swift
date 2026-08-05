import UIKit

@MainActor
public final class FeedCell: UITableViewCell { // FeedCell 本身并不负责具体绘制，它更像一个生命周期管理器
    let contentNode: FeedContentView // Cell 内只有一个主要内容视图 这个相当于子视图！！！
    public var onAction: ((FeedAction) -> Void)? { didSet { contentNode.onAction = onAction } }
    private(set) var representedID: FeedID?
    /*
     feedID          = 菜名
     contentVersion  = 菜谱版本
     requestGeneration = 这一批订单编号
     cellGeneration  = 当前桌位的翻台次数
    */
    private(set) var generation: UInt = 0
    private var imageTasks: [Task<Void, Never>] = []
    var imageCompletionForTesting: ((ImageRequest, Result<Void, Error>) -> Void)?

    public override convenience init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        self.init(style: style, reuseIdentifier: reuseIdentifier, contentNode: FeedContentView())
    }
    init(style: UITableViewCell.CellStyle, reuseIdentifier: String?, contentNode: FeedContentView) {
        self.contentNode = contentNode
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.addSubview(contentNode) // 头像、文字、图片和转发区域，都由 FeedContentView 统一管理。
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // PreparedFeedEntry 包括 微博数据，解析文本，预计算布局
    func apply(_ entry: PreparedFeedEntry, pipeline: any ImagePipeline) {
        let interval = FeedSignpost.begin(.cellApply)
        defer { interval.end() }
        // 因为 UITableViewCell 会被复用。当前 Cell 之前可能显示的是另一条微博。
        cancelImageTasks()
        contentNode.cancelRendering()
        generation &+= 1
        let capturedGeneration = generation
        representedID = entry.item.id
        // 直接使用预计算尺寸 没有重新计算高度，也没有触发复杂的 Auto Layout。
        contentNode.frame = CGRect(x: 0, y: 0, width: entry.layout.profile.frame.width, height: entry.layout.height)
        contentNode.apply(entry) // apply：保存内容、设置交互和图片 Layer。
        let scale = CGFloat(max(entry.layout.identity.environment.displayScale, 1))
        // display：开始绘制文字，转发区域，工具栏等。
        contentNode.display(entry: entry, generation: capturedGeneration, scale: scale)
        // 发图片请求   图片URL 图片显示Frame 最终承载图片的CA Layer
        for (url, frame, node) in contentNode.imageBindings(for: entry, scale: scale) {
            // Cell 根据 frame 计算目标像素尺寸
            let request = ImageRequest(url: url, targetPixelSize: PixelSize(width: max(1, Int((frame.width * scale).rounded())), height: max(1, Int((frame.height * scale).rounded()))), contentMode: .aspectFill, processorVersion: 1)
            let task = Task { [weak self, weak node] in
                do { // 异步请求
                    let response = try await pipeline.image(for: request)
                    try Task.checkCancellation()
                    // generation 防止 Cell 错图
                    guard let self, let node, self.representedID == entry.item.id, self.generation == capturedGeneration, response.request == request else { return }
                    // 图片成功后直接设置到 Layer：
                    node.contentsScale = scale; node.contents = response.image
                    self.imageCompletionForTesting?(request, .success(()))
                } catch {
                    guard let self, let node, self.representedID == entry.item.id, self.generation == capturedGeneration else { return }
                    node.backgroundColor = UIColor.systemRed.withAlphaComponent(0.16).cgColor
                    self.imageCompletionForTesting?(request, .failure(error))
                }
            }
            imageTasks.append(task)
        }
    }

    func applyPlaceholder(identity: FeedContentIdentity, height: CGFloat, width: CGFloat) {
        cancelImageTasks(); contentNode.clear(); generation &+= 1; representedID = identity.itemID
        contentNode.frame = CGRect(x: 0, y: 0, width: width, height: height)
        contentNode.backgroundColor = .systemGray6
        contentNode.isAccessibilityElement = true
        contentNode.accessibilityLabel = "Loading feed content"
    }

    public override func prepareForReuse() { // UITableView 准备复用 Cell 时调用
        super.prepareForReuse()
        // 清除旧微博的
        generation &+= 1
        representedID = nil
        onAction = nil
        imageCompletionForTesting = nil
        cancelImageTasks()
        contentNode.clear()
    }

    private func cancelImageTasks() { imageTasks.forEach { $0.cancel() }; imageTasks.removeAll() }
}
