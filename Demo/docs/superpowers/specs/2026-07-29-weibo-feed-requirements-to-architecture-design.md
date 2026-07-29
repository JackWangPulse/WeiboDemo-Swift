# Swift UIKit 动态列表：从原始需求到工程架构

日期：2026-07-29

## 1. 文档目的

本文不是从 YYKit Demo 的实现反推设计理由，而是假设团队只有一份产品需求，从零推导 Swift UIKit 动态列表的业务模型、Cell 结构、线程模型、缓存策略和性能方案。

文档重点记录：

- 一开始为什么选择简单方案；
- 用什么证据判断简单方案不再够用；
- 每次演进解决了什么问题；
- 新方案增加了什么成本；
- 最终设计如何映射到当前 Swift 工程。

YYKit 只作为后期验证成熟思路和视觉规则的参考，不作为“必须这样设计”的理由。

## 2. 原始业务需求

使用 Swift 和 UIKit 实现内容社区首页，最低支持 iOS 16。

每条动态可能包含：

- 用户头像、昵称、认证或会员标识；
- 发布时间和发布来源；
- 正文；
- 正文中的 `@用户`、`#话题#`、网页链接和表情；
- 0～9 张图片；
- 一层转发内容；
- 链接卡片或内容标签；
- 转发数、评论数和点赞数。

用户可以：

- 点击头像或昵称进入用户主页；
- 点击 @、话题和链接；
- 点击图片查看大图；
- 展开长正文；
- 点击转发、评论和点赞；
- 下拉刷新并加载更多。

非功能要求：

- 目标设备为 iPhone 11；
- 500 条混合动态连续快速滚动时，体验目标接近 60fps；
- 图片失败不能阻塞文字和其他图片；
- Cell 复用后不能出现图片串位；
- 支持深浅色、字体大小与宽度变化；
- 内存不能随着浏览数量无限增长。

## 3. 需求澄清过程

### 3.1 性能验收不能只有“接近 60fps”

“接近 60fps”必须补充测试设备、构建配置、数据规模、滚动方式、缓存状态和测试时间，否则无法判断方案是否达标。

确认的基准场景：

- iPhone 11 真机；
- Release 构建；
- 500 条混合数据；
- 冷缓存与热缓存分别测试；
- 连续快速滚动 30 秒；
- 包含快速改变滚动方向、正文展开、主题/字体变化和内存压力。

### 3.2 富文本数据契约

需要确认后端是只返回原始正文，还是同时返回 @、话题、链接等结构化实体。

本项目假设后端只返回原始字符串，客户端负责识别：

- 普通文字；
- `@用户`；
- `#话题#`；
- URL；
- `[表情名]`。

这项决定直接影响客户端是否需要独立文本解析模块。

### 3.3 图片布局规则

“支持 0～9 张图片”不足以指导实现，还必须确认每种数量的列数、间距、单图比例和失败占位规则。

V1 规则：

- 单图最大 `240×240pt`，暂按正方形裁剪；
- 四图使用两列；
- 其他多图使用三列；
- 图片间距 `4pt`；
- 最多展示九张；
- 列表加载缩略图，大图页加载原图。

## 4. 从产品行为推导业务模型

### 4.1 用户身份

产品要求点击头像进入对应用户主页，因此必须有稳定、唯一的 `userID`。昵称可能重复或修改，不能作为身份。

产品要求注销用户仍保留动态，但显示“用户已注销”且不可进入主页，因此需要用户状态，而不只是 `userID` 和昵称。

用户信息草案：

```text
FeedUser
- userID
- status
- name
- avatarURL
- verificationType
- verificationReason
- membershipType
- membershipLevel
```

### 4.2 原始事实与展示降级分离

初始候选方案是在 Model 解码时，把空昵称直接替换成“未知用户”。该方案简单，但会丢失“服务端确实缺少昵称”这一事实，也不利于多语言、数据上报和不同页面采用不同降级文案。

最终决定：

- Model 保留原始 `name` 和 `status`；
- 独立 Presentation 规则生成 `displayName`、头像占位、角标和是否允许跳转；
- 默认头像是客户端资源，不进入业务 Model。

示例规则：

```text
status == deleted → “用户已注销”，不可点击
name 有效          → 显示真实昵称
name 缺失          → “未知用户”
```

### 4.3 认证和会员不能只有 Bool

`isVerified` 和 `isMember` 只能表达“有或没有”，不能表达个人认证、企业认证或会员等级。

因此需要类型和等级字段，并对后端未来新增的未知枚举进行降级，不能因为一个未知值导致整条动态解码失败。

### 4.4 动态身份

每条动态需要稳定的 `feedID`，用于：

- 分页去重；
- 缓存索引；
- 展开和点赞状态定位；
- 局部更新；
- 异步结果身份校验。

列表下标不能替代 ID，因为刷新、插入和删除会改变下标。业务 ID 不参与数学计算，客户端内部适合规范化为字符串身份。

### 4.5 正文与布局结果分离

“是否超过六行”依赖屏幕宽度、字体、行高和表情尺寸，应由客户端根据当前环境计算。

业务 Model 只保存完整原始正文，不保存：

- 行数；
- 文本高度；
- 是否截断；
- `More` 的位置。

这些属于某次布局环境下的结果。

### 4.6 文本语义与 UI 表现分离

候选方案 A：Parser 直接生成最终 `NSAttributedString`。

候选方案 B：Parser 先生成与 UIKit 无关的语义片段，再由布局/显示层决定字体、颜色、行高和表情尺寸。

选择 B：

```text
原始字符串
    ↓
ParsedFeedText / TextSpan
    ↓
布局和显示样式
    ↓
NSAttributedString / CTLine / 点击区域
```

这样主题或字体变化时可以复用语义结果，只重新生成布局与显示结果。

### 4.7 图片业务数据

每张图片应尽量包含：

```text
FeedPicture
- thumbnailURL
- originalURL
- pixelWidth
- pixelHeight
```

宽高只是少量 JSON 元数据，并不等于下载原图。即使 V1 使用固定正方形，它们仍有助于后续比例布局、大图预览和异常图片安全校验。

### 4.8 转发结构

候选方案 A：在 `FeedItem` 中堆叠 `repostText`、`repostPictures`、`repostUser` 等字段。

候选方案 B：递归使用 `repost: FeedItem?`。

A 会造成字段重复；B 在没有服务端深度约束时可能产生无限嵌套和复杂 UI。

V1 产品只展示一层转发，因此选择独立 `RepostContent`，复用 User、Picture、Card 等子模型，但不继续递归。

## 5. V1：最小可行 UIKit 方案

第一版以业务正确性和可验证性为目标：

```text
UITableView
+ Auto Layout / automaticDimension
+ UILabel
+ UIImageView
+ 普通区域子 View
+ 简单异步图片加载
```

选择 `UITableView` 的原因是当前页面是单列、纵向、变高时间线。若未来演变为多列、多 Section 或复杂模块，再评估 `UICollectionView`。

Cell 按职责拆分：

```text
FeedCell
├── ProfileView
├── BodyTextView
├── PictureGridView
├── RepostView
└── ToolbarView
```

拆分的主要价值是职责、测试和维护边界，不是自动转移到后台。所有 UIKit 创建和更新仍在主线程。

V1 的意义：

- 建立正确性基准；
- 明确真实 UI 复杂度；
- 提供可对照的性能数据；
- 避免在没有证据时直接承担最高复杂度。

## 6. 从 V1 到预计算布局

### 6.1 升级触发条件

真机 Instruments 显示快速滚动时，富文本测量和复杂约束求解反复占用主线程，并产生超过单帧预算的长帧。

此时才引入预计算，而不是仅凭担忧优化。

### 6.2 布局输入与输出

容器宽度属于布局输入/环境；Cell 高度属于布局输出。

布局环境至少包含：

- 容器宽度和屏幕倍率；
- 字体大小环境；
- 主题或绘制样式版本；
- 展开/收起状态；
- 布局算法版本。

布局结果至少包含：

- Cell 总高度；
- 用户区 frame；
- 正文 frame 与文本行；
- 图片 frames；
- 转发区 frame；
- 卡片和标签 frame；
- 工具栏 frame；
- 表情与交互区域。

只缓存总高度仍会让 Cell 在主线程重新计算内部位置，因此不足以解决问题。

### 6.3 布局缓存身份

布局不能只按 `feedID` 缓存。同一动态在宽度、字体、展开状态或内容版本变化后会产生不同结果。

```text
LayoutIdentity
├── feedID
├── contentVersion
├── containerWidth
├── contentSizeCategory
├── expandedState
└── layoutAlgorithmVersion
```

## 7. V2：Cell 按需后台布局

为避免一步进入复杂协调层，V2 先尝试：

```text
Cell 即将显示
→ 查询布局缓存
→ 未命中则提交后台解析/布局
→ 结果返回后校验身份
→ 应用并刷新
```

为保证基本正确性，需要：

- Cell 复用时取消自己的任务；
- 使用 feedID 和配置版本校验结果；
- 使用最小布局缓存避免重复计算；
- 使用有界后台执行，避免快速滚动创建无限任务。

V2 暴露出新的问题：

- UITableView 在 Cell 出现前就需要精确高度；
- 估算高度切换为精确高度可能造成跳动；
- 多个 Cell 之间难以统一去重、优先级和并发；
- Cell 同时管理解析、布局、缓存、取消、版本和复用，职责过重；
- 快速滚动会积压已经离屏的低价值任务。

## 8. V3：独立准备层

当 V2 的任务协调使 Cell 失控时，解析和布局从 Cell 中拆出。

准备层负责：

- 文本解析；
- 布局计算；
- 解析与布局结果复用；
- 有界并发和有界队列；
- 可见/前方/后方任务优先级；
- 取消与去重；
- 批次发布顺序。

Cell 最终只负责：

- 接收准备完成的数据；
- 应用 frame 与显示内容；
- 管理复用；
- 管理当前图片订阅；
- 转发点击事件。

### 8.1 一致的准备结果

原始动态、解析结果和布局结果组合成一个不可变对象：

```text
PreparedFeedEntry
- item
- parsedText
- parsedRepost
- layout
- identity
```

组合传入可以避免新版正文搭配旧版布局、图片数量与 frame 数组不一致、展开状态与文字行不一致等问题。

### 8.2 三类版本保护

```text
contentVersion
动态内容版本，用于缓存和内容身份

requestGeneration
整批准备请求版本，防止旧环境结果晚完成后覆盖新结果

cellGeneration
某个 Cell 实例的配置次数，防止复用或同一动态重新配置后被旧结果覆盖
```

异步结果提交前必须同时确认：

- 内容身份匹配；
- 布局环境匹配；
- generation 匹配；
- 任务未取消。

## 9. 有界后台调度

后台执行不等于没有性能问题。无限并发会导致 CPU、内存和调度竞争；只有并发限制但队列无限，也会让可见任务等待大量失效任务。

因此需要：

- 有界并发；
- 有界排队容量；
- 相同任务去重；
- 离开工作窗口后取消；
- 可见内容优先；
- 滚动方向前方其次；
- 反方向后方最低。

具体并发数不凭感觉定死，应在目标设备上测量后选择。

## 10. 绘制方案演进

预计算布局完成后，先继续使用普通 UIKit/CoreText 绘制。只有 Instruments 证明文字绘制仍是主线程瓶颈，才引入异步位图绘制。

### 10.1 整 Cell 位图与分区位图

候选 B1：整条 Cell 画成一张大位图。

候选 B2：用户区、正文、转发区和工具栏分别绘制。

选择 B2：

- 单任务更短，取消响应更及时；
- 点赞变化只需更新工具栏；
- 正文展开不必无条件重画全部区域；
- 不存在的可选区域不创建任务；
- 非可见区域可以单独释放。

代价是 Layer、坐标、身份和提交管理更复杂。

每个异步绘制任务需要区域身份和 generation，提交位图前再次验证。

### 10.2 网络图片与文字独立

网络图片不合入文字位图：

```text
文字和背景 → Render Pipeline
头像和内容图 → Image Pipeline
```

原因：

- 图片下载时间不确定；
- 单图失败不能影响正文；
- 图片需要独立缓存、复用和取消；
- 图片完成后可以单独更新；
- 文字无需等待网络。

## 11. 图片管线演进

### 11.1 防止 Cell 串图

网络请求完成顺序不可控，不能依赖“先请求先完成”。

Cell 配置新内容时：

- 取消旧图片订阅；
- 立即显示占位；
- 保存当前 feedID、图片请求和 cellGeneration；
- 结果返回后再次校验；
- 只有完全匹配才提交。

### 11.2 相同请求合并

多个 Cell 请求同一头像时，只执行一个下载和解码任务，其他调用方订阅共享结果。

取消单个订阅者不能误取消其他可见 Cell。只有最后一个订阅者离开时，才取消底层任务。

### 11.3 目标尺寸缩略解码

列表使用缩略图 URL，并按照显示 frame × 屏幕倍率生成目标像素尺寸。

图片请求至少包含：

```text
ImageRequest
- URL
- targetPixelSize
- contentMode
- processorVersion
```

ImagePipeline 在有界后台队列中按目标尺寸解码，避免把 `2000×2000` 图片完整解码后只显示为 `120×120pt`。

### 11.4 两级缓存

```text
压缩数据/HTTP 缓存
- Key：URL 与 HTTP 缓存规则
- Value：JPEG/PNG Data
- 目的：避免重复网络

解码图片内存缓存
- Key：URL + targetPixelSize + contentMode + processorVersion
- Value：CGImage
- 目的：避免重复解码
```

解码缓存按实际位图成本设置上限。V1 可采用 `NSCache`；它提供成本淘汰，但不应宣称为严格 LRU。只有实测命中率不足时再考虑自行实现严格 LRU/LFU。

## 12. 方向性预加载

不能预加载后面全部动态。预加载窗口围绕当前可见范围，并向滚动方向前方扩展一到两屏，仅在反方向保留少量内容。

优先级：

```text
当前可见
> 滚动方向前方
> UITableView 建议预取
> 滚动反方向后方
```

方向变化时更新窗口并取消失去价值的订阅。若可见 Cell 仍需要同一图片，共享底层任务继续执行。

## 13. 错误处理与降级

- 字段缺失：Optional 或安全默认值，不能让整页解码失败；
- 未知枚举：降级为 unknown，不显示无法识别的角标；
- 用户注销：统一文案与占位头像，禁用主页跳转；
- 正文解析失败：退化为普通文本；
- 表情资源缺失：保留原始文本；
- 单张图片失败：保留占位，其余内容继续显示；
- 转发删除：显示删除状态，不丢弃原动态；
- 旧异步结果：身份不匹配时静默丢弃；
- 内存压力：释放缓存、非可见位图和低优先级预取，优先保留可见内容。

缓存只是优化，不是唯一数据来源；任何被清理的解析、布局、绘制或图片结果都必须能够重新生成。

## 14. 验证方法

### 14.1 正确性

- Model 缺失字段、数字/字符串混用和未知枚举；
- 富文本边界、Emoji 与 UTF-16 Range；
- 0～9 图宫格；
- 六行截断与展开；
- 宽度、字体、主题和内容版本导致的缓存失效；
- 快速复用不串图；
- 相同图片请求合并和订阅取消；
- 旧 generation 不能覆盖新结果；
- 图片失败不影响正文；
- 转发删除和用户注销正确降级。

### 14.2 性能

App 内 FPS 面板只用于开发反馈，不能单独作为验收结论。

正式验证使用 iPhone 11 真机 Release 构建与固定的 500 条数据，结合 Instruments 记录：

- FPS、卡顿次数与最长帧；
- 主线程耗时；
- Parse、Layout、Render、Download、Decode、CellApply 的 P50/P95/P99；
- CPU 和内存峰值；
- 停止滚动后的内存回落；
- 图片缓存命中率；
- 相同请求合并率；
- 取消任务数；
- 重复网络请求数；
- 图片错位次数。

性能阶段使用系统 Signpost 记录开始、结束、身份、线程、缓存命中、取消状态和输入规模。避免在滚动热路径大量 `print`。

## 15. 最终模块边界

```text
JSON
  ↓
Domain Model
  ↓
Text Parser
  ↓
Preparation
  ├── Layout Engine
  ├── Cache
  └── Bounded Scheduling
  ↓
Prepared Feed Entry
  ↓
Timeline Store
  ↓
View Controller
  ↓
Feed Cell / Content View
  ├── Render Pipeline
  └── Image Pipeline
```

边界约束：

- Model 不保存 View、frame、UIImage 或 Task；
- Parser 不决定主题、字体和渲染框架；
- Layout 不下载图片；
- Preparation 不操作 Cell；
- Controller 不解析、测量或解码；
- Cell 不生产布局；
- UI 提交在主线程；
- CPU 密集工作使用可取消、有界后台执行。

## 16. 与当前 Swift 工程的追踪关系

当前实现位于 `/Users/jjwang/Documents/SwiftWeiboFeedDemo/Demo/SwiftWeiboFeed`。

| 需求或设计决定 | 当前代码 |
|---|---|
| 容错业务 Model 与稳定身份 | `Domain/FeedModels.swift`、`Domain/FeedIdentity.swift` |
| 用户业务数据与展示降级分离 | `Domain/WeiboUserPresentation.swift` |
| 解析语义与 UI 样式分离 | `Parsing/FeedTextParser.swift`、`Parsing/ParsedFeedText.swift` |
| 表情名称解析为本地资源 | `Parsing/FeedEmoticonResolver.swift` |
| 布局环境参与缓存身份 | `Layout/FeedLayoutEnvironment.swift` |
| Cell 高度与各区域预计算 | `Layout/FeedLayoutEngine.swift` |
| 统一准备与旧批次防覆盖 | `Domain/FeedRepository.swift` |
| 不可变准备结果 | `PreparedFeedEntry`，位于 `Domain/FeedRepository.swift` |
| 列表顺序、精确高度与重准备 | `UI/FeedTimelineStore.swift` |
| Cell 复用和 generation 防护 | `UI/FeedCell.swift` |
| 预计算 frame 的消费与交互区域 | `UI/FeedContentView.swift` |
| 分区异步位图绘制 | `Display/AsyncRenderLayer.swift` |
| 目标尺寸图片请求 | `Images/ImageRequest.swift` |
| 请求合并、缩略解码与预加载 | `Images/SystemImagePipeline.swift` |
| 解码位图成本缓存 | `Images/DecodedImageCache.swift` |
| 方向性有限预加载 | `UI/FeedPrefetchCoordinator.swift` |
| 页面编排与内存压力响应 | `UI/FeedViewController.swift` |

转发结构存在一项有意记录的差异：本文从“V1 只展示一层转发”的产品假设推导出独立 `RepostContent`；当前工程为了贴合原始微博数据，使用了间接递归的 `FeedItem.repost`。这不是文档遗漏，而是两个输入条件产生的不同选择。若继续使用当前递归模型，应补充最大解码/展示深度与异常循环数据的保护。

## 17. 设计过程结论

最终架构不是拿到需求后必须一次性实现的“标准答案”。合理路径是：

```text
先用最简单且能正确满足业务的方案
→ 在固定条件下测量
→ 找到可复现瓶颈
→ 比较候选方案与代价
→ 只增加解决当前问题所需的复杂度
→ 再次验证
```

若团队已有同类项目和可靠数据证明简单方案无法满足目标，可以直接采用成熟方案，但仍应写清证据、边界和代价。

YYKit Demo 的价值在于验证预计算布局、异步绘制、轻量 Cell 和独立图片管线是成熟可行的方向；本项目的设计理由仍来自业务约束、性能测量和逐步演进。
