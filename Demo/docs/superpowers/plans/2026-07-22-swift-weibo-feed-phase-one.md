# Swift Weibo Feed Phase One Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an isolated Swift UIKit app target to the existing YYKit demo project that renders the bundled Weibo timeline through parsed immutable models, background CoreText layout, asynchronous region drawing, target-size image loading, lightweight reusable cells, and measurable scrolling performance.

**Architecture:** The app follows the approved `FeedDomain -> FeedParsing -> FeedLayout -> AsyncDisplay/ImagePipeline -> FeedUI` pipeline. Actors protect mutable repository and request state, bounded operation queues perform CPU-heavy work, and the main actor only applies prepared frames and layer contents.

**Tech Stack:** Swift 6 language mode where supported, UIKit, CoreText, CoreGraphics, ImageIO, URLSession, URLCache, XCTest, OSLog/signposts; no third-party runtime dependencies.

## Global Constraints

- Add a new `SwiftWeiboFeed` iOS application target and `SwiftWeiboFeedTests` unit-test target to `YYKitDemo.xcodeproj`; do not migrate or modify the existing Objective-C target's behavior.
- Set the new app deployment target to iOS 16.0 and supported device families to iPhone and iPad.
- Reuse `YYKitDemo/weibo_0.json` through `YYKitDemo/weibo_7.json`, `YYKitDemo/ResourceWeibo.bundle`, and `YYKitDemo/EmoticonWeibo.bundle` as resources of the new target.
- The Swift target must not link or import YYKit, YYText, YYWebImage, Kingfisher, Nuke, or another third-party runtime library.
- CoreText layout, semantic parsing, bitmap drawing, image downsampling, image decoding, JSON decoding, and disk I/O must not run on the main actor.
- Cells use explicit frames for per-feed geometry and never synchronously measure content from table-view callbacks.
- Async results must validate item identity, content version, layout environment, render region, and cell generation before UI submission.
- First-phase text supports tappable mention/topic/link spans and accessibility, but not selection or copying.
- Validate performance on an iPhone 11 Release build with at least 500 mixed items; simulator tests are correctness checks, not the final 60 fps proof.

---

## Planned File Structure

```text
SwiftWeiboFeed/
├── App/
│   ├── AppDelegate.swift
│   └── SceneDelegate.swift
├── Domain/
│   ├── FeedModels.swift
│   ├── FeedIdentity.swift
│   └── FeedRepository.swift
├── Parsing/
│   ├── FeedAction.swift
│   ├── ParsedFeedText.swift
│   └── FeedTextParser.swift
├── Layout/
│   ├── FeedLayoutEnvironment.swift
│   ├── TextLayout.swift
│   ├── FeedItemLayout.swift
│   ├── FeedLayoutEngine.swift
│   └── FeedLayoutCache.swift
├── Display/
│   ├── RenderIdentity.swift
│   ├── AsyncDisplayTask.swift
│   └── AsyncRenderLayer.swift
├── Images/
│   ├── ImageRequest.swift
│   ├── ImagePipeline.swift
│   ├── DecodedImageCache.swift
│   └── SystemImagePipeline.swift
├── UI/
│   ├── FeedCell.swift
│   ├── FeedContentView.swift
│   ├── FeedViewController.swift
│   └── FeedPrefetchCoordinator.swift
├── Performance/
│   └── FeedSignpost.swift
└── Resources/
    └── Info.plist

SwiftWeiboFeedTests/
├── Fixtures/FeedFixtureLoader.swift
├── FeedModelsTests.swift
├── FeedTextParserTests.swift
├── FeedLayoutEngineTests.swift
├── AsyncRenderLayerTests.swift
├── SystemImagePipelineTests.swift
├── FeedRepositoryTests.swift
└── FeedCellReuseTests.swift
```

Each file owns one responsibility. Do not combine the parser, layout engine, image pipeline, or cell into a single convenience file.

---

### Task 1: Isolated Swift App and Test Targets

**Files:**
- Modify: `YYKitDemo.xcodeproj/project.pbxproj`
- Create: `SwiftWeiboFeed/App/AppDelegate.swift`
- Create: `SwiftWeiboFeed/App/SceneDelegate.swift`
- Create: `SwiftWeiboFeed/Resources/Info.plist`
- Create: `SwiftWeiboFeedTests/TargetSmokeTests.swift`

**Interfaces:**
- Consumes: existing Xcode project and bundled Weibo resources.
- Produces: buildable `SwiftWeiboFeed` and testable `SwiftWeiboFeedTests` schemes.

- [ ] **Step 1: Add a failing target smoke test**

```swift
import XCTest
@testable import SwiftWeiboFeed

final class TargetSmokeTests: XCTestCase {
    func testTargetLoads() {
        XCTAssertEqual(SwiftWeiboFeedConfiguration.minimumOSMajorVersion, 16)
    }
}
```

- [ ] **Step 2: Add the app entry points and configuration**

```swift
import UIKit

enum SwiftWeiboFeedConfiguration {
    static let minimumOSMajorVersion = 16
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
```

```swift
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UINavigationController(rootViewController: UIViewController())
        window.makeKeyAndVisible()
        self.window = window
    }
}
```

- [ ] **Step 3: Add both targets, shared scheme, resource membership, and iOS 16 settings**

Set `PRODUCT_MODULE_NAME = SwiftWeiboFeed`, `SWIFT_VERSION = 6.0`, `IPHONEOS_DEPLOYMENT_TARGET = 16.0`, `TARGETED_DEVICE_FAMILY = "1,2"`, and include the eight JSON files plus both bundles in the new app Copy Bundle Resources phase. Link only Apple frameworks required by imports.

- [ ] **Step 4: Build and run the smoke test**

Run:

```bash
xcodebuild -project YYKitDemo.xcodeproj -scheme SwiftWeiboFeed -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath /tmp/SwiftWeiboFeedDerivedData test
```

Expected: build succeeds and `TargetSmokeTests.testTargetLoads` passes. If that named runtime is unavailable, replace only the destination with an installed iOS simulator and record it in the execution notes.

- [ ] **Step 5: Commit**

```bash
git add YYKitDemo.xcodeproj/project.pbxproj SwiftWeiboFeed SwiftWeiboFeedTests/TargetSmokeTests.swift
git commit -m "feat: add isolated Swift Weibo feed target"
```

---

### Task 2: Domain Models and Fixture Decoding

**Files:**
- Create: `SwiftWeiboFeed/Domain/FeedModels.swift`
- Create: `SwiftWeiboFeed/Domain/FeedIdentity.swift`
- Create: `SwiftWeiboFeedTests/Fixtures/FeedFixtureLoader.swift`
- Create: `SwiftWeiboFeedTests/FeedModelsTests.swift`

**Interfaces:**
- Consumes: bundled `weibo_0.json` through `weibo_7.json`.
- Produces: `FeedItem`, `FeedID`, `FeedContentIdentity`, and `FeedPage` as Codable, Hashable, Sendable values.

- [ ] **Step 1: Write decoding tests for real fixtures and missing optional fields**

```swift
final class FeedModelsTests: XCTestCase {
    func testDecodesBundledTimeline() throws {
        let data = try FeedFixtureLoader.data(named: "weibo_0")
        let page = try JSONDecoder.weibo.decode(FeedPage.self, from: data)
        XCTAssertFalse(page.items.isEmpty)
        XCTAssertFalse(page.items[0].id.rawValue.isEmpty)
    }

    func testMissingOptionalMediaDoesNotFailItem() throws {
        let json = #"{"statuses":[{"id":1,"text":"hello","user":{"id":2,"name":"A"}}]}"#.data(using: .utf8)!
        let page = try JSONDecoder.weibo.decode(FeedPage.self, from: json)
        XCTAssertEqual(page.items[0].pictures, [])
        XCTAssertNil(page.items[0].repost)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
xcodebuild -project YYKitDemo.xcodeproj -scheme SwiftWeiboFeed -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath /tmp/SwiftWeiboFeedDerivedData -only-testing:SwiftWeiboFeedTests/FeedModelsTests test
```

Expected: compile fails because `FeedPage` and fixture helpers do not exist.

- [ ] **Step 3: Implement tolerant DTO-aligned models and identity**

Define exact public domain signatures:

```swift
struct FeedID: RawRepresentable, Hashable, Codable, Sendable { let rawValue: String }
struct FeedContentIdentity: Hashable, Sendable { let itemID: FeedID; let contentVersion: UInt }
struct FeedPage: Decodable, Sendable { let items: [FeedItem] }
struct FeedItem: Decodable, Hashable, Sendable {
    let id: FeedID
    let user: FeedUser
    let text: String
    let pictures: [FeedPicture]
    let repost: FeedItem?
    let card: FeedCard?
    let tags: [FeedTag]
    let repostCount: Int
    let commentCount: Int
    let likeCount: Int
}
```

Map fixture keys such as `statuses`, `retweeted_status`, `pics`, `page_info`, `tag_struct`, `reposts_count`, `comments_count`, and `attitudes_count`. Decode numeric IDs through a small `LosslessStringID` helper so string and number representations both work. Default absent arrays and counts to empty or zero; require only stable ID, text, and user identity/name.

- [ ] **Step 4: Run all model tests**

Expected: real fixtures decode, the missing-media example passes, and no test imports UIKit.

- [ ] **Step 5: Commit**

```bash
git add SwiftWeiboFeed/Domain SwiftWeiboFeedTests/Fixtures SwiftWeiboFeedTests/FeedModelsTests.swift
git commit -m "feat: decode Weibo feed domain models"
```

---

### Task 3: Semantic Rich-Text Parser

**Files:**
- Create: `SwiftWeiboFeed/Parsing/FeedAction.swift`
- Create: `SwiftWeiboFeed/Parsing/ParsedFeedText.swift`
- Create: `SwiftWeiboFeed/Parsing/FeedTextParser.swift`
- Create: `SwiftWeiboFeedTests/FeedTextParserTests.swift`

**Interfaces:**
- Consumes: `String` plus optional server URL/topic metadata from `FeedItem`.
- Produces: `FeedTextParser.parse(_:) -> ParsedFeedText`, where spans preserve valid Swift String indices and expose `FeedAction`.

- [ ] **Step 1: Write table-driven parser tests**

```swift
func testParsesMixedSemanticText() throws {
    let result = parser.parse("@alice 看#Swift# https://t.cn/a [笑哭]")
    XCTAssertEqual(result.spans.map(\.kind), [.mention, .plain, .topic, .plain, .link, .plain, .emoticon])
    XCTAssertEqual(result.spans.compactMap(\.action).count, 3)
}

func testMalformedUnicodeNeverCreatesOutOfBoundsRange() {
    let source = "👨‍👩‍👧‍👦 @甲 #未闭合 [坏"
    let result = parser.parse(source)
    XCTAssertTrue(result.spans.allSatisfy { $0.range.lowerBound >= source.startIndex && $0.range.upperBound <= source.endIndex })
}
```

- [ ] **Step 2: Run tests and verify missing-type failure**

- [ ] **Step 3: Implement deterministic overlap resolution**

Expose:

```swift
enum FeedSpanKind: Hashable, Sendable { case plain, mention, topic, link, emoticon }
enum FeedAction: Hashable, Sendable { case user(String), topic(String), url(URL), expand(FeedID), repost, comment, like }
struct FeedTextSpan: Hashable, Sendable { let kind: FeedSpanKind; let range: Range<String.Index>; let action: FeedAction?; let emoticonName: String? }
struct ParsedFeedText: Sendable { let source: String; let spans: [FeedTextSpan] }
struct FeedTextParser: Sendable { func parse(_ source: String) -> ParsedFeedText }
```

Match links before topics, mentions, and emoticons; discard lower-priority overlapping matches; fill unmatched gaps with `.plain`; retain the original emoticon token when a resource cannot later be found.

- [ ] **Step 4: Run parser tests under Thread Sanitizer once**

Expected: all parser tests pass with no race or String-index trap.

- [ ] **Step 5: Commit**

```bash
git add SwiftWeiboFeed/Parsing SwiftWeiboFeedTests/FeedTextParserTests.swift
git commit -m "feat: parse semantic Weibo text"
```

---

### Task 4: CoreText Layout Primitives and Cache

**Files:**
- Create: `SwiftWeiboFeed/Layout/FeedLayoutEnvironment.swift`
- Create: `SwiftWeiboFeed/Layout/TextLayout.swift`
- Create: `SwiftWeiboFeed/Layout/FeedItemLayout.swift`
- Create: `SwiftWeiboFeed/Layout/FeedLayoutCache.swift`
- Create: `SwiftWeiboFeedTests/FeedLayoutEngineTests.swift`

**Interfaces:**
- Consumes: `FeedContentIdentity`, `ParsedFeedText`, and `FeedLayoutEnvironment`.
- Produces: immutable `TextLayout`, `InteractionRegion`, `FeedItemLayout`, and `FeedLayoutCache` APIs used by Tasks 5-9.

- [ ] **Step 1: Write layout-invariant and cache-key tests**

```swift
func testLayoutEnvironmentUsesPixelWidth() {
    let a = FeedLayoutEnvironment(width: 390, scale: 3, contentSizeCategory: .large, themeVersion: 1, algorithmVersion: 1)
    XCTAssertEqual(a.containerPixelWidth, 1170)
}

func testNineImageLayoutIsFiniteAndInsideCell() async throws {
    let layout = try await engine.layout(fixture: .nineImages, environment: environment)
    XCTAssertEqual(layout.mediaFrames.count, 9)
    XCTAssertTrue(layout.allFrames.allSatisfy(\.isFiniteAndNonNegative))
    XCTAssertTrue(layout.allFrames.allSatisfy { $0.maxY <= layout.height })
}
```

- [ ] **Step 2: Run tests and verify failure**

- [ ] **Step 3: Implement immutable layout value types and NSCache wrapper**

Required signatures:

```swift
struct FeedLayoutEnvironment: Hashable, Sendable {
    let containerPixelWidth: Int
    let displayScale: Int
    let contentSizeCategory: String
    let themeVersion: UInt
    let layoutAlgorithmVersion: UInt
}
struct FeedLayoutIdentity: Hashable, Sendable { let content: FeedContentIdentity; let environment: FeedLayoutEnvironment }
struct InteractionRegion: Sendable { let rects: [CGRect]; let action: FeedAction; let accessibilityLabel: String }
final class CoreTextLayoutStorage: @unchecked Sendable { let lines: [CTLine]; let origins: [CGPoint] }
struct TextLayout: Sendable { let storage: CoreTextLayoutStorage; let bounds: CGRect; let regions: [InteractionRegion] }
struct FeedItemLayout: Sendable { let identity: FeedLayoutIdentity; let height: CGFloat; let body: TextLayout; let avatarFrame: CGRect; let mediaFrames: [CGRect]; let repost: RepostLayout?; let toolbar: ToolbarLayout }
final class FeedLayoutCache: @unchecked Sendable { func value(for key: FeedLayoutIdentity) -> FeedItemLayout?; func insert(_ value: FeedItemLayout, cost: Int); func removeAllExcept(_ keys: Set<FeedLayoutIdentity>) }
```

- [ ] **Step 4: Run invariant tests and verify cache invalidation by width/theme/version**

Expected: all geometry is finite; changing any environment component causes a cache miss.

- [ ] **Step 5: Commit**

```bash
git add SwiftWeiboFeed/Layout SwiftWeiboFeedTests/FeedLayoutEngineTests.swift
git commit -m "feat: define immutable feed layout primitives"
```

---

### Task 5: Background Feed Layout Engine

**Files:**
- Create: `SwiftWeiboFeed/Layout/FeedLayoutEngine.swift`
- Modify: `SwiftWeiboFeedTests/FeedLayoutEngineTests.swift`

**Interfaces:**
- Consumes: `FeedItem`, parsed body/repost text, and `FeedLayoutEnvironment`.
- Produces: `FeedLayoutEngine.layout(item:parsedBody:parsedRepost:environment:) async throws -> FeedItemLayout`.

- [ ] **Step 1: Add exact-height, interaction, repost, and cancellation tests**

Write tests that compare repeated layout results, assert one interaction region for each semantic action, verify one/four/nine media geometry, and cancel a queued operation before it begins.

- [ ] **Step 2: Run tests and verify the engine is missing**

- [ ] **Step 3: Implement a bounded OperationQueue engine**

Use `maxConcurrentOperationCount = 2`. Build attributed strings from semantic spans, create CTLines off-main, fix line height through explicit paragraph/line metrics, calculate all frames, and throw `CancellationError` before expensive stages and before returning. Truncate content above the phase-one limit and append an `.expand(itemID)` region.

- [ ] **Step 4: Assert the engine never runs on the main thread in tests**

Inject a test hook called at layout start and assert `Thread.isMainThread == false`. Run all layout tests.

- [ ] **Step 5: Commit**

```bash
git add SwiftWeiboFeed/Layout/FeedLayoutEngine.swift SwiftWeiboFeedTests/FeedLayoutEngineTests.swift
git commit -m "feat: compute CoreText feed layouts off main"
```

---

### Task 6: Asynchronous Region Drawing

**Files:**
- Create: `SwiftWeiboFeed/Display/RenderIdentity.swift`
- Create: `SwiftWeiboFeed/Display/AsyncDisplayTask.swift`
- Create: `SwiftWeiboFeed/Display/AsyncRenderLayer.swift`
- Create: `SwiftWeiboFeedTests/AsyncRenderLayerTests.swift`

**Interfaces:**
- Consumes: immutable layout region, scale, and `RenderIdentity`.
- Produces: cancellable asynchronous bitmap rendering with main-actor identity-checked submission.

- [ ] **Step 1: Write the stale-result race test**

Create a controllable executor where render A blocks, render B completes for the next generation, then A completes. Assert only B reaches the layer's commit spy.

- [ ] **Step 2: Run and verify missing renderer failure**

- [ ] **Step 3: Implement the renderer**

Required types:

```swift
enum RenderRegion: Hashable, Sendable { case headerBody, repost, cardTag, toolbar }
struct RenderIdentity: Hashable, Sendable { let layout: FeedLayoutIdentity; let region: RenderRegion; let generation: UInt }
final class DisplayCancellationToken: @unchecked Sendable { func cancel(); var isCancelled: Bool { get } }
struct AsyncDisplayTask: @unchecked Sendable { let identity: RenderIdentity; let size: CGSize; let scale: CGFloat; let draw: (CGContext, DisplayCancellationToken) -> Void }
final class AsyncRenderLayer: CALayer { func display(_ task: AsyncDisplayTask); func cancelDisplay() }
```

Use a queue with concurrency 2, create bitmap contexts off-main, check cancellation before context creation, between semantic drawing groups, before image creation, and before `contents` submission.

- [ ] **Step 4: Run race, cancellation, and zero-size tests**

Expected: stale A never commits, cancellation commits nothing, and zero-size tasks are rejected without allocation.

- [ ] **Step 5: Commit**

```bash
git add SwiftWeiboFeed/Display SwiftWeiboFeedTests/AsyncRenderLayerTests.swift
git commit -m "feat: draw feed regions asynchronously"
```

---

### Task 7: Replaceable System Image Pipeline

**Files:**
- Create: `SwiftWeiboFeed/Images/ImageRequest.swift`
- Create: `SwiftWeiboFeed/Images/ImagePipeline.swift`
- Create: `SwiftWeiboFeed/Images/DecodedImageCache.swift`
- Create: `SwiftWeiboFeed/Images/SystemImagePipeline.swift`
- Create: `SwiftWeiboFeedTests/SystemImagePipelineTests.swift`

**Interfaces:**
- Consumes: URL and exact target pixel geometry.
- Produces: `ImagePipeline.image(for:) async throws -> ImageResponse`, prefetch, cancellation through Task, decoded `CGImage`, request coalescing, and cost-based memory caching.

- [ ] **Step 1: Write URLProtocol-backed cache, coalescing, cancellation, and downsampling tests**

Assert two identical concurrent requests cause one protocol load; two target sizes use distinct cache keys; cancelling one waiter does not fail the other; a 4000-pixel fixture requested at 300 pixels returns a result no larger than the allowed target envelope.

- [ ] **Step 2: Run tests and verify missing pipeline failure**

- [ ] **Step 3: Implement the protocol and system pipeline**

```swift
struct PixelSize: Hashable, Sendable { let width: Int; let height: Int }
enum ImageContentMode: Hashable, Sendable { case aspectFill, aspectFit }
struct ImageRequest: Hashable, Sendable { let url: URL; let targetPixelSize: PixelSize; let contentMode: ImageContentMode; let processorVersion: UInt }
struct ImageResponse: @unchecked Sendable { let request: ImageRequest; let image: CGImage }
protocol ImagePipeline: Sendable { func image(for request: ImageRequest) async throws -> ImageResponse; func prefetch(_ requests: [ImageRequest]) async; func cancelPrefetch(_ requests: [ImageRequest]) async }
```

Use an actor for in-flight task and subscriber state, URLSession configured with URLCache, an NSCache whose cost is decoded bytes, and a decode operation queue with concurrency 2. Implement ImageIO thumbnail creation with transform and immediate caching before returning.

- [ ] **Step 4: Run tests and inspect for main-thread decode**

Expected: all tests pass; an injected decode hook always observes a non-main thread.

- [ ] **Step 5: Commit**

```bash
git add SwiftWeiboFeed/Images SwiftWeiboFeedTests/SystemImagePipelineTests.swift
git commit -m "feat: add replaceable downsampling image pipeline"
```

---

### Task 8: Repository, Change Sets, and Layout Preparation

**Files:**
- Create: `SwiftWeiboFeed/Domain/FeedRepository.swift`
- Create: `SwiftWeiboFeedTests/FeedRepositoryTests.swift`

**Interfaces:**
- Consumes: decoded `FeedPage` and a layout-preparation closure.
- Produces: ordered prepared entries and `[FeedChange]` with insert/delete/move/content/toolbar-only cases.

- [ ] **Step 1: Write de-duplication, version, toolbar-only, and stale-preparation tests**

Verify duplicate IDs are stored once; body changes increment content version; count-only changes emit `.toolbarChanged`; an older preparation finishing after a newer page cannot replace the current layout.

- [ ] **Step 2: Run tests and verify failure**

- [ ] **Step 3: Implement the repository actor**

```swift
enum FeedChange: Sendable { case inserted(FeedID, Int), deleted(FeedID, Int), moved(FeedID, Int, Int), contentChanged(FeedID), toolbarChanged(FeedID) }
struct PreparedFeedEntry: Sendable { let item: FeedItem; let identity: FeedContentIdentity; let parsed: ParsedFeedText; let layout: FeedItemLayout }
actor FeedRepository { func apply(page: FeedPage, environment: FeedLayoutEnvironment) async throws -> [FeedChange]; func snapshot() -> [PreparedFeedEntry] }
```

Keep long parsing/layout work outside actor isolation, then re-enter and validate the content generation before storing results.

- [ ] **Step 4: Run repository and Thread Sanitizer tests**

- [ ] **Step 5: Commit**

```bash
git add SwiftWeiboFeed/Domain/FeedRepository.swift SwiftWeiboFeedTests/FeedRepositoryTests.swift
git commit -m "feat: coordinate versioned feed updates"
```

---

### Task 9: Lightweight Feed Cell and Interaction Routing

**Files:**
- Create: `SwiftWeiboFeed/UI/FeedContentView.swift`
- Create: `SwiftWeiboFeed/UI/FeedCell.swift`
- Create: `SwiftWeiboFeedTests/FeedCellReuseTests.swift`

**Interfaces:**
- Consumes: `PreparedFeedEntry`, `AsyncRenderLayer`, and `any ImagePipeline`.
- Produces: explicit-frame rendering, safe reuse, image-layer assignment, hit testing, and virtual accessibility elements.

- [ ] **Step 1: Write cell reuse and stale-image tests**

Apply item A, begin controllable image and draw tasks, call `prepareForReuse`, apply B, finish B then A, and assert only B's bitmap and images are installed. Assert `generation` increments and local task subscriptions cancel.

- [ ] **Step 2: Run tests and verify missing cell failure**

- [ ] **Step 3: Implement semantic render regions and lightweight image layers**

`FeedContentView.apply(_:)` performs only frame assignments. `FeedCell.apply(_:pipeline:)` captures represented ID and generation, starts region draws, requests target-size images, and validates all identity fields before setting `contents`. Reuse clears content and cancels local subscriptions. Do not create per-span views or buttons.

- [ ] **Step 4: Implement hit testing and accessibility from layout regions**

Map touches to `InteractionRegion.action`, use one transient highlight layer, and create `UIAccessibilityElement` objects for profile, body, semantic actions, media, and toolbar. Add tests for topic hit mapping and accessible toolbar labels.

- [ ] **Step 5: Run all FeedCell tests and commit**

```bash
git add SwiftWeiboFeed/UI/FeedContentView.swift SwiftWeiboFeed/UI/FeedCell.swift SwiftWeiboFeedTests/FeedCellReuseTests.swift
git commit -m "feat: render prepared feed entries in lightweight cells"
```

---

### Task 10: Timeline Controller and Directional Prefetch

**Files:**
- Create: `SwiftWeiboFeed/UI/FeedPrefetchCoordinator.swift`
- Create: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Modify: `SwiftWeiboFeed/App/SceneDelegate.swift`
- Create: `SwiftWeiboFeedTests/FeedPrefetchCoordinatorTests.swift`

**Interfaces:**
- Consumes: repository snapshots, image pipeline, table prefetch callbacks, and bundled pages.
- Produces: visible timeline, exact row heights, batched updates, and bounded directional preparation.

- [ ] **Step 1: Write prefetch window and priority tests**

Verify visible items outrank forward-prefetch items, reversing scroll direction cancels distant old-direction work, and queue pressure drops low-priority rendering before layout.

- [ ] **Step 2: Run tests and verify missing coordinator failure**

- [ ] **Step 3: Implement the controller and coordinator**

Load the eight JSON fixtures off-main, duplicate the decoded list until it contains at least 500 items using derived stable IDs, prepare exact layouts, then publish a snapshot on MainActor. Return `entry.layout.height` directly from `heightForRowAt`; never call measurement APIs from table callbacks. Conform to `UITableViewDataSourcePrefetching` and use a one-to-two-screen forward window with a smaller trailing window.

- [ ] **Step 4: Connect SceneDelegate and run the application**

Expected: the new scheme launches directly into the timeline; content, media, reposts, tags, toolbar, semantic taps, reuse, and rotation work without height jumps or wrong images.

- [ ] **Step 5: Commit**

```bash
git add SwiftWeiboFeed/UI SwiftWeiboFeed/App/SceneDelegate.swift SwiftWeiboFeedTests/FeedPrefetchCoordinatorTests.swift
git commit -m "feat: present prefetched Swift Weibo timeline"
```

---

### Task 11: Instrumentation, Memory Pressure, and Final Verification

**Files:**
- Create: `SwiftWeiboFeed/Performance/FeedSignpost.swift`
- Modify: `SwiftWeiboFeed/Parsing/FeedTextParser.swift`
- Modify: `SwiftWeiboFeed/Layout/FeedLayoutEngine.swift`
- Modify: `SwiftWeiboFeed/Display/AsyncRenderLayer.swift`
- Modify: `SwiftWeiboFeed/Images/SystemImagePipeline.swift`
- Modify: `SwiftWeiboFeed/UI/FeedViewController.swift`
- Create: `SwiftWeiboFeedTests/PerformanceSmokeTests.swift`
- Create: `SwiftWeiboFeedTests/FeedCellSnapshotTests.swift`

**Interfaces:**
- Consumes: timings from all pipeline stages and system memory-pressure notifications.
- Produces: `os_signpost` intervals, cache/window degradation, benchmark tests, and a recorded Release-device acceptance procedure.

- [ ] **Step 1: Write performance smoke tests**

Measure parsing and layout over representative ordinary and complex fixtures using `XCTClockMetric` and assert cell application performs no synchronous parser, layout, or decode hook calls.

- [ ] **Step 2: Add signpost intervals**

Create signpost names `feed.parse`, `feed.layout`, `feed.display`, `image.download`, `image.decode`, and `cell.apply`. Instrument start/end paths including cancellation and error exits.

- [ ] **Step 3: Implement memory-pressure degradation**

On memory pressure, clear nonvisible region bitmaps, decoded image cache, distant layouts, and low-priority prefetch work in that order while retaining visible identities and layouts. Add a test-only trigger and assert visible entries survive.

- [ ] **Step 4: Add representative cell snapshot coverage**

Render deterministic cells into image contexts at iPhone 11 width and compare stored PNG references for plain text, long text, one/four/nine images, repost text, repost media, card, place tag, rich semantic text, image placeholder, and image failure. Fail with an output diff path when changed pixels exceed the documented one-pixel antialiasing tolerance.

- [ ] **Step 5: Run the full automated suite**

Run:

```bash
xcodebuild -project YYKitDemo.xcodeproj -scheme SwiftWeiboFeed -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath /tmp/SwiftWeiboFeedDerivedData test
```

Expected: all tests pass with zero Thread Sanitizer findings in the dedicated sanitizer run. Then run:

```bash
xcodebuild -project YYKitDemo.xcodeproj -scheme SwiftWeiboFeed -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/SwiftWeiboFeedReleaseDerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Perform iPhone 11 Release acceptance**

Record OS version, dataset size, cold/warm cache state, average fps, 1% low, hitch ratio, peak/stable memory, and Time Profiler evidence that CoreText layout and image decode are absent from the main thread. Exercise 30 seconds of bidirectional scrolling, image-heavy content, slow/failing network, toolbar interaction, and post-memory-pressure scrolling.

- [ ] **Step 7: Commit**

```bash
git add SwiftWeiboFeed/Performance SwiftWeiboFeed SwiftWeiboFeedTests/PerformanceSmokeTests.swift SwiftWeiboFeedTests/FeedCellSnapshotTests.swift
git commit -m "test: instrument and verify Swift feed performance"
```

---

## Completion Gate

Phase one is complete only when:

- both new targets build independently of YYKit;
- all unit, race, integration, and smoke tests pass;
- 500 mixed items render with exact cached heights;
- rapid reuse produces no stale text, wrong images, blank reused content, or height jumps;
- VoiceOver exposes meaningful profile, body, link/topic/mention, media, and toolbar elements;
- the iPhone 11 Release acceptance record meets or explicitly explains variance from the design targets;
- Instruments confirms that semantic parsing, CoreText layout, bitmap drawing, image downsampling/decoding, JSON decoding, and disk I/O do not run on the main thread.
