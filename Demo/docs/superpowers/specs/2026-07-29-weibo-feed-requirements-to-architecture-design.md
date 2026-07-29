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

### 4.1 FeedUser：用户模型推导

#### 4.1.1 用户身份

产品要求点击头像进入对应用户主页，因此必须有稳定、唯一的 `userID`。昵称可能重复或修改，不能作为身份。

产品要求注销用户仍保留动态，但显示“用户已注销”且不可进入主页，因此需要用户状态，而不只是 `userID` 和昵称。

#### 4.1.2 原始事实与展示降级分离

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

#### 4.1.3 认证和会员不能只有 Bool

`isVerified` 和 `isMember` 只能表达“有或没有”，不能表达个人认证、企业认证或会员等级。

因此需要类型和等级字段，并对后端未来新增的未知枚举进行降级，不能因为一个未知值导致整条动态解码失败。

#### 4.1.4 FeedUser 草案

完成身份、注销状态、展示降级、认证和会员的推导后，用户业务模型草案为：

```text
FeedUser
- userID：稳定用户身份
- status：正常、注销或其他业务状态
- name：服务端原始昵称，可缺失
- avatarURL：网络头像地址，可缺失
- verificationType：认证类型，可容忍未知值
- verificationReason：认证说明，可缺失
- membershipType：会员类型，可缺失
- membershipLevel：会员等级，可缺失
```

`FeedUser` 不保存默认头像、最终展示名称、昵称颜色或是否创建点击区域。这些由 Presentation 根据业务事实和当前客户端规则生成。

### 4.2 FeedItem：动态模型推导

#### 4.2.1 动态身份

每条动态需要稳定的 `feedID`，用于：

- 分页去重；
- 缓存索引；
- 展开和点赞状态定位；
- 局部更新；
- 异步结果身份校验。

列表下标不能替代 ID，因为刷新、插入和删除会改变下标。业务 ID 不参与数学计算，客户端内部适合规范化为字符串身份。

#### 4.2.2 正文与布局结果分离

“是否超过六行”依赖屏幕宽度、字体、行高和表情尺寸，应由客户端根据当前环境计算。

业务 Model 只保存完整原始正文，不保存：

- 行数；
- 文本高度；
- 是否截断；
- `More` 的位置。

这些属于某次布局环境下的结果。

#### 4.2.3 文本语义与 UI 表现分离

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

`ParsedFeedText` 是从 `FeedItem.text` 派生出的准备结果，不是服务端业务事实，因此不直接塞入 `FeedItem`。

#### 4.2.4 图片业务数据

每张图片应尽量包含：

```text
FeedPicture
- thumbnailURL
- originalURL
- pixelWidth
- pixelHeight
```

宽高只是少量 JSON 元数据，并不等于下载原图。即使 V1 使用固定正方形，它们仍有助于后续比例布局、大图预览和异常图片安全校验。

#### 4.2.5 转发结构

候选方案 A：在 `FeedItem` 中堆叠 `repostText`、`repostPictures`、`repostUser` 等字段。

候选方案 B：递归使用 `repost: FeedItem?`。

A 会造成字段重复；B 在没有服务端深度约束时可能产生无限嵌套和复杂 UI。

V1 产品只展示一层转发，因此选择独立 `RepostContent`，复用 User、Picture、Card 等子模型，但不继续递归。

#### 4.2.6 FeedItem 草案

完成动态身份、正文、图片和转发结构的推导后，动态业务模型草案为：

```text
FeedItem
- feedID：稳定动态身份
- user：发布者 FeedUser
- createdAt：发布时间
- source：发布设备或来源
- text：完整原始正文
- pictures：[FeedPicture]
- repost：RepostContent?
- card：FeedCard?
- tags：[FeedTag]
- repostCount：转发数
- commentCount：评论数
- likeCount：点赞数
- liked：当前用户是否已点赞
```

一层转发模型草案为：

```text
RepostContent
- sourceItemID：原动态身份
- user：原动态作者
- text：原动态正文
- pictures：[FeedPicture]
- card：FeedCard?
- deleted：原动态是否已删除
```

`FeedItem` 不保存解析后的文本、Cell 高度、区域 frame、绘制位图、图片任务或缓存对象。这些都是可由业务数据和显示环境重新生成的派生状态。

## 5. 从原始正文推导富文本模型

本章不从现有 `FeedTextParser` 的代码反推答案，而是从产品行为逐步设计富文本 Struct、解析规则、布局边界、缓存身份和测试约束。

原始输入只有一段字符串：

```text
你好 @小明，看看 #旅行# https://example.com [微笑]
```

产品要求：

- 普通文字使用正文样式；
- @、话题和 URL 使用可交互样式；
- 点击后产生对应业务意图；
- `[表情名]` 在本地资源存在时显示为图片；
- 资源不存在或语法无效时仍要保留可读正文；
- 宽度和字体变化后重新排版；
- 语义解析不能依赖具体 View。

### 5.1 第一次候选：Parser 直接返回 NSAttributedString

最简单的方案是让 Parser 直接生成最终 `NSAttributedString`：

```text
String
→ Parser
→ NSAttributedString
→ UILabel
```

这个方案适合只有普通文字和少量链接的小页面，但当前需求下存在耦合：

- Parser 必须知道字体和颜色；
- Parser 必须知道深浅色主题；
- Parser 必须加载表情图片；
- 主题或字体变化时需要重新识别语义；
- 点击目标难以与最终导航解耦；
- 更换 UILabel、TextKit 或 CoreText 时可能重写 Parser。

因此选择增加一个与 UIKit 样式无关的中间语义模型。

### 5.2 从 @用户推导 TextSpan 字段

以 `@小明` 为例，显示和点击至少需要知道：

```text
1. 它位于原文中的哪个范围；
2. 它属于哪种语义；
3. 点击后产生什么业务意图。
```

得到第一版草案：

```swift
struct TextSpan: Sendable {
    let range: Range<String.Index>
    let kind: TextSpanKind
    let action: TextAction?
    let emoticonName: String?
}

enum TextSpanKind: Sendable {
    case plain
    case mention
    case topic
    case link
    case emoticon
}
```

Span 不直接执行导航。它只描述点击意图，最终由 Cell 将 Action 交给 Controller 或 Router。

### 5.3 Action 保存闭包还是纯数据

候选 A：Span 保存点击闭包。

```swift
let onTap: () -> Void
```

问题：

- 闭包可能捕获 ViewController 并形成生命周期问题；
- 解析结果无法安全缓存和跨线程传递；
- 缓存可能长期保存已经失效的页面对象；
- Parser 难以独立测试和跨页面复用。

候选 B：Span 保存纯数据枚举。

```swift
enum TextAction: Hashable, Sendable {
    case user(String)
    case topic(String)
    case url(URL)
}
```

选择 B。事件流为：

```text
TextSpan.action
→ ContentView 命中点击区域
→ FeedCell 转发
→ ViewController / Router 执行业务导航
```

### 5.4 为什么 ParsedFeedText 必须保存 source

`Range<String.Index>` 只能与产生它的原字符串配套使用。单独保存“第几个字符到第几个字符”无法恢复语义，也容易在 Emoji 和组合字符处出错。

因此原文和所有 Span 组成一个整体：

```swift
struct ParsedFeedText: Sendable {
    let source: String
    let spans: [TextSpan]
}
```

消费者通过：

```swift
let value = String(parsed.source[span.range])
```

恢复片段文字。Span 不重复保存 `text`，避免 `text` 与 `range` 不一致。

保存 `source` 还有三个作用：

- 构建完整富文本；
- 富文本处理失败时降级为原始正文；
- 为无障碍描述提供完整文本。

进入 `NSAttributedString/CoreText` 边界时，再针对同一份 source 转换：

```swift
let nsRange = NSRange(span.range, in: parsed.source)
```

### 5.5 特殊 Span 还是完整覆盖

候选 A：`spans` 只保存 @、话题、URL 和表情。

候选 B：普通文字也生成 `.plain` Span，使所有 Span 完整覆盖 source。

选择 B。解析结果需要满足：

```text
所有 Span 按原文顺序排列；
Span 之间不能重叠；
Span 之间不能留空；
所有 Span 拼接后必须等于 source。
```

这样显示、无障碍和其他消费者不需要分别计算特殊片段之间的普通文字缺口。

### 5.6 kind、action 和 emoticonName 的组合

候选 A：简单 `kind` 加 Optional 字段。

```swift
struct TextSpan {
    let range: Range<String.Index>
    let kind: TextSpanKind
    let action: TextAction?
    let emoticonName: String?
}
```

候选 B：带关联值的枚举，由编译器禁止非法组合。

```swift
enum TextSpanContent {
    case plain
    case mention(name: String)
    case topic(name: String)
    case link(URL)
    case emoticon(name: String)
}
```

本设计选择 A，原因是下游经常需要统一按 `kind` 过滤和遍历，点击系统也可以统一消费 Optional Action。

代价是类型允许非法组合，因此必须规定：

```text
plain：
action == nil，emoticonName == nil

mention：
action == .user(...)，emoticonName == nil

topic：
action == .topic(...)，emoticonName == nil

link：
action == .url(...)，emoticonName == nil

emoticon：
action == nil，emoticonName != nil
```

不向任意调用者暴露完全自由的初始化方式，而是提供受控构造：

```swift
TextSpan.plain(...)
TextSpan.mention(...)
TextSpan.topic(...)
TextSpan.link(...)
TextSpan.emoticon(...)
```

### 5.7 ParsedFeedText 从一开始采用受控验证

当前讨论选择：不先开放任意 `[TextSpan]`，而是从第一版就验证结果不变量。

```swift
struct ParsedFeedText: Sendable {
    let source: String
    let spans: [TextSpan]

    private init(
        source: String,
        validatedSpans: [TextSpan]
    ) {
        self.source = source
        self.spans = validatedSpans
    }
}
```

受控工厂必须验证：

1. 非空 source 至少有一个 Span；
2. 第一个 Span 从 `source.startIndex` 开始；
3. spans 已按 range 起点排序；
4. 前一个 `upperBound` 等于后一个 `lowerBound`；
5. 最后一个 Span 到 `source.endIndex`；
6. 每个 Range 均与 source 配套；
7. kind、action 与 emoticonName 组合合法。

空字符串对应：

```text
source == ""
spans == []
```

失败策略：

```text
Debug：
断言暴露 Parser 实现错误

Release：
降级为一个覆盖完整 source 的 plain Span
```

服务端的奇怪正文不能导致页面崩溃；结构验证失败通常意味着客户端 Parser Bug。

### 5.8 TextAction 与 FeedAction 的边界

候选 A：富文本定义独立 `TextAction`。

候选 B：整条动态统一使用包含 `.like`、`.comment` 等行为的 `FeedAction`。

从零设计选择 A：

- Parser 不知道点赞、评论和转发；
- 富文本模块可以复用到其他页面；
- 类型上不能给 TextSpan 塞入 `.like`；
- 由 ContentView 或适配层将 TextAction 转换为 FeedAction。

```swift
extension FeedAction {
    init(_ action: TextAction) {
        switch action {
        case let .user(value): self = .user(value)
        case let .topic(value): self = .topic(value)
        case let .url(url): self = .url(url)
        }
    }
}
```

### 5.9 TextSpan 不保存图片、颜色或 CGRect

Span 只回答“这段是什么”，不保存：

- `UIImage/CGImage`；
- 字体、颜色和行高；
- 点击 `CGRect`；
- UIView 或 CALayer；
- 导航闭包。

职责拆分：

```text
TextSpan
→ 语义

EmoticonResourceResolver
→ 表情名称对应哪张本地图片

TextStyle
→ 当前字体、颜色和行高

TextLayout
→ 当前宽度下的行、附件和点击矩形
```

### 5.10 表情资源的处理与降级

`TextSpan` 只保存：

```text
kind = emoticon
emoticonName = "微笑"
```

资源解析顺序：

```text
查找本地表情资源
├── 找到
│   → 将 [微笑] 替换为附件占位
│   → 根据行高设置 width/ascent/descent
│
└── 未找到
    → 不替换
    → 保留原始文字 [微笑]
```

不能先无条件替换为空白，再查找资源。单个表情资源缺失不能导致正文缺字或整段失败。

### 5.11 样式由 TextStyle 与环境提供

Span 不保存显示样式。布局阶段根据 `TextSpanKind + TextStyle` 构建富文本。

```swift
struct TextStyle: Hashable, Sendable {
    let fontSize: Double
    let lineHeight: Double
    let primaryColor: FeedRGBA
    let accentColor: FeedRGBA
}
```

`maximumLines` 属于本次排版约束，而不是文字视觉样式，应作为 `TextLayoutBuilder` 的独立输入。

规则示例：

```text
plain     → primaryColor
mention   → accentColor
topic     → accentColor
link      → accentColor
emoticon  → 根据 lineHeight 计算附件尺寸
```

主题或字体变化时：

```text
ParsedFeedText → 复用
TextStyle      → 变化
TextLayout     → 重建
```

### 5.12 点击 CGRect 必须在布局后产生

一个语义 Span 可能跨越多行，因此不能在 `TextSpan` 中提前保存一个 CGRect。

```swift
struct InteractionRegion: Sendable {
    let rects: [CGRect]
    let action: TextAction
    let accessibilityLabel: String
}
```

使用 `[CGRect]` 是因为同一个 @用户或 URL 可能跨行，对应多个点击矩形。

### 5.13 V1 与优化版的富文本结果不同

V1 先选择简单结果：

```swift
struct RichTextPresentation {
    let attributedText: NSAttributedString
}
```

流程：

```text
FeedItem.text
→ ParsedFeedText
→ RichTextPresentation
→ UILabel 完成排版和绘制
```

当 Instruments 证明 UILabel/CoreText 排版仍是主线程瓶颈后，再升级：

```swift
struct TextLayout {
    let lines: [TextLine]
    let origins: [CGPoint]
    let bounds: CGRect
    let regions: [InteractionRegion]
    let attachments: [TextAttachment]
}
```

优化流程：

```text
FeedItem.text
→ ParsedFeedText
→ 后台构建样式和完成换行
→ TextLayout
→ View 直接消费行、坐标、点击区域和附件
```

如果优化版仍只保存 `NSAttributedString + height`，View 为绘制仍需再次排版，既重复工作，也可能造成后台高度与实际显示不一致。

### 5.14 Parser 候选识别与重叠优先级

候选方案 A：URL、话题、@和表情分别扫描，再按优先级合并。

候选方案 B：从头到尾编写一个统一状态机，一次识别所有类型。

最初倾向 B，认为可以降低时间复杂度。评审后确认，固定四类规则分别扫描为 `4 × n`，统一扫描为 `1 × n`，两者大 O 都是 `O(n)`，主要差异是常数。

V1 选择 A：

- 每类规则容易独立测试；
- URL 和 Unicode 边界更容易维护；
- 正文通常只有数百字符；
- 只有性能数据证明 Parse 是瓶颈时才升级状态机。

识别优先级：

```text
完整 URL
> 话题
> @用户
> 表情
> 普通文字
```

例如：

```text
https://example.com/@jack#intro
```

整体是 URL。内部的 `@jack` 和 `#intro` 不再二次识别，否则会破坏完整 URL。

Parser 流程：

```text
分别产生特殊候选
→ 按优先级拒绝重叠候选
→ 按 range 排序
→ 在空隙中补 plain
→ 验证完整覆盖
→ 创建 ParsedFeedText
```

### 5.15 ParsedText 缓存身份

只按 `feedID` 缓存不够，因为正文可能被编辑；使用包含所有动态字段的粗粒度版本又会让点赞变化无意义地清理解析结果。

选择独立文本身份：

```text
TextContentIdentity
- feedID
- textRevision
```

正文变化：

```text
ParsedFeedText → 失效
TextLayout → 失效
正文渲染结果 → 失效
```

点赞数变化：

```text
ParsedFeedText → 复用
正文 TextLayout → 复用
工具栏显示 → 更新
```

宽度、字体或主题变化：

```text
ParsedFeedText → 复用
TextStyle / TextLayout → 按需重建
```

### 5.16 富文本测试约束

基础测试：

- 空字符串；
- 只有普通文字；
- @、话题、URL 和表情分别识别；
- 相邻特殊片段；
- Emoji 与组合字符；
- 未闭合话题或表情降级为 plain；
- 无效 URL 降级；
- 表情资源缺失保留原文。

重叠测试：

```text
https://example.com/@jack#intro
→ [.link]

#欢迎@小明#
→ [.topic]

#[微笑]#
→ [.topic]

@小明#旅行#[微笑]
→ [.mention, .topic, .emoticon]
```

每个测试还要统一验证：

```swift
let rebuilt = result.spans
    .map { String(result.source[$0.range]) }
    .joined()

XCTAssertEqual(rebuilt, result.source)
```

并检查有序、不重叠、无空隙和字段组合合法。

### 5.17 MVC 中的最终位置与处理顺序

```text
Model
FeedItem.text：服务端原始业务事实

Model 侧解析服务
FeedTextParser：String → ParsedFeedText

Presentation / Layout
ParsedFeedText + TextStyle + Width → RichTextPresentation / TextLayout

View
只消费已经准备好的富文本或布局结果

Controller
触发流程并处理 TextAction，不实现解析和排版算法
```

无论 V1 还是优化版，数据顺序始终是：

```text
原始正文
→ 语义解析
→ 样式构建
→ 文字排版
→ View 显示
```

架构演进改变的是排版发生的位置和结果的精细程度，不改变上述依赖顺序。

### 5.18 与当前实现的差异

当前 Swift 工程已经实现：

- `source + spans`；
- 普通文字完整补齐；
- URL、话题、@和表情的优先级合并；
- `Range<String.Index>`；
- 表情只保存名称；
- 多组边界与重叠测试；
- 优化版 CoreText `TextLayout`。

当前实现与从零设计仍有差异：

- `FeedTextSpan` 使用全局 `FeedAction`，而不是独立 `TextAction`；
- `FeedTextSpan` 公开初始化器允许非法 Optional 组合；
- `ParsedFeedText` 公开初始化器未集中验证有序、无重叠和完整覆盖；
- Parser 算法与测试提供了过程保证，但 Struct 本身未封闭不变量；
- 没有独立 `ParsedTextCache`，Repository 通过 retained 结果复用解析文本；
- `FeedLayoutEngine` 直接读取完整 `FeedLayoutEnvironment`，尚未抽取独立 `TextStyle`。

这些差异不影响当前主链工作，但构成明确的后续重构候选；是否实施仍需结合复用需求、错误风险和性能数据决定。

## 6. V1：最小可行 UIKit 方案

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

## 7. 从 V1 到预计算布局

### 7.1 升级触发条件

真机 Instruments 显示快速滚动时，富文本测量和复杂约束求解反复占用主线程，并产生超过单帧预算的长帧。

此时才引入预计算，而不是仅凭担忧优化。

### 7.2 布局输入与输出

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

### 7.3 布局缓存身份

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

## 8. V2：Cell 按需后台布局

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

## 9. V3：独立准备层

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

### 9.1 一致的准备结果

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

### 9.2 三类版本保护

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

## 10. 有界后台调度

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

## 11. 绘制方案演进

预计算布局完成后，先继续使用普通 UIKit/CoreText 绘制。只有 Instruments 证明文字绘制仍是主线程瓶颈，才引入异步位图绘制。

### 11.1 整 Cell 位图与分区位图

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

### 11.2 网络图片与文字独立

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

## 12. 图片管线演进

### 12.1 防止 Cell 串图

网络请求完成顺序不可控，不能依赖“先请求先完成”。

Cell 配置新内容时：

- 取消旧图片订阅；
- 立即显示占位；
- 保存当前 feedID、图片请求和 cellGeneration；
- 结果返回后再次校验；
- 只有完全匹配才提交。

### 12.2 相同请求合并

多个 Cell 请求同一头像时，只执行一个下载和解码任务，其他调用方订阅共享结果。

取消单个订阅者不能误取消其他可见 Cell。只有最后一个订阅者离开时，才取消底层任务。

### 12.3 目标尺寸缩略解码

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

### 12.4 两级缓存

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

## 13. 方向性预加载

不能预加载后面全部动态。预加载窗口围绕当前可见范围，并向滚动方向前方扩展一到两屏，仅在反方向保留少量内容。

优先级：

```text
当前可见
> 滚动方向前方
> UITableView 建议预取
> 滚动反方向后方
```

方向变化时更新窗口并取消失去价值的订阅。若可见 Cell 仍需要同一图片，共享底层任务继续执行。

## 14. 错误处理与降级

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

## 15. 验证方法

### 15.1 正确性

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

### 15.2 性能

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

## 16. 最终模块边界

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

## 17. 与当前 Swift 工程的追踪关系

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

## 18. 设计过程结论

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
