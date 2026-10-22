# Swift Weibo Feed 增量展开、双列表布局与转场动画实施计划

> 对应需求：`docs/superpowers/specs/2026-08-27-weibo-feed-incremental-expansion-dual-layout-transition-requirements.md`

**目标：** 在保留现有异步 CoreText、分区位图绘制、图片 Pipeline 和性能边界的前提下，实现 `.more` 区域级增量展开、UITableView/UICollectionView FlowLayout 双模式，以及 CollectionView 单列/多列 FlowLayout 的原生布局转场。

**核心架构：** 先把“业务内容版本、展开状态、布局环境、渲染区域版本”拆成独立身份，再让 Timeline Store 保存 Prepared Entry。Table 与 Collection 共用数据状态；Collection 同时持有单列和多列 FlowLayout，并以稳定 FeedID 恢复阅读锚点，通过系统 `setCollectionViewLayout` 完成布局属性插值。任何阶段都不得把 CoreText 测量、图片解码或整批 500 条布局移到主线程。

**技术栈：** Swift 6、UIKit、CoreText、CoreGraphics、UITableView、UICollectionView、UICollectionViewFlowLayout、XCTest、XCUITest、XcodeBuildMCP、iOS 16+

## 全局约束

- 开始写新代码前创建新分支，默认建议 `codex/weibo-feed-dual-layout`；不得覆盖或清理用户现有未提交修改。
- 当前工作树已有 `.xcodebuildmcp/config.yaml`、UI Tests、project.pbxproj 与 `.codegraph/` 相关变更，实施时先重新核对并只修改本计划明确涉及的部分。
- 每个 Task 采用测试先行：先写失败测试并确认 RED，再实现并确认 GREEN。
- 每个 Task 单独提交；提交信息最后必须追加一行 `Co-authored-by: Codex`。
- 新 Swift 文件必须加入正确的 app/test target；修改 `project.pbxproj` 时保留用户已有变更并检查冲突。
- 最低部署版本保持 iOS 16。
- 不引入第三方布局、图片或响应式依赖。
- 不链接 YYKit、YYText 或 YYWebImage。
- 解析、CoreText 布局、位图绘制、图片下载/解码继续离开主线程。
- 所有异步提交继续验证 FeedID、环境、区域版本、请求 generation 与 Cell generation。
- Collection Compact Width 为单列；Regular Width 为双列；V1 使用纵向 `UICollectionViewFlowLayout`。
- `.more` V1 只展开，不增加收起。
- 转场主体指 CollectionView 单列/多列 FlowLayout 的页面内切换；Table/Collection 之间只负责显示权交接，不修改图片预览和详情页 push 动画。

## Xcode 验证约定

开始第一次构建、运行或测试前：

1. 使用 XcodeBuildMCP `session_show_defaults`；
2. 确认工程为 `YYKitDemo.xcodeproj`、Scheme 为 `SwiftWeiboFeed`、目标为可用 iOS Simulator；
3. 仅在默认工程上下文缺失或错误时使用 `discover_projs` / `session_set_defaults`；
4. 聚焦测试通过 XcodeBuildMCP `test_sim` 的 `extraArgs` 传入 `-only-testing:...`；
5. 编译检查使用 `build_sim`；
6. UI 联调使用一次 `build_run_sim`，不要先执行重复的 build-only；
7. 真机最终验收使用已启用的 device workflow；若当前未启用，记录为人工验收项，不用 raw `xcodebuild` 代替。

---

### Task 0：建立安全分支与基线

**文件：**

- 不创建业务代码文件
- 检查：`AGENTS.md`
- 检查：`.xcodebuildmcp/config.yaml`
- 检查：`YYKitDemo.xcodeproj/project.pbxproj`
- 检查：`SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift`

- [ ] **Step 1：记录现有工作树状态**

执行只读检查：

```bash
git status --short
git branch --show-current
git diff -- .xcodebuildmcp/config.yaml YYKitDemo.xcodeproj/project.pbxproj SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift
```

不得 reset、checkout 或丢弃现有修改。

- [ ] **Step 2：创建功能分支**

若当前工作树可以安全携带现有修改，创建：

```bash
git switch -c codex/weibo-feed-dual-layout
```

若该分支已存在，使用新的 `codex/` 前缀名称；若用户现有修改与本计划将修改的文件重叠，先停下并确认处理方式。

- [ ] **Step 3：确认 XcodeBuildMCP 上下文并运行基线测试**

先调用 `session_show_defaults`，然后用 `test_sim` 运行：

```text
SwiftWeiboFeedTests/FeedLayoutEngineTests
SwiftWeiboFeedTests/FeedCellReuseTests
SwiftWeiboFeedTests/FeedPrefetchCoordinatorTests
SwiftWeiboFeedTests/AsyncRenderLayerTests
```

Expected：记录当前基线结果。若已有失败，区分“既有失败”和本轮回归，不在 Task 0 顺手修复无关问题。

- [ ] **Step 4：不提交 Task 0**

仅创建分支和记录基线，不制造空提交。

---

### Task 1：拆分展开状态与多布局环境 Timeline Store

**文件：**

- Create: `SwiftWeiboFeed/UI/FeedExpansionState.swift`
- Modify: `SwiftWeiboFeed/UI/FeedTimelineStore.swift`
- Modify: `SwiftWeiboFeed/UI/FeedReprepareExecutor.swift`
- Modify: `SwiftWeiboFeed/Domain/FeedRepository.swift`
- Modify: `SwiftWeiboFeedTests/FeedLayoutEngineTests.swift`
- Create: `SwiftWeiboFeedTests/FeedTimelineStoreTests.swift`
- Modify: `YYKitDemo.xcodeproj/project.pbxproj`

**产出接口：**

```swift
enum FeedTextTarget: Hashable, Sendable {
    case body(FeedID)
    case repost(FeedID)
}

struct FeedExpansionState: Hashable, Sendable {
    var expandedTargets: Set<FeedTextTarget>
    func maximumLines(for target: FeedTextTarget) -> Int?
}

struct FeedPreparationKey: Hashable, Sendable {
    let content: FeedContentIdentity
    let environment: FeedLayoutEnvironment
    let expansion: FeedExpansionState
}
```

Timeline Record 从单一 `exactHeight/prepared/expectedLayoutIdentity` 演进为按 `FeedPreparationKey` 或等价环境键保存准备结果，业务 Item 与 Parsed Text 只保留一份。

- [ ] **Step 1：写 Timeline Store 失败测试**

覆盖：

- 原正文和转发正文展开状态独立；
- 重复展开同一 target 返回 no-op；
- 同一 Feed 在 414pt 和 Collection 列宽下同时保留两个 Prepared Entry；
- 安装新环境布局不覆盖旧环境精确高度；
- FeedID 而不是 IndexPath 决定展开对象；
- 旧 store generation 不能安装；
- 清理远端布局时可按可见环境身份保留。

- [ ] **Step 2：运行聚焦测试并确认 RED**

使用 `test_sim`：

```text
-only-testing:SwiftWeiboFeedTests/FeedTimelineStoreTests
-only-testing:SwiftWeiboFeedTests/FeedLayoutEngineTests/testExpandingRepostUsesRepostIDAndRemovesItsLineLimit
```

Expected：新类型和多环境存储尚不存在而失败。

- [ ] **Step 3：实现独立展开状态**

- 从 `Record.maximumBodyLines` / `maximumRepostLines` 提取 `FeedExpansionState`；
- `expand(target:)` 只改变展开状态，不再把所有业务变化都伪装成新的完整 Feed 内容；
- 保留一个可用于布局缓存的 expansion revision/key；
- 明确刷新新业务内容时如何保留或清除展开状态：FeedID 保持且正文未变化时保留，正文内容变化时重置目标状态。

- [ ] **Step 4：实现多环境 Prepared Entry 存储**

- Record 保存 Item、稳定业务 identity、parsed、parsedRepost；
- Prepared Entry/精确高度按环境 + 展开状态键索引；
- `prepared(at:environment:)`、`height(at:environment:)`、`install(...)` 提供明确接口；
- reprepare request 显式携带 environment 和 expansion state；
- 不重新解析已保留的 ParsedFeedText。

- [ ] **Step 5：运行测试并确认 GREEN**

运行 Task 1 聚焦测试以及 `FeedRepositoryTests`、`FeedPrefetchCoordinatorTests`。

- [ ] **Step 6：提交 Task 1**

```bash
git add SwiftWeiboFeed/UI/FeedExpansionState.swift \
  SwiftWeiboFeed/UI/FeedTimelineStore.swift \
  SwiftWeiboFeed/UI/FeedReprepareExecutor.swift \
  SwiftWeiboFeed/Domain/FeedRepository.swift \
  SwiftWeiboFeedTests/FeedTimelineStoreTests.swift \
  SwiftWeiboFeedTests/FeedLayoutEngineTests.swift \
  YYKitDemo.xcodeproj/project.pbxproj
git commit -m "refactor: model feed expansion and layout environments" -m "Co-authored-by: Codex"
```

---

### Task 2：生成稳定正文前缀与可变尾部布局

**文件：**

- Modify: `SwiftWeiboFeed/Layout/TextLayout.swift`
- Modify: `SwiftWeiboFeed/Layout/FeedItemLayout.swift`
- Modify: `SwiftWeiboFeed/Layout/FeedLayoutEngine.swift`
- Modify: `SwiftWeiboFeed/Layout/FeedLayoutCache.swift`
- Modify: `SwiftWeiboFeedTests/FeedLayoutEngineTests.swift`
- Modify: `SwiftWeiboFeedTests/PerformanceSmokeTests.swift`

**产出接口：**

建议引入等价于以下结构的渲染切片：

```swift
struct TextRenderSlice: Sendable {
    let storage: CoreTextLayoutStorage
    let bounds: CGRect
    let regions: [InteractionRegion]
    let attachments: [TextAttachment]
}

struct IncrementalTextRenderLayout: Sendable {
    let stablePrefix: TextRenderSlice?
    let mutableTail: TextRenderSlice
}
```

`TextLayout` 仍负责完整几何、完整交互与无障碍语义；增量渲染切片仅描述如何复用位图，不能成为第二套文本语义来源。

- [ ] **Step 1：写布局切片失败测试**

新增覆盖：

- 长正文折叠/展开的前五行（或实际确认完全相同的最大前缀）具有相同 glyph/line origin；
- 折叠态包含 `.more` 的最后一行属于 mutable tail；
- 展开态 stable prefix bounds 与折叠态一致；
- 展开态 mutable tail 包含新增行且不包含 `.more`；
- 短正文 stable prefix 可以为空，行为与现有完整 TextLayout 一致；
- URL、话题、@ 和表情跨分界时 Region/Attachment 只属于正确切片；
- 转发正文使用转发 FeedID 产生 `.expand`；
- forced newline、Emoji family、超长 URL 的现有边界测试继续通过。

- [ ] **Step 2：确认 RED**

使用 `test_sim` 运行 `FeedLayoutEngineTests`。

- [ ] **Step 3：在后台布局阶段计算稳定分界**

- 继续在 `FeedLayoutEngine` 的 OperationQueue 中生成 CoreText 行；
- 比较折叠显示行与完整显示行，只把 glyph、origin、样式和 attachment 完全一致的连续前缀标记为 stable；
- 不假定稳定前缀永远固定为五行；
- `.more`、省略号或被截断 Token 所在行必须进入 mutable tail；
- 切片使用局部 bounds，但保留可转换回 Feed 全局坐标的几何；
- cancellation 检查覆盖切片生成过程。

- [ ] **Step 4：更新 FeedItemLayout 与缓存成本**

- body 与 repost body 都暴露增量渲染切片；
- `allFrames` 覆盖切片 bounds/origins/regions，保持有限且非负断言；
- Layout Cache cost 计入切片持有的 CoreText 数据，避免低估；
- 不改变短正文、profile、media、card、tag、toolbar 的视觉几何。

- [ ] **Step 5：确认 GREEN 与快照不回退**

运行：

```text
FeedLayoutEngineTests
FeedCellSnapshotTests
PerformanceSmokeTests
```

快照若变化，只允许长正文 `.more` 边界因明确修正而变化；不得自动重录全部基准图。

- [ ] **Step 6：提交 Task 2**

```bash
git add SwiftWeiboFeed/Layout SwiftWeiboFeedTests/FeedLayoutEngineTests.swift \
  SwiftWeiboFeedTests/PerformanceSmokeTests.swift
git commit -m "feat: split expandable text into stable and mutable render slices" -m "Co-authored-by: Codex"
```

---

### Task 3：建立区域级渲染身份与位图复用

**文件：**

- Modify: `SwiftWeiboFeed/Display/RenderIdentity.swift`
- Modify: `SwiftWeiboFeed/Display/AsyncRenderLayer.swift`
- Modify: `SwiftWeiboFeed/UI/FeedContentView.swift`
- Modify: `SwiftWeiboFeedTests/AsyncRenderLayerTests.swift`
- Modify: `SwiftWeiboFeedTests/FeedCellReuseTests.swift`
- Modify: `SwiftWeiboFeed/Performance/FeedSignpost.swift`

**关键问题：** 当前 `RenderIdentity` 持有完整 `FeedLayoutIdentity`。展开导致 content/layout identity 变化后，profile、card、tag 和 toolbar 即使像素未变也会失效。

**产出接口：**

```swift
enum RenderRegion: Hashable, Sendable {
    case profile
    case bodyStablePrefix
    case bodyMutableTail
    case repostBackground
    case repostStablePrefix
    case repostMutableTail
    case card
    case tag
    case toolbar
}

struct RenderRegionIdentity: Hashable, Sendable {
    let itemID: FeedID
    let environment: FeedLayoutEnvironment
    let region: RenderRegion
    let revision: UInt64
}
```

Cell generation 继续作为提交安全门，但不再等价于“所有区域像素内容都变化”。

- [ ] **Step 1：写区域身份和 AsyncRenderLayer 失败测试**

覆盖：

- 展开正文只改变 body mutable tail revision；
- profile、stable prefix、card、tag、toolbar revision 保持；
- repost 展开不改变原 body 区域 revision；
- 相同像素内容可更新 layer frame/retained identity 而不调用 draw closure；
- Layer 被 Cell 复用给另一个 FeedID 后，旧 task 仍不能提交；
- memory pressure 以 FeedID + environment 保留当前可见区域，不依赖旧整条 layout version。

- [ ] **Step 2：确认 RED**

运行 `AsyncRenderLayerTests` 与 `FeedCellReuseTests` 的新测试。

- [ ] **Step 3：实现区域 revision 生成规则**

- profile revision 只依赖 profile 像素输入；
- stable prefix revision 依赖原文、解析版本、字体/主题/宽度和稳定切片内容；
- mutable tail revision 额外依赖展开状态；
- card/tag/toolbar 各自只依赖本区域内容；
- frame 的纵向移动不进入像素 revision；宽度/尺寸改变进入 revision；
- 避免用 `hashValue` 持久化 revision，使用确定性字段或显式版本结构。

- [ ] **Step 4：为 AsyncRenderLayer 增加安全复用路径**

- 当 identity 与像素尺寸匹配且已有 contents 时，不重复创建 bitmap context；
- 允许仅更新 frame/retention metadata；
- 有 in-flight task 时仍需按新 token/identity 规则取消或接续；
- 跨 FeedID、跨主题、跨宽度不能误复用；
- `discardNonvisibleBitmaps` 使用新的 region identity 判定。

- [ ] **Step 5：增加区域级可观测性**

记录 `expandTailLayout`、`expandTailRender` 和 region reuse hit。测试通过 observer/hook 计数，不依赖解析 Console 文本。

- [ ] **Step 6：确认 GREEN 并提交**

```bash
git add SwiftWeiboFeed/Display SwiftWeiboFeed/UI/FeedContentView.swift \
  SwiftWeiboFeed/Performance/FeedSignpost.swift \
  SwiftWeiboFeedTests/AsyncRenderLayerTests.swift \
  SwiftWeiboFeedTests/FeedCellReuseTests.swift
git commit -m "feat: reuse unchanged feed render regions" -m "Co-authored-by: Codex"
```

---

### Task 4：抽取 Table/Collection 共用的 Feed Cell 内容宿主

**文件：**

- Create: `SwiftWeiboFeed/UI/FeedCellContentHost.swift`
- Modify: `SwiftWeiboFeed/UI/FeedCell.swift`
- Modify: `SwiftWeiboFeed/UI/FeedContentView.swift`
- Modify: `SwiftWeiboFeedTests/FeedCellReuseTests.swift`
- Modify: `SwiftWeiboFeedTests/SystemImagePipelineTests.swift`
- Modify: `YYKitDemo.xcodeproj/project.pbxproj`

**产出职责：**

`FeedCellContentHost` 或等价对象统一拥有：

- `FeedContentView`；
- represented FeedID；
- Cell generation；
- 图片 Task/订阅；
- full apply 与 incremental apply；
- prepareForReuse；
- Action 转发；
- 图片完成 identity 校验。

UITableViewCell 和后续 UICollectionViewCell 只负责把 host view 安装进自己的 `contentView` 并转发生命周期。

- [ ] **Step 1：写共用宿主失败测试**

覆盖：

- full apply 会取消旧 Feed 的 task 并提升 generation；
- 同 Feed expansion update 不清空稳定 Layer contents；
- 同 Feed expansion update 不重新请求未变化图片；
- frame 改变时图片 Layer contents 保留；
- FeedID 改变必须走 full reuse；
- 旧图片完成回调不能提交；
- host reuse 后 Action 和 Accessibility 不指向旧 entry。

- [ ] **Step 2：确认 RED**

运行 `FeedCellReuseTests` 与相关 `SystemImagePipelineTests`。

- [ ] **Step 3：抽取现有 FeedCell 生命周期逻辑**

- 先保持 UITableView 行为完全一致；
- 将 `cancelImageTasks`、generation、representedID、image bindings 移入 host；
- 不改变 `ImagePipeline` 协议；
- `FeedCell` 暂时保留类型名，降低现有 Controller 和快照测试改动。

- [ ] **Step 4：增加 incremental apply**

输入旧/新 Prepared Entry 或明确 `FeedVisualDelta`：

- 更新整体和区域 frame；
- 仅提交 mutable tail draw；
- 稳定 Layer 不 cancel、不 display；
- 下游静态位图仅移动；
- 新增/删除图片才调整图片绑定；
- 重新构建 interaction/accessibility regions，但保留当前 Feed 焦点语义。

- [ ] **Step 5：确认 GREEN 与快照一致**

运行 `FeedCellReuseTests`、`FeedCellSnapshotTests`、`SystemImagePipelineTests`。

- [ ] **Step 6：提交 Task 4**

```bash
git add SwiftWeiboFeed/UI/FeedCellContentHost.swift SwiftWeiboFeed/UI/FeedCell.swift \
  SwiftWeiboFeed/UI/FeedContentView.swift SwiftWeiboFeedTests/FeedCellReuseTests.swift \
  SwiftWeiboFeedTests/SystemImagePipelineTests.swift YYKitDemo.xcodeproj/project.pbxproj
git commit -m "refactor: share feed cell content lifecycle" -m "Co-authored-by: Codex"
```

---

### Task 5：Table 模式无 reload 增量展开

**文件：**

- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Modify: `SwiftWeiboFeed/UI/FeedTimelineStore.swift`
- Modify: `SwiftWeiboFeed/UI/FeedReprepareExecutor.swift`
- Modify: `SwiftWeiboFeedTests/FeedCellReuseTests.swift`
- Modify: `SwiftWeiboFeedTests/PerformanceSmokeTests.swift`
- Modify: `SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift`

- [ ] **Step 1：写 Table 展开失败测试**

通过可注入 observer/spy 覆盖：

- `.more` 不调用 `reloadRows`；
- 展开准备精确布局后 store 先安装，再更新可见 Cell；
- Table 使用 batch height update 平滑应用新高度；
- 点击位置/目标 Cell 顶部作为锚点，不发生意外 contentOffset 跳动；
- profile/stable/card/tag/toolbar draw 计数为 0；
- body/repost mutable tail draw 计数符合目标；
- 展开时 Cell 离屏不崩溃，状态仍保留；
- 快速重复点击只提交一个有效请求。

- [ ] **Step 2：确认 RED**

运行聚焦 Unit Tests；UI Test 先只添加标识和最终状态断言，动画性能不靠 UI Test 时间阈值判断。

- [ ] **Step 3：改造展开安装流程**

将当前：

```text
expand → prepared=nil → reprepare → reloadRows
```

改为：

```text
expand target
→ 保留当前 Prepared Entry 可见
→ 后台生成目标环境的新 layout/tail
→ generation 校验
→ store 安装新 entry
→ 可见 Cell incremental apply
→ UITableView batch height update
```

旧内容在新布局就绪前持续显示。失败时恢复 `.more` 可点击状态，不留下空白 placeholder。

- [ ] **Step 4：实现展开动画和 Reduce Motion**

- 使用 0.25～0.35 秒集中参数；
- stable prefix 不做 alpha 动画；
- mutable tail 使用 clip + fade；
- 下游 Layer 随 frame 动画；
- `UIAccessibility.isReduceMotionEnabled` 时直接应用或短淡入；
- 动画结束/取消后 interaction regions 与最终布局一致。

- [ ] **Step 5：验证 Table 完整回归**

运行：

```text
FeedLayoutEngineTests
FeedCellReuseTests
FeedCellSnapshotTests
PerformanceSmokeTests
SwiftWeiboFeedUITests 中 Table/.more 用例
```

使用 `build_run_sim` 人工检查长正文和长转发正文展开，无整 Cell 闪烁。

- [ ] **Step 6：提交 Task 5**

```bash
git add SwiftWeiboFeed/UI SwiftWeiboFeedTests/FeedCellReuseTests.swift \
  SwiftWeiboFeedTests/PerformanceSmokeTests.swift SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift
git commit -m "feat: expand table feed text incrementally" -m "Co-authored-by: Codex"
```

---

### Task 6：建立容器无关的列表 Adapter 与锚点模型

**文件：**

- Create: `SwiftWeiboFeed/UI/FeedListAdapter.swift`
- Create: `SwiftWeiboFeed/UI/FeedScrollAnchor.swift`
- Create: `SwiftWeiboFeed/UI/FeedTableAdapter.swift`
- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Modify: `SwiftWeiboFeed/UI/FeedPrefetchCoordinator.swift`
- Create: `SwiftWeiboFeedTests/FeedListAdapterTests.swift`
- Modify: `SwiftWeiboFeedTests/FeedPrefetchCoordinatorTests.swift`
- Modify: `YYKitDemo.xcodeproj/project.pbxproj`

**建议接口：**

```swift
@MainActor
protocol FeedListAdapter: AnyObject {
    var view: UIView { get }
    var scrollView: UIScrollView { get }
    var visibleIndexes: [Int] { get }
    var visibleFeedIDs: [FeedID] { get }
    func reload()
    func applyUpdate(at index: Int, old: PreparedFeedEntry?, new: PreparedFeedEntry)
    func captureAnchor() -> FeedScrollAnchor?
    func restoreAnchor(_ anchor: FeedScrollAnchor, animated: Bool)
    func visibleContentView(for feedID: FeedID) -> FeedContentView?
}
```

接口可以调整，但不得暴露 Table 专属的 row 或 Collection 专属的 item 给 Controller 业务层。

- [ ] **Step 1：写锚点与 Adapter 契约失败测试**

覆盖：

- 选择最接近 viewport center 的 FeedID；
- 记录 Feed frame 相对 viewport 的 y；
- 目标 Feed 删除时按“后一个，再前一个”降级；
- 相同 visible indexes 对 Table/Collection 产生相同预取优先级；

- [ ] **Step 2：确认 RED**

运行新 `FeedListAdapterTests` 与 `FeedPrefetchCoordinatorTests`。

- [ ] **Step 3：把 UITableView data source/delegate 移入 FeedTableAdapter**

- Controller 仍拥有 Repository、Store、Image Pipeline 和 Action 路由；
- Adapter 通过闭包/协议请求 entry、height、reprepare 和 action；
- UITableView accessibility identifier 保持 `feed.table`；
- scroll/prefetch 回调输出抽象 indexes，不让 Controller 直接访问 `indexPathsForVisibleRows`。

- [ ] **Step 4：抽象可见窗口与内存压力逻辑**

- `updatePrefetchWindow` 使用 active adapter 的 visible indexes；
- memory pressure 遍历 active adapter 的可见 FeedContentView；
- requested indexes 与取消逻辑不依赖 UITableView；
- 保留方向检测和 bounded executor 行为。

- [ ] **Step 5：确认 Table 行为不变**

运行所有 Feed UI/Prefetch/Performance tests，使用 `build_run_sim` 检查 Table 模式。

- [ ] **Step 6：提交 Task 6**

```bash
git add SwiftWeiboFeed/UI/FeedListAdapter.swift SwiftWeiboFeed/UI/FeedScrollAnchor.swift \
  SwiftWeiboFeed/UI/FeedTableAdapter.swift SwiftWeiboFeed/UI/FeedViewController.swift \
  SwiftWeiboFeed/UI/FeedPrefetchCoordinator.swift SwiftWeiboFeedTests/FeedListAdapterTests.swift \
  SwiftWeiboFeedTests/FeedPrefetchCoordinatorTests.swift YYKitDemo.xcodeproj/project.pbxproj
git commit -m "refactor: isolate feed list container behavior" -m "Co-authored-by: Codex"
```

---

### Task 7：增加 UICollectionViewCell 与 FlowLayout Adapter

**文件：**

- Create: `SwiftWeiboFeed/UI/FeedCollectionCell.swift`
- Create: `SwiftWeiboFeed/UI/FeedCollectionAdapter.swift`
- Create: `SwiftWeiboFeed/UI/FeedFlowLayoutMetrics.swift`
- Modify: `SwiftWeiboFeed/UI/FeedCellContentHost.swift`
- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Create: `SwiftWeiboFeedTests/FeedCollectionAdapterTests.swift`
- Modify: `SwiftWeiboFeedTests/FeedCellReuseTests.swift`
- Modify: `YYKitDemo.xcodeproj/project.pbxproj`

- [ ] **Step 1：写 FlowLayout 和 Collection Cell 失败测试**

覆盖：

- Compact Width 列数为 1；
- Regular Width 列数为 2；
- itemWidth 精确扣除 section inset 和 inter-item spacing；
- 像素对齐后最后一列不越界；
- `sizeForItemAt` 只读取 Store 的精确高度，不同步调用 parser/layout hook；
- Collection Cell 复用取消旧任务且不串图；
- Table Cell 与 Collection Cell 应用相同 entry 后 FeedContentView 结果一致；
- environment/宽度变化只请求目标宽度 Prepared Entry。

- [ ] **Step 2：确认 RED**

运行 `FeedCollectionAdapterTests` 与新增 reuse tests。

- [ ] **Step 3：实现 FeedCollectionCell**

- 继承 `UICollectionViewCell`；
- 安装共用 `FeedCellContentHost`；
- `prepareForReuse` 转发给 host；
- 不复制 FeedCell 的图片和渲染逻辑；
- accessibility identifier 使用稳定 FeedID 或 `feed.collection.cell.<index>` 的测试映射。

- [ ] **Step 4：实现 FlowLayout metrics 与 Adapter**

- 纵向 `UICollectionViewFlowLayout`；
- Compact 单列、Regular 双列；
- delegate size 查 Store 的目标 environment entry；
- 缺失布局时提交可见优先 reprepare 并显示稳定 placeholder；
- 实现 `UICollectionViewDataSourcePrefetching` 并接共用 coordinator；
- item 尺寸更新用 FlowLayout invalidation/batch updates，不 reload 全列表。

- [ ] **Step 5：确认 Collection 聚焦测试 GREEN**

运行：

```text
FeedCollectionAdapterTests
FeedCellReuseTests
FeedLayoutEngineTests
FeedPrefetchCoordinatorTests
```

- [ ] **Step 6：提交 Task 7**

```bash
git add SwiftWeiboFeed/UI/FeedCollectionCell.swift SwiftWeiboFeed/UI/FeedCollectionAdapter.swift \
  SwiftWeiboFeed/UI/FeedFlowLayoutMetrics.swift SwiftWeiboFeed/UI/FeedCellContentHost.swift \
  SwiftWeiboFeed/UI/FeedViewController.swift SwiftWeiboFeedTests/FeedCollectionAdapterTests.swift \
  SwiftWeiboFeedTests/FeedCellReuseTests.swift YYKitDemo.xcodeproj/project.pbxproj
git commit -m "feat: add flow-layout collection feed" -m "Co-authored-by: Codex"
```

---

### Task 8：加入两个模式按钮与状态同步

**文件：**

- Create: `SwiftWeiboFeed/UI/FeedLayoutMode.swift`
- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Modify: `SwiftWeiboFeed/UI/FeedTableAdapter.swift`
- Modify: `SwiftWeiboFeed/UI/FeedCollectionAdapter.swift`
- Create: `SwiftWeiboFeedTests/FeedLayoutModeTests.swift`
- Modify: `SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift`
- Modify: `YYKitDemo.xcodeproj/project.pbxproj`

- [ ] **Step 1：写模式状态失败测试**

覆盖：

- 初始模式为 `.table`；
- 重复点击当前模式 no-op；
- 模式按钮 Selected 状态与实际 active adapter 一致；
- Table/Collection 共用同一 Store、Repository、Image Pipeline 和 Action 路由；
- 展开状态切换模式后保留；
- 模式切换不重新加载 JSON、不重新解析全部 500 条 Feed；
- accessibility label/identifier/value 正确。

- [ ] **Step 2：确认 RED**

运行 `FeedLayoutModeTests`；增加 UI 测试按钮查找但暂不要求复杂转场。

- [ ] **Step 3：实现两个导航栏按钮**

- Table：SF Symbol + `feed.mode.table`；
- Collection：SF Symbol + `feed.mode.collection`；
- 选中态通过 tint/disabled/selected accessibility value 明确表达；
- 重复点击不 reload；
- 切换目标状态统一经过 `setLayoutMode(_:animated:)`。

- [ ] **Step 4：实现无动画模式切换基线**

- capture 当前 anchor；
- 目标 Adapter 按目标宽度优先准备可见窗口；
- 目标容器 ready 后切换可见性并 restore anchor；
- 旧容器停止交互和预取；
- 不销毁 Store 和图片缓存；
- 先确保无动画路径完全正确，为 Task 10 的动画提供稳定 fallback。

- [ ] **Step 5：验证功能并提交**

运行 Unit/UI tests，使用 `build_run_sim` 检查两个按钮、展开状态和滚动锚点。

```bash
git add SwiftWeiboFeed/UI/FeedLayoutMode.swift SwiftWeiboFeed/UI/FeedViewController.swift \
  SwiftWeiboFeed/UI/FeedTableAdapter.swift SwiftWeiboFeed/UI/FeedCollectionAdapter.swift \
  SwiftWeiboFeedTests/FeedLayoutModeTests.swift SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift \
  YYKitDemo.xcodeproj/project.pbxproj
git commit -m "feat: switch between table and collection feed modes" -m "Co-authored-by: Codex"
```

---

### Task 9：Collection 模式增量展开与环境切换

**文件：**

- Modify: `SwiftWeiboFeed/UI/FeedCollectionAdapter.swift`
- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Modify: `SwiftWeiboFeed/UI/FeedTimelineStore.swift`
- Modify: `SwiftWeiboFeedTests/FeedCollectionAdapterTests.swift`
- Modify: `SwiftWeiboFeedTests/FeedLayoutModeTests.swift`
- Modify: `SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift`

- [ ] **Step 1：写 Collection 展开/环境失败测试**

覆盖：

- Collection `.more` 使用当前 itemWidth environment；
- 只 invalidate 目标 Item size；
- 可见 Collection Cell 使用 incremental apply；
- 展开后其他 Item 的 bitmap 不重画；
- Compact/Regular 切换得到正确列数和 layout identity；
- 横竖屏变化不会提交旧宽度布局；
- Table 中展开后进入 Collection 仍展开，反向亦然。

- [ ] **Step 2：确认 RED**

运行 Collection/Mode 聚焦测试。

- [ ] **Step 3：实现 Collection 增量 size update**

- Store 安装新 entry；
- 可见 Cell incremental apply；
- FlowLayout invalidation context 只标记目标 IndexPath；
- `performBatchUpdates` 或等价方式动画高度变化；
- 锚定点击 Feed，避免布局重新排布后突然跳动；
- 离屏时只保留状态和新 entry，不强制创建 Cell。

- [ ] **Step 4：处理 trait/width 变化**

- 根据有效 content width 重新计算 metrics；
- 目标环境可见优先准备；
- 旧环境缓存可保留到成本策略清理；
- 不重新解析正文；
- 取消旧环境低优先级任务。

- [ ] **Step 5：确认 GREEN 并提交**

```bash
git add SwiftWeiboFeed/UI/FeedCollectionAdapter.swift SwiftWeiboFeed/UI/FeedViewController.swift \
  SwiftWeiboFeed/UI/FeedTimelineStore.swift SwiftWeiboFeedTests/FeedCollectionAdapterTests.swift \
  SwiftWeiboFeedTests/FeedLayoutModeTests.swift SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift
git commit -m "feat: expand collection feed items incrementally" -m "Co-authored-by: Codex"
```

---

### Task 10：实现 UICollectionView 不同 FlowLayout 的原生转场

**文件：**

- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Modify: `SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift`

**转场状态机：**

```text
idle
→ aligningCollectionList(anchor)
→ animatingCollectionLayout(sourceLayout, targetLayout)
→ completing
→ idle

任意阶段可进入 cancelling → applyFinalMode → idle
```

- [ ] **Step 1：写转场映射与状态机失败测试**

覆盖：

- 单列使用 `UICollectionViewFlowLayout`，多列使用最短列优先的瀑布流 `UICollectionViewLayout`；
- anchor Feed 的移动量最小；
- 重复切换被忽略或合并为最终目标；
- 数据更新删除 anchor 时安全降级；
- rotation/background/memory pressure 可以 cancel 并落到一致最终状态；
- Reduce Motion 直接应用目标 Layout；
- completion 后实际 Layout、完成态标识和模式按钮一致。

- [ ] **Step 2：确认 RED**

运行 `FeedLayoutTransitionCoordinatorTests`。

- [ ] **Step 3：扩展 Adapter 转场查询接口**

提供单列和多列 FlowLayout，并让 delegate 根据传入的 `collectionViewLayout` 返回对应 itemSize。单列用于和 Table 交接，多列用于最终卡片界面。

- [ ] **Step 4：实现原生 Layout Transition**

- Table → Collection：先无动画安装单列 Layout、恢复锚点，再调用 `setCollectionViewLayout(gridLayout, animated: true)`；
- Collection → Table：先调用 `setCollectionViewLayout(listLayout, animated: true)`，完成后再交接给 Table；
- Layout 切换过程中不 reload Collection 数据，不创建临时 Item snapshot；
- Collection 模式显示独立的 `feed.collection.layout.toggle` 按钮，允许用户反复触发单列 FlowLayout / 多列瀑布流 Layout Transition；
- 瀑布流按每列累计高度选择下一 Item 的目标列，禁止按行高度预留空洞；
- 布局按钮图标和无障碍 label 随当前 FlowLayout 更新，转场期间禁用；
- completion 更新完成态标识、按钮和预取窗口。

- [ ] **Step 5：实现降级与中断**

- `UIAccessibility.isReduceMotionEnabled`：无位移切换或短 cross-fade；
- Layout Transition 失败或 Reduce Motion 开启：直接安装目标 Layout；
- App background、页面消失、旋转、内存警告：立即完成或取消到目标模式；
- 转场中到达的旧 generation 布局/位图结果静默丢弃。

- [ ] **Step 6：确认 GREEN 与人工关键帧检查**

运行 Unit/UI tests。使用 `build_run_sim` 检查：

- Table → Collection；
- Collection → Table；
- 屏幕中部 Feed 锚点；
- 已展开 Feed；
- 图片加载中与加载完成；
- 快速重复点击；
- Reduce Motion；
- 旋转/后台中断。

- [ ] **Step 7：提交 Task 10**

```bash
git add SwiftWeiboFeed/UI/FeedLayoutTransitionCoordinator.swift \
  SwiftWeiboFeed/UI/FeedTransitionSnapshot.swift SwiftWeiboFeed/UI/FeedListAdapter.swift \
  SwiftWeiboFeed/UI/FeedTableAdapter.swift SwiftWeiboFeed/UI/FeedCollectionAdapter.swift \
  SwiftWeiboFeed/UI/FeedViewController.swift \
  SwiftWeiboFeedTests/FeedLayoutTransitionCoordinatorTests.swift \
  SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift YYKitDemo.xcodeproj/project.pbxproj
git commit -m "feat: animate feed layout mode transitions" -m "Co-authored-by: Codex"
```

---

### Task 11：无障碍、快照与 UI 回归

**文件：**

- Modify: `SwiftWeiboFeed/UI/FeedContentView.swift`
- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Modify: `SwiftWeiboFeed/UI/FeedCollectionCell.swift`
- Modify: `SwiftWeiboFeedTests/FeedCellSnapshotTests.swift`
- Modify: `SwiftWeiboFeedTests/FeedCellReuseTests.swift`
- Modify: `SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift`
- Add snapshots only when reviewed: `SwiftWeiboFeedTests/SnapshotReferences/<runtime>/...`

- [ ] **Step 1：补充无障碍失败测试**

覆盖：

- 两个模式按钮 label、identifier、selected value；
- `.more` 为“展开全文”且展开后消失；
- Collection reading order 与视觉顺序一致；
- 展开后 VoiceOver 语义焦点仍属于同一 Feed；
- Reduce Motion 下模式切换完成；
- Table/Collection 的语义 Action 相同。

- [ ] **Step 2：补充 Snapshot 场景**

至少新增/复核：

- Table 长正文折叠/展开；
- Table 长转发折叠/展开；
- Collection Compact 单列；
- Collection Regular 双列；
- rich text + emoticon + media + card/tag 的 Collection 组合；
- Light/Dark；
- Placeholder 和 image failure。

转场动画本身不使用静态 snapshot 自动判断“流畅”，只保存必要关键帧用于人工复核。

- [ ] **Step 3：补充端到端 UI 测试**

流程：

```text
启动 Table
→ 滚到长正文
→ 点击 more
→ 切换 Collection
→ 验证同 Feed 仍展开且接近原视口位置
→ Collection 中展开另一条转发正文
→ 切回 Table
→ 验证两条展开状态都保留
```

再覆盖连续切换、旋转和按钮选中态。

- [ ] **Step 4：运行测试并人工审核 Snapshot diff**

不得使用自动 record 覆盖所有基准。只接受符合需求的明确变化。

- [ ] **Step 5：提交 Task 11**

```bash
git add SwiftWeiboFeed/UI SwiftWeiboFeedTests/FeedCellSnapshotTests.swift \
  SwiftWeiboFeedTests/FeedCellReuseTests.swift SwiftWeiboFeedUITests/SwiftWeiboFeedUITests.swift \
  SwiftWeiboFeedTests/SnapshotReferences
git commit -m "test: cover dual feed layouts and accessibility" -m "Co-authored-by: Codex"
```

---

### Task 12：性能埋点、内存压力与最终验收

**文件：**

- Modify: `SwiftWeiboFeed/Performance/FeedSignpost.swift`
- Modify: `SwiftWeiboFeed/Display/AsyncRenderLayer.swift`
- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Modify: `SwiftWeiboFeed/UI/FeedPrefetchCoordinator.swift`
- Modify: `SwiftWeiboFeedTests/PerformanceSmokeTests.swift`
- Modify: `docs/performance/iphone-11-release-acceptance.md`
- Create: `docs/performance/weibo-dual-layout-acceptance.md`

- [ ] **Step 1：增加可验证的计数 Hook**

至少记录：

- `expandStateChange`；
- `expandTailLayout`；
- `expandTailRender`；
- 每个 RenderRegion draw/reuse count；
- `layoutModeSwitch`；
- `collectionVisiblePrepare`；
- `layoutTransition` start/complete/cancel；
- 模式切换时可见/预取准备数量；
- 重复图片请求与 decode count；
- 转场 snapshot 数量和释放结果。

- [ ] **Step 2：写性能/资源失败测试**

断言：

- 单次 body `.more` 的 profile/card/tag/toolbar draw 增量为 0；
- stable prefix draw 增量为 0；
- 只有目标 mutable tail 发生 draw；
- 图片 request/download 不重复；
- 模式切换不重新 parse 500 条；
- 快速来回切换后 executor occupied count 回落；
- memory pressure 清理非可见 region/snapshot，保留当前可见内容；
- 多次切换后弱引用宿主、Cell 和 snapshot 可释放。

- [ ] **Step 3：运行完整 Simulator 测试**

先 `session_show_defaults`，再使用 XcodeBuildMCP `test_sim` 运行整个 `SwiftWeiboFeed` Scheme。

Expected：所有 Unit、Snapshot 和 UI Tests 通过；无新增并发警告、错误图片、旧 generation 提交或高度跳动。

- [ ] **Step 4：运行 Debug/Release 构建验证**

- Debug：`build_sim`；
- Release：`build_sim` 并通过 `extraArgs` 传入 `-configuration Release`、`CODE_SIGNING_ALLOWED=NO`；
- 如需运行交互，只执行一次 `build_run_sim`。

- [ ] **Step 5：Simulator 人工验收**

覆盖：

- 冷/热图片缓存；
- Table 快速滚动与展开；
- Collection Compact/Regular；
- Table/Collection 连续切换；
- 图片加载中切换；
- Dynamic Type、Dark Mode、Reduce Motion；
- 旋转、后台、内存压力；
- 500 条数据双向滚动。

- [ ] **Step 6：iPhone 11 Release 真机验收**

记录：

- OS/Xcode/构建配置；
- 数据量与缓存状态；
- 30 秒双向滚动 FPS、hitch、最长帧；
- `.more` 各区域 layout/draw 计数；
- 模式切换耗时与转场 hitch；
- CPU 峰值、内存峰值和停止操作后的回落；
- parse/layout/render/download/decode P50/P95/P99；
- 图片重复请求数与错位数；
- 切换 20 次后的任务队列和内存是否收敛。

如果 device workflow 未启用，文档中明确标记“待真机”，不得以 Simulator 数值冒充真机结果。

- [ ] **Step 7：更新性能验收记录并提交**

```bash
git add SwiftWeiboFeed/Performance/FeedSignpost.swift \
  SwiftWeiboFeed/Display/AsyncRenderLayer.swift SwiftWeiboFeed/UI \
  SwiftWeiboFeedTests/PerformanceSmokeTests.swift docs/performance
git commit -m "perf: verify incremental expansion and layout transitions" -m "Co-authored-by: Codex"
```

---

## 完成门槛

全部满足后才可宣布完成：

- [ ] 所有新代码位于独立 `codex/` 功能分支；
- [ ] Table 模式现有视觉、滚动、Action、图片和无障碍无回退；
- [ ] `.more` 不再使用 `reloadRows` 触发整 Cell apply；
- [ ] stable prefix、profile、未变化 card/tag/toolbar 位图在展开时复用；
- [ ] body 与 repost body 都能增量展开；
- [ ] Timeline Store 同时支持 Table/Collection 多宽度精确布局；
- [ ] Collection Compact 单列、Regular 双列并使用 FlowLayout；
- [ ] 两种容器共用 Store、Repository、Image Pipeline、Action 和 Cell 内容宿主；
- [ ] 模式切换保持稳定 FeedID 锚点，不回到顶部；
- [ ] Item snapshot 转场可完成、可取消、可 Reduce Motion 降级；
- [ ] 快速复用、展开、切换和旋转均无旧位图提交或图片串位；
- [ ] 全套 Unit、Snapshot、UI、Performance Smoke Tests 通过；
- [ ] Debug 与 Release Simulator 构建成功；
- [ ] iPhone 11 Release 验收完成，或被明确记录为待真机而非伪造结果；
- [ ] 切换和滚动停止后 CPU、任务队列与内存能够收敛；
- [ ] 所有 Commit message 末尾包含 `Co-authored-by: Codex`。

## 推荐执行节奏

为降低风险，按以下四个可独立回退的阶段推进：

```text
阶段 A：Task 0–5
身份/缓存拆分 + Table 增量展开
完成后现有 Table 应已获得独立性能收益

阶段 B：Task 6–9
Adapter 抽取 + Collection FlowLayout + 双按钮
完成后双模式功能正确，即使关闭转场动画也可交付

阶段 C：Task 10–11
跨容器 Item 转场 + 无障碍/视觉回归

阶段 D：Task 12
全量性能、内存与真机验收
```

若某阶段发现性能或一致性问题，应在该阶段修正，不把基础正确性债务带到后续动画阶段。
