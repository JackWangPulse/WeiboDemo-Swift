# Swift Weibo Feed 增量展开、双列表布局与转场动画需求文档

日期：2026-08-27  
状态：需求草案，可进入技术方案设计  
适用工程：`SwiftWeiboFeed`

## 1. 文档目的

本轮优化围绕三个相互关联的体验目标展开：

1. 修复点击正文 `.more` 后整条 Cell 重新生成位图的问题；
2. 在同一时间线中提供 `UITableView` 与 `UICollectionView` 两种布局模式；
3. 在两种布局切换时加入以 CollectionView Item 为核心的连续转场动画。

本文定义产品行为、性能边界、状态规则和验收标准。具体类名、文件拆分和实现步骤在后续技术设计与开发计划中确定。

## 2. 背景与现状

### 2.1 当前架构基础

现有 Swift Weibo Feed 已具备：

- Swift + UIKit，最低支持 iOS 16；
- `UITableView` 单列时间线；
- 后台 CoreText 布局；
- profile、body、repost、card、tag、toolbar 分区异步位图绘制；
- 独立图片 Pipeline；
- Layout Cache、预取、取消与 Cell generation 校验；
- 500 条混合数据的性能验证基础。

本轮必须保留上述架构优势，不能为了增加 CollectionView 而把文本测量、图片解码或复杂布局移回主线程。

### 2.2 `.more` 当前问题

当前点击 `.more` 后的实际链路是：

```text
点击 .more
→ FeedTimelineStore.expand 修改展开状态和 contentVersion
→ 清空该条目的 PreparedFeedEntry
→ 重新解析/计算整条 FeedItemLayout
→ reloadRows
→ FeedCell 重新 apply
→ 取消该 Cell 现有渲染
→ profile/body/repost/card/tag/toolbar 全部分区重新提交位图绘制
```

虽然网络图片本身位于独立 Layer，但 Cell 重新应用时仍会重建绑定和请求流程。用户可观察到内容短暂刷新，CPU 也承担了与实际变化范围不相称的工作。

### 2.3 双布局需求的动机

现有 Controller、Cell 和预取逻辑直接围绕 `UITableView` 组织。增加 CollectionView 不能只是复制一套 Controller，否则会产生两份展开状态、缓存、点击处理和预取逻辑，后续行为容易不一致。

本轮要求同一份时间线数据和 UI 状态可以被两种列表容器消费：

- Table 模式：延续当前 `UITableView` 体验；
- Collection 模式：使用 `UICollectionViewFlowLayout`，为后续多列、分区和自定义 Layout 学习与演进留下空间。

## 3. 本轮目标

### 3.1 用户体验目标

- 点击 `.more` 时，已经显示且内容未变化的区域保持原样，不闪白、不出现整 Cell 重绘感；
- 展开内容从原正文尾部自然出现，Cell 高度平滑增长；
- 用户可以通过两个明确按钮在 Table 与 Collection 模式间切换；
- 布局切换时，当前可见内容保持空间连续性，不突然跳回列表顶部；
- Collection 模式具备可感知但不过度的 Item 转场动画；
- 展开状态、滚动位置和当前内容在两种模式间保持一致。

### 3.2 工程目标

- `.more` 只使真正变化的文本尾部和必要几何失效；
- 未变化的 profile、稳定正文前缀、图片内容、卡片、标签和工具栏位图可继续复用；
- TableView 与 CollectionView 共用 Domain、Parsing、Layout、Repository、Timeline Store、Image Pipeline 和交互处理；
- 两种 Cell 容器复用同一个 Feed 内容承载组件，不复制正文绘制实现；
- 主线程仅执行 UIKit 更新、Layer frame 调整和动画提交；
- 保留现有异步结果的 identity、generation 与 cancellation 安全性。

## 4. 非目标

本轮不包含：

- 改为 SwiftUI；
- 引入第三方瀑布流、响应式框架或图片框架；
- 重写微博数据模型或富文本 Parser；
- 增加下拉刷新、分页、评论编辑或发微博业务；
- 改造图片预览页的业务功能；
- 实现任意数量列的 Pinterest 式瀑布流；
- 在 Table 模式和 Collection 模式中展示不同的数据集合；
- 为了动画而生成整屏长期缓存截图。

## 5. 名词与状态定义

### 5.1 展开状态

每条 Feed 需要独立记录：

- 原微博正文：`collapsed` 或 `expanded`；
- 转发微博正文：`collapsed` 或 `expanded`。

状态以稳定 `FeedID` 定位，不能依赖 IndexPath。刷新、插入、删除、模式切换或 Cell 复用后，展开状态仍应指向同一条内容。

V1 只要求“展开”，不提供“收起”。后续若增加收起，必须沿用同一增量失效模型。

### 5.2 布局模式

```text
FeedLayoutMode
├── table
└── collection
```

布局模式属于页面展示状态，不属于 `FeedItem` 业务模型。

### 5.3 锚点 Item

切换布局时，优先选择当前视口中最靠近可视区域中心的 Feed 作为锚点 Item。切换完成后，同一 Feed 应尽量仍位于相近的屏幕位置。

## 6. 功能需求一：`.more` 增量展开

### 6.1 基本交互

1. 正文超过六行时，折叠态显示 `.more`；
2. 点击 `.more` 后，该正文切换为完整内容；
3. `.more` 点击区域在布局更新期间只能触发一次；
4. 展开完成后 `.more` 不再显示，也不能重复触发；
5. 原微博正文与转发正文可以分别展开，互不覆盖状态；
6. 展开过程中 Cell 不得被误判为选中，也不得触发图片或链接 Action。

### 6.2 稳定区域与变化区域

折叠文本不能继续被视为一张不可拆分的大位图。正文渲染结果至少要区分：

```text
Body Render
├── stablePrefix：折叠态与展开态完全相同的正文前缀
└── mutableTail：包含截断尾部、.more 和展开新增行的变化区域
```

点击 `.more` 时：

- `stablePrefix` 的位图内容和 Layer identity 保持不变；
- 仅重新布局/绘制 `mutableTail`；
- body 之后的媒体、转发、卡片、标签和工具栏仅更新 frame；
- 这些下游区域内容未变化时，不重新生成位图；
- 网络图片 Layer 保留当前 `contents`，只改变位置；
- profile 区域不得重新绘制；
- 如果 `.more` 位于转发正文，仅转发正文尾部及其下游几何发生变化。

说明：折叠态最后一行通常包含省略处理和 `.more`，它与展开态对应行不一定像素一致。因此要求复用的是“确认完全相同的稳定前缀”，而不是强行复用整张折叠正文位图。

### 6.3 布局更新

- 展开后的精确高度必须在后台计算；
- 主线程不得同步调用 CoreText 测量；
- 精确布局返回前，旧内容持续可见；
- 新布局通过身份校验后，以批量高度更新应用到当前容器；
- Table 模式使用无 reload 闪烁的行高更新；
- Collection 模式使 FlowLayout 对目标 Item 的尺寸变化失效并更新；
- 更新时保持该 Feed 顶部或 `.more` 点击位置的视觉锚点，避免内容突然上跳；
- 快速滚动导致 Cell 离屏时，允许取消动画，但正确展开状态必须保留。

### 6.4 异步一致性

展开请求必须携带：

- Feed 内容身份；
- 展开对象身份（原正文或转发正文）；
- 当前布局环境；
- 请求 generation；
- 当前 Cell/Item generation。

以下结果不得提交：

- Cell 已复用；
- 用户已切换到新的布局环境；
- 同一 Feed 已产生更新版本；
- 请求被取消；
- 返回结果对应旧展开状态。

### 6.5 展开动画

- 默认动画时长建议为 0.25～0.35 秒，最终值由真机体验确定；
- 新增尾部使用轻微淡入与裁剪区域展开；
- 下游内容随高度变化平滑下移；
- 已显示稳定前缀不做淡出/淡入；
- 开启“减弱动态效果”时取消位移动画，直接应用最终布局或仅使用短淡入；
- 动画期间触摸命中区域使用最终或明确冻结的几何，不能出现误点。

## 7. 功能需求二：TableView / CollectionView 双布局

### 7.1 模式切换入口

导航栏提供两个模式按钮，并在 Collection 模式下额外显示一个布局按钮：

- `Table` 按钮：切换到 UITableView 模式；
- `Collection` 按钮：切换到 UICollectionView 模式；
- `Collection Layout` 按钮：仅在 Collection 模式显示，在单列和多列 FlowLayout 之间切换。

按钮要求：

- 使用 SF Symbols 与文字或清晰的无障碍标签；
- 当前模式对应按钮显示选中态，且重复点击不触发刷新；
- 无障碍标识为 `feed.mode.table`、`feed.mode.collection` 与 `feed.collection.layout.toggle`；
- Collection Layout 按钮的图标与 VoiceOver label 必须表达下一次点击的目标布局；
- VoiceOver 能读出按钮名称、选中状态和用途；
- 模式状态在本次页面生命周期内保持。是否跨启动持久化不属于 V1 强制项。

### 7.2 Table 模式

- 保留当前单列、纵向、动态高度表现；
- 保持现有视觉基准、交互区域、图片加载和预取行为；
- 不因双模式改造引入 estimated height 跳动；
- 现有 `feed.table`、Cell 标识和 UI 测试可继续使用或提供兼容映射。

### 7.3 Collection 模式

- 使用 `UICollectionView`；单列采用 `UICollectionViewFlowLayout`，多列采用自定义瀑布流 `UICollectionViewLayout`；
- V1 采用纵向滚动；
- Compact Width 的网格布局默认双列，Regular Width 默认三列；Collection 内另提供单列 FlowLayout；
- 列数、Section inset 和 Item spacing 由容器有效宽度决定；
- Table Cell 与 Collection Cell 必须复用同一个 `FeedContentView`，保留 CoreText 富文本、表情附件、链接/@/话题、转发区、媒体 Layer、工具栏和点击区域；
- 网格卡片按列宽等比缩放完整 `FeedContentView`，并用每条微博自己的预计算内容高度推导 Item 高度；不得使用统一高宽比、不得裁切长内容，也不得退化为普通 `UILabel.text` 摘要；
- 多列布局把新 Item 放入当前累计高度最短的列，不能按行等待另一列最高 Item，不得产生行式布局的大块垂直空白；
- Item 高度使用预计算结果，不在 `sizeForItemAt` 中同步测量文本；
- 宽度、横竖屏、Split View 或 Dynamic Type 改变时，只使受影响布局环境失效；
- Collection Cell 复用时必须取消旧图片订阅和旧位图任务；
- CollectionView 支持与 TableView 等价的点击、无障碍、内存压力和预取行为。

### 7.4 共用数据与状态

两种模式必须共用：

- 同一个 Repository 与 Timeline Store；
- 同一组 Feed identity；
- 同一份展开状态；
- 同一个图片 Pipeline 与解码缓存；
- 同一套 Action 路由；
- 同一套刷新/数据变更结果；
- 能按不同容器宽度区分的 Layout Cache。

禁止：

- 为 Collection 模式重新读取八份 JSON；
- 切换模式时重新生成 500 条业务模型或重新解析全部正文；
- 用 IndexPath 作为跨容器身份；
- 复制一份独立的 `handle(_ action:)`；
- 让 Table Cell 与 Collection Cell 各自实现一套 Feed 内容绘制逻辑。

### 7.5 滚动位置保持

切换模式时：

1. 记录锚点 FeedID 及其相对视口位置；
2. 新容器完成目标宽度布局后滚动到同一 Feed；
3. 尽量恢复相同相对位置；
4. 如果锚点已被删除，则选择其后最近 Item，再退化到其前 Item；
5. 不得无条件回到第 0 条。

Table 和 Collection 的绝对 `contentOffset` 不要求相同，因为两种布局的 Item 高度和列数可能不同。

## 8. 功能需求三：带 CollectionView Item 的布局转场

### 8.1 转场范围

本轮“转场动画”特指 Table 与 Collection 模式之间的页面内布局切换，不替代现有图片预览或详情页的导航 push 动画。

由于 `UITableView` 不能直接参与 `UICollectionViewTransitionLayout`，Collection 容器必须同时提供单列 `UICollectionViewFlowLayout` 和多列 `UICollectionViewFlowLayout`。进入卡片模式时先把单列 Collection 与当前 Table 阅读锚点对齐，再调用 `setCollectionViewLayout(_:animated:completion:)` 切到多列；返回时先完成多列到单列的反向 Layout Transition，再把显示权交回 Table。

### 8.2 转场行为

- 切换前确定锚点 Feed；
- Collection 单列和多列必须是两个独立的 `UICollectionViewLayout` 对象；
- Item 的位置和尺寸变化必须由 `setCollectionViewLayout` 的布局属性插值驱动，不得以 Cell snapshot 位移动画冒充 CollectionView Layout Transition；
- Table 与 Collection 单列之间只做短交叉淡化，用于跨容器显示权交接；
- Collection 单列与多列之间保持同一数据源和同一批 Item，不执行中间 `reloadData`；
- 动画结束后通过完成态标识确认当前实际 Layout 与模式按钮一致；
- 锚点 Item 的相对 viewport 位置应尽量保持稳定。

### 8.3 动画参数与中断

- 默认采用 0.3～0.45 秒的 ease-in-out 或 spring 动画；
- 动画参数集中管理，不能散落在两个 Controller/Cell 中；
- 动画期间禁止重复启动另一次模式切换，或将新请求安全合并为最终目标模式；
- App 进入后台、旋转、内存警告或页面消失时可以立即完成/取消动画；
- 取消后 UI、选中按钮和实际容器模式必须一致；
- “减弱动态效果”开启时使用无位移切换或短交叉淡化；
- 动画不得持有不可释放的 Cell、图片任务或大尺寸整屏位图；
- Reduce Motion 下直接设置目标 Layout，不执行位置与尺寸插值。

### 8.4 转场期间的数据变化

- 转场期间收到数据刷新时，先以稳定 FeedID 合并数据；
- 若变更不影响可见映射，可在转场完成后应用；
- 若锚点被删除或 Layout Environment 改变，应安全结束当前动画并应用最终状态；
- 旧 generation 的位图或布局结果不得提交到新容器。

## 9. 建议的职责边界

以下是需求对架构提出的边界，不是最终文件命名要求：

```text
FeedViewController
├── FeedLayoutModeState
├── FeedListCoordinator
│   ├── Table Adapter
│   └── Collection Adapter
├── FeedLayoutTransitionCoordinator
└── 共用 Action / Prefetch / Anchor 协调

TableFeedCell ───────┐
                     ├── FeedContentView / FeedContentNode
CollectionFeedCell ─┘

Feed body rendering
├── stablePrefixLayer
└── mutableTailLayer
```

必须满足：

- 容器 Adapter 只处理 UIKit 数据源、复用、尺寸和滚动回调；
- 业务内容与展开状态不进入 Cell；
- Feed 内容承载组件不依赖自己位于 Table Cell 还是 Collection Cell；
- 预取窗口由抽象的可见 Item 范围驱动，不直接绑定 `indexPathsForVisibleRows`；
- Render identity 能区分区域级变化，不能仅用整条 contentVersion 使所有区域失效。

## 10. 性能与资源要求

### 10.1 主线程

主线程允许：

- 处理按钮和点击；
- 读取当前可见 Item；
- 提交 frame、contents 和容器更新；
- 创建和驱动动画；
- 执行轻量 identity 映射。

主线程禁止：

- CoreText 排版；
- 正文解析；
- JSON 读取或解码；
- 图片解码；
- 为转场同步生成大量新 Feed 位图；
- 在切换模式时重新准备全部 500 条精确布局后才响应用户。

### 10.2 增量展开性能验收

在 iPhone 11 Release 基准上，点击单条 `.more`：

- profile 位图绘制任务新增数为 0；
- 未变化的 card、tag、toolbar 位图绘制任务新增数为 0；
- 未变化的网络图片不产生重复下载；
- 稳定正文前缀位图不重新生成；
- 只允许目标正文尾部产生新的 CoreText 布局/绘制工作；
- 动画期间无明显闪烁和持久卡顿；
- 展开前后锚点位置变化符合交互设计。

具体 P95/P99 时间阈值在实现前通过现有版本真机采样建立基线，再在技术方案中冻结。

### 10.3 模式切换性能验收

- 首次进入 Collection 模式可以按可见窗口优先准备，不等待全部 500 条；
- 切换动画期间不进行无界并发排版或绘制；
- 可见 Item 优先于前方预取 Item；
- 快速往返切换后任务队列能够收敛，无持续 CPU 占用；
- 多次切换后内存达到稳定上限，不随切换次数线性增长；
- 无重复图片网络请求和图片串位。

## 11. 可访问性与系统适配

- 两个模式按钮支持 VoiceOver、Button Traits 与 Selected 状态；
- Collection Item 的阅读顺序与视觉顺序一致；
- `.more` 保留可理解的无障碍名称，如“展开全文”；
- 展开完成后 VoiceOver 焦点尽量保留在同一 Feed；
- Dynamic Type 改变后两种容器均重新取得对应环境布局；
- 深色模式切换不能提交旧主题位图；
- 支持 Reduce Motion；
- 屏幕旋转或 Split View 改变宽度时，Collection 列数和 Item 宽度正确更新。

## 12. 错误与降级处理

- 增量尾部布局失败：保留折叠内容和 `.more`，允许再次尝试，不清空 Cell；
- Collection 可见 Item 布局尚未完成：显示几何稳定的占位内容，不用错误宽度强行缩放；
- 转场 snapshot 创建失败：退化为无动画切换，并保持锚点；
- 图片加载失败：继续显示当前占位，不影响布局切换；
- 内存压力：优先取消非可见转场资源和低优先级预渲染，保留当前可见内容；
- 异步结果过期：静默丢弃，不覆盖新模式或新展开状态。

## 13. 测试需求

### 13.1 单元测试

- 原正文与转发正文展开状态独立；
- 同一 `.more` 重复触发只产生一次状态变化；
- stable prefix identity 在展开前后保持一致；
- mutable tail identity 在展开后变化；
- 未变化区域的 render identity 不随正文展开失效；
- 不同容器宽度产生不同 Layout identity；
- FeedID 与 Table/Collection IndexPath 映射正确；
- 锚点选择、删除降级和相对位置计算正确；
- 旧 generation 不能跨模式提交；
- Reduce Motion 返回正确动画策略。

### 13.2 Cell 与复用测试

- Table Cell 与 Collection Cell 均能承载相同 Prepared Feed 内容；
- Collection Cell 快速复用不串图、不提交旧位图；
- 展开后复用再滚回，状态与完整正文正确；
- 模式切换后图片 Layer 位置正确且不重复下载；
- 离屏展开任务取消后再次出现能够恢复准备。

### 13.3 布局测试

- Compact Width Collection 为单列；
- Regular Width Collection 为双列；
- FlowLayout Item 宽度、间距、Section inset 符合规则；
- 展开只改变目标尾部和后续 frame；
- Table 与 Collection 在相同有效内容宽度下呈现相同信息层级；
- 横竖屏、Dynamic Type 和深浅色切换后几何与 identity 正确。

### 13.4 UI 测试

- 两个按钮可见、可点击且选中态正确；
- Table → Collection → Table 后仍停留在同一锚点 Feed 附近；
- 在两种模式中点击 `.more` 均可正确展开；
- 展开状态跨模式保留；
- 动画期间连续点击不会造成两个容器同时可交互；
- Reduce Motion 下正确降级；
- VoiceOver 标识和按钮状态可被自动化验证。

### 13.5 Snapshot 与人工视觉验收

至少覆盖：

- Table 折叠态与展开态；
- Collection Compact 单列折叠态与展开态；
- Collection Regular 双列；
- 原微博展开与转发微博展开；
- 富文本、表情、图片、卡片和标签组合；
- 深浅色；
- 转场开始、中间和结束的关键帧人工检查。

人工验收重点：稳定正文不闪、图片不闪、锚点不跳、无重影、无旧 Cell 瞬间出现。

## 14. 可观测性

现有 Signpost 需要补充或细分：

- `expandStateChange`；
- `expandTailLayout`；
- `expandTailRender`；
- `layoutModeSwitch`；
- `collectionVisiblePrepare`；
- `layoutTransition`；
- 区域级 render cache/复用命中；
- 转场取消原因。

Debug 统计至少能回答：

- 点击一次 `.more` 新增了多少次 layout 和各区域 draw；
- 哪些位图被复用；
- 模式切换准备了多少可见/非可见 Item；
- 转场过程中是否发生旧 generation 提交；
- 切换前后锚点 FeedID 是否一致。

## 15. 验收清单

满足以下全部条件，本轮需求才算完成：

- [ ] 点击 `.more` 不再整 Cell 重新生成位图；
- [ ] 稳定正文前缀及其他未变化区域被复用；
- [ ] 展开高度与下游区域位置平滑更新；
- [ ] 原正文与转发正文都支持正确展开；
- [ ] 导航栏存在 Table 与 Collection 两个切换按钮；
- [ ] Table 模式保持现有功能和视觉；
- [ ] Collection 模式使用 FlowLayout 并适配 Compact/Regular Width；
- [ ] 两种模式共用数据、展开状态、图片 Pipeline 和 Action；
- [ ] 切换模式保留锚点 Feed，不回到顶部；
- [ ] 转场以可见 Item 为单位连续重排，无明显重影或闪烁；
- [ ] Reduce Motion、旋转、后台和中断场景正确降级；
- [ ] Table/Collection 快速复用均不串图、不提交旧位图；
- [ ] 单元测试、Cell 测试、UI 测试和 Snapshot 测试通过；
- [ ] iPhone 11 Release 真机性能验证无相对当前版本的滚动回退；
- [ ] 多次展开和模式切换后 CPU 任务、内存与图片请求能够收敛。

## 16. 推荐实施顺序

为降低一次性改动风险，后续技术方案建议按以下里程碑拆分：

1. 建立区域级 identity 与 `.more` 增量布局/绘制；
2. 抽取容器无关的 Feed 内容承载与列表协调接口；
3. 保持 Table 模式回归通过后加入 CollectionView + FlowLayout；
4. 完成跨容器锚点和状态同步；
5. 增加 Item 级转场动画及中断/Reduce Motion 处理；
6. 完成真机 Instruments、Snapshot 和 UI 回归验收。

每个里程碑应独立可构建、可测试，且不得依赖后续阶段才能恢复当前 Table 模式的正确性。

## 17. 与往期文档的关系

本需求延续以下既有原则：

- 业务 Model 不保存 UI frame 或位图；
- 解析、布局、显示分层；
- 精确布局在 Cell 出现前或按可见优先级后台准备；
- 复杂静态区域异步绘制；
- 网络图片与文字位图独立；
- 通过稳定 ID、Layout Environment 和 generation 防止旧结果覆盖；
- 有界并发、可取消、可观测；
- iPhone 11 Release + 500 条混合 Feed 作为性能基准。

本轮新增的关键原则是：

> 内容版本变化不应自动等价于整条 Feed 所有渲染区域失效；失效范围必须与真实视觉变化范围一致。
