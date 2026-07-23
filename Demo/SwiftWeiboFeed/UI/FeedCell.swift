import UIKit

@MainActor
public final class FeedCell: UITableViewCell {
    let contentNode: FeedContentView
    public var onAction: ((FeedAction) -> Void)? { didSet { contentNode.onAction = onAction } }
    private(set) var representedID: FeedID?
    private(set) var generation: UInt = 0
    private var imageTasks: [Task<Void, Never>] = []

    public override convenience init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        self.init(style: style, reuseIdentifier: reuseIdentifier, contentNode: FeedContentView())
    }
    init(style: UITableViewCell.CellStyle, reuseIdentifier: String?, contentNode: FeedContentView) {
        self.contentNode = contentNode
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.addSubview(contentNode)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ entry: PreparedFeedEntry, pipeline: any ImagePipeline) {
        let interval = FeedSignpost.begin(.cellApply)
        defer { interval.end() }
        cancelImageTasks()
        contentNode.cancelRendering()
        generation &+= 1
        let capturedGeneration = generation
        representedID = entry.item.id
        contentNode.frame = CGRect(x: 0, y: 0, width: entry.layout.profile.frame.width, height: entry.layout.height)
        contentNode.apply(entry)
        let scale = CGFloat(max(entry.layout.identity.environment.displayScale, 1))
        contentNode.display(entry: entry, generation: capturedGeneration, scale: scale)
        for (url, frame, node) in contentNode.imageBindings(for: entry, scale: scale) {
            let request = ImageRequest(url: url, targetPixelSize: PixelSize(width: max(1, Int((frame.width * scale).rounded())), height: max(1, Int((frame.height * scale).rounded()))), contentMode: .aspectFill, processorVersion: 1)
            let task = Task { [weak self, weak node] in
                do {
                    let response = try await pipeline.image(for: request)
                    try Task.checkCancellation()
                    guard let self, let node, self.representedID == entry.item.id, self.generation == capturedGeneration, response.request == request else { return }
                    node.contentsScale = scale; node.contents = response.image
                } catch {
                    guard let self, let node, self.representedID == entry.item.id, self.generation == capturedGeneration else { return }
                    node.backgroundColor = UIColor.systemRed.withAlphaComponent(0.16).cgColor
                }
            }
            imageTasks.append(task)
        }
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        generation &+= 1
        representedID = nil
        onAction = nil
        cancelImageTasks()
        contentNode.clear()
    }

    private func cancelImageTasks() { imageTasks.forEach { $0.cancel() }; imageTasks.removeAll() }
}
