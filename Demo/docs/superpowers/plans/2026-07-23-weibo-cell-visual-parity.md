# Weibo Cell Visual Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pure-Swift UIKit feed Cell match the original YYKit Weibo demo in light mode at fixed text sizing, using the original resources without linking YYKit.

**Architecture:** Add a typed, cached resource provider and explicit Weibo visual metrics, enrich decoded presentation metadata, then port the original rich-text, layout, and rendering rules into the existing immutable-layout/asynchronous-rendering pipeline. Remote avatar and media loading remains behind `ImagePipeline`; local icons and badges are resolved once and drawn without bundle I/O in the scrolling path.

**Tech Stack:** Swift 6, UIKit, CoreText, CoreGraphics, ImageIO, XCTest, Xcode 27 beta, iOS 16+

## Global Constraints

- Keep the app target pure Swift; do not link YYKit, YYText, or YYWebImage.
- Keep iOS 16.0 as the minimum deployment target.
- Preserve off-main CoreText layout, asynchronous bitmap rendering, cancellation, Cell reuse, and the `ImagePipeline` abstraction.
- The acceptance configuration is light appearance, fixed original-demo font sizes, and 414-point Cell width.
- Treat `WBStatusCell.m`, `WBStatusLayout.m`, `WBStatusHelper.m`, `ResourceWeibo.bundle`, `EmoticonWeibo.bundle`, and the supplied comparison screenshot as the reference.
- Do not include stable-Xcode compiler work, image-pipeline race fixes, dark mode, Dynamic Type, or like animation in this plan.

---

### Task 1: Typed Weibo Resource Contract

**Files:**
- Create: `Demo/SwiftWeiboFeed/Resources/WeiboResourceProvider.swift`
- Create: `Demo/SwiftWeiboFeedTests/WeiboResourceProviderTests.swift`
- Modify: `Demo/YYKitDemo.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `WeiboResource`, `WeiboResourceProviding`, and `WeiboResourceProvider.shared`.
- `func image(_ resource: WeiboResource) -> CGImage?`
- `func membershipImage(rank: Int) -> CGImage?`
- Later rendering and presentation tasks consume these typed lookups.

- [ ] **Step 1: Write the failing resource-contract tests**

```swift
import XCTest
@testable import SwiftWeiboFeed

final class WeiboResourceProviderTests: XCTestCase {
    func testRequiredTimelineResourcesResolveFromBundledDemoAssets() {
        let provider = WeiboResourceProvider(bundle: .main)
        let required: [WeiboResource] = [
            .toolbarRepost, .toolbarComment, .toolbarUnlike, .toolbarLike,
            .avatarVIP, .avatarEnterpriseVIP, .avatarGrassroot,
            .timelineMore, .timelineGIF, .timelineLongImage
        ]
        for resource in required {
            XCTAssertNotNil(provider.image(resource), "\(resource) must resolve")
        }
    }

    func testMembershipRankUsesSpecificImageThenGenericFallback() {
        let provider = WeiboResourceProvider(bundle: .main)
        XCTAssertNotNil(provider.membershipImage(rank: 1))
        XCTAssertNotNil(provider.membershipImage(rank: 99))
    }
}
```

Add the test and future source file references to the Swift app/test target source phases before running.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
/Applications/Xcode-27-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project Demo/YYKitDemo.xcodeproj \
  -scheme SwiftWeiboFeed \
  -destination 'platform=iOS Simulator,id=D806A752-A2EC-4DE6-80ED-603E506F070E' \
  -derivedDataPath /tmp/SwiftWeiboFeedVisualParityRed1 \
  -only-testing:SwiftWeiboFeedTests/WeiboResourceProviderTests \
  CODE_SIGNING_ALLOWED=NO test
```

Expected: FAIL because `WeiboResourceProvider` and `WeiboResource` do not exist.

- [ ] **Step 3: Implement typed, eagerly cached resource loading**

Create the semantic mapping:

```swift
import CoreGraphics
import ImageIO
import UIKit

enum WeiboResource: Hashable, Sendable {
    case toolbarRepost, toolbarComment, toolbarUnlike, toolbarLike
    case avatarVIP, avatarEnterpriseVIP, avatarGrassroot
    case timelineMore, timelineGIF, timelineLongImage

    var baseName: String {
        switch self {
        case .toolbarRepost: "timeline_icon_retweet"
        case .toolbarComment: "timeline_icon_comment"
        case .toolbarUnlike: "timeline_icon_unlike"
        case .toolbarLike: "timeline_icon_like"
        case .avatarVIP: "avatar_vip"
        case .avatarEnterpriseVIP: "avatar_enterprise_vip"
        case .avatarGrassroot: "avatar_grassroot"
        case .timelineMore: "timeline_icon_more"
        case .timelineGIF: "timeline_image_gif"
        case .timelineLongImage: "timeline_image_longimage"
        }
    }
}

protocol WeiboResourceProviding: Sendable {
    func image(_ resource: WeiboResource) -> CGImage?
    func membershipImage(rank: Int) -> CGImage?
}
```

Implement `WeiboResourceProvider` with a lock-protected `[String: CGImage]`
cache. Resolve `ResourceWeibo.bundle` once in `init`, select `@3x`, `@2x`, then
unscaled PNG according to `UIScreen.main.scale`, and decode via
`CGImageSourceCreateImageAtIndex`. `membershipImage(rank:)` first requests
`common_icon_membership_level\(rank)` and then
`common_icon_membership`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command again.

Expected: `WeiboResourceProviderTests` PASS with no missing required resource.

- [ ] **Step 5: Commit Task 1**

```bash
git add Demo/SwiftWeiboFeed/Resources/WeiboResourceProvider.swift \
  Demo/SwiftWeiboFeedTests/WeiboResourceProviderTests.swift \
  Demo/YYKitDemo.xcodeproj/project.pbxproj
git commit -m "feat: add typed Weibo resource provider"
```

---

### Task 2: Original-Demo User Presentation Metadata

**Files:**
- Create: `Demo/SwiftWeiboFeed/Domain/WeiboUserPresentation.swift`
- Create: `Demo/SwiftWeiboFeedTests/WeiboUserPresentationTests.swift`
- Modify: `Demo/SwiftWeiboFeed/Domain/FeedModels.swift`
- Modify: `Demo/YYKitDemo.xcodeproj/project.pbxproj`

**Interfaces:**
- Extends `FeedUser` with decoded `membershipRank: Int`.
- Produces `WeiboUserPresentation` with `nameColor`, `nameBadge`, and `avatarBadge`.
- Consumes `FeedUser.verifiedType`, `FeedUser.isVerified`, and membership rank.

- [ ] **Step 1: Write failing decoding and mapping tests**

```swift
func testMemberUserSelectsOrangeNameMembershipAndVIPAvatarBadges() throws {
    let data = Data(#"""
    {"id":"u","name":"Member","verified":true,"verified_type":0,"mbrank":3}
    """#.utf8)
    let user = try JSONDecoder.weibo.decode(FeedUser.self, from: data)
    let presentation = WeiboUserPresentation(user: user)

    XCTAssertEqual(user.membershipRank, 3)
    XCTAssertEqual(presentation.nameColor, WeiboVisualMetrics.nameOrange)
    XCTAssertEqual(presentation.nameBadge, .membership(rank: 3))
    XCTAssertEqual(presentation.avatarBadge, .avatarVIP)
}

func testOrganizationUsesEnterpriseBadgeAndNormalNameWithoutMembership() throws {
    let data = Data(#"""
    {"id":"u","name":"Org","verified":true,"verified_type":2}
    """#.utf8)
    let user = try JSONDecoder.weibo.decode(FeedUser.self, from: data)
    let presentation = WeiboUserPresentation(user: user)

    XCTAssertEqual(presentation.nameColor, WeiboVisualMetrics.nameNormal)
    XCTAssertEqual(presentation.nameBadge, .avatarEnterpriseVIP)
    XCTAssertEqual(presentation.avatarBadge, .avatarEnterpriseVIP)
}
```

- [ ] **Step 2: Run tests and verify RED**

Use the Task 1 Xcode command with:

```text
-only-testing:SwiftWeiboFeedTests/WeiboUserPresentationTests
```

Expected: FAIL because membership and presentation mapping are absent.

- [ ] **Step 3: Implement exact presentation mapping and colors**

Add `mbrank` to `FeedUser.CodingKeys`, decode missing values as zero, and create:

```swift
enum WeiboNameBadge: Equatable, Sendable {
    case avatarEnterpriseVIP
    case membership(rank: Int)
}

struct WeiboUserPresentation: Equatable, Sendable {
    let nameColor: FeedRGBA
    let nameBadge: WeiboNameBadge?
    let avatarBadge: WeiboResource?
}
```

Use the original colors: normal `#333333`, member orange `#F26220`.
Organization verification maps to enterprise VIP; verified personal users map
to avatar VIP; grassroots verification maps to avatar grassroot when the
fixture's verified type matches the original enum. A positive membership rank
adds a membership badge after the name and makes the name orange.

- [ ] **Step 4: Verify focused and model tests**

Run:

```text
-only-testing:SwiftWeiboFeedTests/WeiboUserPresentationTests
-only-testing:SwiftWeiboFeedTests/FeedModelsTests
```

Expected: both suites PASS.

- [ ] **Step 5: Commit Task 2**

```bash
git add Demo/SwiftWeiboFeed/Domain/FeedModels.swift \
  Demo/SwiftWeiboFeed/Domain/WeiboUserPresentation.swift \
  Demo/SwiftWeiboFeedTests/WeiboUserPresentationTests.swift \
  Demo/YYKitDemo.xcodeproj/project.pbxproj
git commit -m "feat: map Weibo user visual metadata"
```

---

### Task 3: Complete Weibo Emoticon and Display-Text Normalization

**Files:**
- Modify: `Demo/SwiftWeiboFeed/Parsing/FeedEmoticonResolver.swift`
- Modify: `Demo/SwiftWeiboFeed/Parsing/FeedTextParser.swift`
- Modify: `Demo/SwiftWeiboFeed/Parsing/ParsedFeedText.swift`
- Modify: `Demo/SwiftWeiboFeedTests/FeedTextParserTests.swift`
- Modify: `Demo/SwiftWeiboFeedTests/FeedLayoutEngineTests.swift`

**Interfaces:**
- `FeedEmoticonResolver.image(named:)` recursively indexes every plist/JSON
  package under `EmoticonWeibo.bundle`.
- `ParsedFeedText` continues to expose source/display ranges and actions, with
  replacement metadata sufficient for CoreText attachment placement.

- [ ] **Step 1: Add failing representative parity tests**

Add tests that parse the screenshot's representative content:

```swift
func testAdditionalPackageEmoticonResolves() {
    XCTAssertNotNil(FeedEmoticonResolver.image(named: "喵喵"))
}

func testKnownEmoticonBecomesSingleDisplayAttachmentWithoutBreakingMentions() async throws {
    let parsed = FeedTextParser().parse("我家狗～[喵喵] //@用户:正文")
    let emoticon = try XCTUnwrap(parsed.spans.first { $0.kind == .emoticon })
    XCTAssertEqual(String(parsed.source[emoticon.range]), "[喵喵]")

    let layout = try await makeLayout(parsed: parsed)
    XCTAssertEqual(layout.body.attachments.count, 1)
    XCTAssertTrue(layout.body.regions.contains { $0.action == .user("用户") })
}
```

For URL replacement, first add a fixture-backed assertion only where the JSON
contains the original URL metadata/title; do not infer “查看图片” from arbitrary
`t.cn` URLs.

- [ ] **Step 2: Run parser/layout tests and verify RED**

Run only `FeedTextParserTests` and `FeedLayoutEngineTests`.

Expected: the additional-package emoticon test FAILS, proving the current
resolver does not fully index the nested bundle.

- [ ] **Step 3: Port recursive emoticon indexing**

Replace the partial package lookup with a one-time recursive index matching
`WBStatusHelper._emoticonDicFromPath`: read `info.plist` and `info.json`,
collect both simplified and traditional names, recurse into child directories,
and store paths rather than decoded images. Decode and cache a `CGImage` only
when a named emoticon is requested.

Preserve the existing source-to-display mapping. Add explicit display-label
metadata to parsed URL spans only when supplied by decoded fixture metadata.

- [ ] **Step 4: Verify parser, layout, and accessibility suites**

Run:

```text
-only-testing:SwiftWeiboFeedTests/FeedTextParserTests
-only-testing:SwiftWeiboFeedTests/FeedLayoutEngineTests
-only-testing:SwiftWeiboFeedTests/FeedAccessibilityTests
```

Expected: all selected suites PASS; `[喵喵]` produces one attachment.

- [ ] **Step 5: Commit Task 3**

```bash
git add Demo/SwiftWeiboFeed/Parsing \
  Demo/SwiftWeiboFeedTests/FeedTextParserTests.swift \
  Demo/SwiftWeiboFeedTests/FeedLayoutEngineTests.swift
git commit -m "fix: complete Weibo rich text normalization"
```

---

### Task 4: Port Original Cell Metrics and Geometry

**Files:**
- Create: `Demo/SwiftWeiboFeed/Layout/WeiboVisualMetrics.swift`
- Modify: `Demo/SwiftWeiboFeed/Layout/FeedItemLayout.swift`
- Modify: `Demo/SwiftWeiboFeed/Layout/FeedLayoutEnvironment.swift`
- Modify: `Demo/SwiftWeiboFeed/Layout/FeedLayoutEngine.swift`
- Modify: `Demo/SwiftWeiboFeedTests/FeedLayoutEngineTests.swift`
- Modify: `Demo/YYKitDemo.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces `WeiboVisualMetrics` constants copied from `WBStatusLayout.h`.
- Extends profile/toolbar/media layout values with badge and icon resource
  identities but not decoded images.
- Rendering consumes the resulting immutable frames and resource identities.

- [ ] **Step 1: Write failing structural geometry tests at 414 points**

```swift
func testBodyStartsAtCellContentInsetBelowProfile() async throws {
    let layout = try await layoutFixture(width: 414)
    XCTAssertEqual(layout.profile.avatarFrame, CGRect(x: 12, y: 20, width: 40, height: 40))
    XCTAssertEqual(layout.body.bounds.minX, 12)
    XCTAssertEqual(layout.body.bounds.minY, 8 + 56)
}

func testToolbarMatchesOriginalHeightAndSemanticIcons() async throws {
    let layout = try await layoutFixture(width: 414)
    XCTAssertEqual(layout.toolbar.frame.height, 35)
    XCTAssertEqual(layout.toolbar.items.map(\.resource),
                   [.toolbarRepost, .toolbarComment, .toolbarUnlike])
}

func testNineImageGridUsesThreeColumnsAndFourPointSpacing() async throws {
    let layout = try await layoutFixture(pictureCount: 9, width: 414)
    XCTAssertEqual(layout.mediaFrames.count, 9)
    XCTAssertEqual(layout.mediaFrames[1].minX - layout.mediaFrames[0].maxX, 4)
    XCTAssertEqual(layout.mediaFrames[3].minY - layout.mediaFrames[0].maxY, 4)
}
```

- [ ] **Step 2: Run layout tests and verify RED**

Expected failures: body x is currently 64, toolbar height is currently at least
44, and icon resources are absent.

- [ ] **Step 3: Add original visual metrics**

Define fixed values from `WBStatusLayout.h`:

```swift
enum WeiboVisualMetrics {
    static let topMargin: CGFloat = 8
    static let contentInset: CGFloat = 12
    static let textPadding: CGFloat = 10
    static let pictureSpacing: CGFloat = 4
    static let profileHeight: CGFloat = 56
    static let nameAvatarSpacing: CGFloat = 14
    static let toolbarHeight: CGFloat = 35
    static let toolbarBottomMargin: CGFloat = 2
    static let nameFontSize: CGFloat = 16
    static let sourceFontSize: CGFloat = 12
    static let bodyFontSize: CGFloat = 17
    static let repostFontSize: CGFloat = 16
    static let link = FeedRGBA(hex: 0x527EAD)
    static let innerBackground = FeedRGBA(hex: 0xF7F7F7)
}
```

If `FeedRGBA(hex:)` is not present, add an internal initializer whose unit test
asserts exact normalized channels.

- [ ] **Step 4: Port layout ordering and geometry**

Refactor `FeedLayoutEngine.compute` to follow the original order:

```text
top margin → optional title → 56pt profile → body → repost OR media OR card
→ tag/padding → 35pt toolbar → 2pt bottom margin
```

Make the body width `containerWidth - 24` at x `12`. Use 17pt body and 16pt
repost text with the original `1.34` baseline multiple and 10pt top/bottom text
padding. Port one-image aspect sizing and 3-column media sizing. Keep every
calculation pixel rounded for `environment.displayScale`.

Extract text-layout helpers from `FeedLayoutEngine.swift` into
`WeiboTextLayoutBuilder.swift` if the stable compiler or file size regresses;
add the new file to the app target in the same change.

- [ ] **Step 5: Verify layout and performance invariants**

Run:

```text
-only-testing:SwiftWeiboFeedTests/FeedLayoutEngineTests
-only-testing:SwiftWeiboFeedTests/PerformanceSmokeTests/testRepresentativeParserAndLayoutBenchmarks
-only-testing:SwiftWeiboFeedTests/PerformanceSmokeTests/testLayoutRunsOffMainThread
```

Expected: geometry assertions PASS and layout remains off-main.

- [ ] **Step 6: Commit Task 4**

```bash
git add Demo/SwiftWeiboFeed/Layout \
  Demo/SwiftWeiboFeedTests/FeedLayoutEngineTests.swift \
  Demo/YYKitDemo.xcodeproj/project.pbxproj
git commit -m "feat: port original Weibo cell geometry"
```

---

### Task 5: Render Original Profile, Toolbar, and Media Decorations

**Files:**
- Modify: `Demo/SwiftWeiboFeed/UI/FeedContentView.swift`
- Modify: `Demo/SwiftWeiboFeed/UI/FeedCell.swift`
- Modify: `Demo/SwiftWeiboFeed/Layout/FeedItemLayout.swift`
- Create: `Demo/SwiftWeiboFeedTests/WeiboRenderingTests.swift`
- Modify: `Demo/YYKitDemo.xcodeproj/project.pbxproj`

**Interfaces:**
- `FeedContentView` receives a `WeiboResourceProviding` dependency, defaulting
  to `WeiboResourceProvider.shared`.
- Profile and toolbar render passes draw cached `CGImage` resources.
- Image-binding layers retain independent avatar/media updates.

- [ ] **Step 1: Write failing rendering tests with a recording provider**

```swift
@MainActor
func testApplyMakesAvatarCircularAndRequestsProfileBadges() async throws {
    let resources = RecordingWeiboResources()
    let view = FeedContentView(resourceProvider: resources,
                               layerFactory: { ImmediateRenderLayer() })
    let entry = try await memberFixture()
    view.apply(entry)
    view.display(entry: entry, generation: 1, scale: 3)

    XCTAssertEqual(view.avatarLayer.cornerRadius,
                   entry.layout.profile.avatarFrame.width / 2)
    XCTAssertTrue(resources.requested.contains(.avatarVIP))
}

@MainActor
func testToolbarRequestsOriginalSemanticResources() async throws {
    let resources = RecordingWeiboResources()
    let view = makeView(resources)
    let entry = try await fixture()
    view.apply(entry)
    view.display(entry: entry, generation: 1, scale: 3)
    XCTAssertEqual(resources.requested.filter(\.isToolbar),
                   [.toolbarRepost, .toolbarComment, .toolbarUnlike])
}
```

- [ ] **Step 2: Run rendering tests and verify RED**

Expected: FAIL because the Cell has no typed resource dependency, no avatar
layer accessor, and toolbar icons are still drawn as placeholder circles.

- [ ] **Step 3: Implement profile and toolbar rendering**

Replace `drawToolbarIcon` with cached image drawing. Draw nickname using the
presentation color and append the membership/organization badge at the
precomputed frame. Add the profile more icon. Configure the first image layer
as the avatar:

```swift
avatarLayer.cornerRadius = profile.avatarFrame.width / 2
avatarLayer.borderWidth = 1 / scale
avatarLayer.borderColor = UIColor(white: 0, alpha: 0.09).cgColor
```

Add a separate badge layer above the avatar so avatar completion cannot cover
it. Draw GIF/long-image badges above media where model metadata supports them.
Use `#F2F2F2` outer spacing, white Cell content, `#F7F7F7` repost/card
background, and the original 9%-black separators.

- [ ] **Step 4: Verify rendering, reuse, and cancellation**

Run:

```text
-only-testing:SwiftWeiboFeedTests/WeiboRenderingTests
-only-testing:SwiftWeiboFeedTests/FeedCellTests
-only-testing:SwiftWeiboFeedTests/AsyncRenderLayerTests
```

Expected: selected suites PASS; reuse tests prove badge/icon layers are cleared
or replaced and stale image completion cannot overwrite the represented item.

- [ ] **Step 5: Commit Task 5**

```bash
git add Demo/SwiftWeiboFeed/UI \
  Demo/SwiftWeiboFeed/Layout/FeedItemLayout.swift \
  Demo/SwiftWeiboFeedTests/WeiboRenderingTests.swift \
  Demo/YYKitDemo.xcodeproj/project.pbxproj
git commit -m "feat: render original Weibo cell resources"
```

---

### Task 6: Establish Reviewed Visual Baselines and Final Verification

**Files:**
- Modify: `Demo/SwiftWeiboFeedTests/FeedCellSnapshotTests.swift`
- Add: `Demo/SwiftWeiboFeedTests/ReferenceImages/*.png`
- Add: `Demo/docs/performance/weibo-visual-parity-verification.md`

**Interfaces:**
- Snapshot test names are stable and correspond to reference states.
- Normal test execution compares but never records baselines.

- [ ] **Step 1: Add deterministic parity snapshot cases**

Ensure the snapshot suite covers:

```swift
enum FeedSnapshotCase: String, CaseIterable {
    case plainText
    case richTextEmoticons
    case verifiedMember
    case repost
    case oneImage
    case nineImages
    case card
    case imagePlaceholder
    case imageFailure
    case truncated
    case expanded
}
```

Use a deterministic local image pipeline and the real bundle resource provider.
Force light appearance, 414-point width, 3x scale, and fixed visual metrics.

- [ ] **Step 2: Run snapshots and verify RED for absent/new references**

Run:

```text
-only-testing:SwiftWeiboFeedTests/FeedCellSnapshotTests
```

Expected: FAIL with an explicit missing-reference message for each new case.

- [ ] **Step 3: Record candidate images in an explicit one-time mode**

Run with `RECORD_SNAPSHOTS=1` only for this step. Copy candidate PNGs into
`Demo/SwiftWeiboFeedTests/ReferenceImages`. Inspect each image against the
supplied screenshot and original demo source before accepting it. Do not
weaken the comparator tolerance to make a mismatch pass.

- [ ] **Step 4: Run snapshots normally and verify GREEN**

Run Step 2 without `RECORD_SNAPSHOTS`.

Expected: all snapshot cases PASS using checked-in references.

- [ ] **Step 5: Run Debug, Release, and scoped unit verification**

Debug build:

```bash
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
/Applications/Xcode-27-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project Demo/YYKitDemo.xcodeproj -scheme SwiftWeiboFeed \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/SwiftWeiboFeedVisualParityDebug \
  CODE_SIGNING_ALLOWED=NO build
```

Release build: repeat with `-configuration Release` and a new derived-data
path.

Run all tests except the already-separated image-pipeline race suite:

```text
xcodebuild ... test -skip-testing:SwiftWeiboFeedTests/SystemImagePipelineTests
```

Expected: both builds PASS; the scoped test suite PASS. Record any pre-existing
unrelated failures rather than changing their assertions in this branch.

- [ ] **Step 6: Document visual and performance verification**

In `weibo-visual-parity-verification.md`, record:

- Xcode/Swift version and simulator;
- build commands and results;
- snapshot cases reviewed;
- confirmation that resource lookup, CoreText layout, and image decode do not
  run synchronously in `cellForRowAt`;
- remaining out-of-scope differences.

- [ ] **Step 7: Commit Task 6**

```bash
git add Demo/SwiftWeiboFeedTests/FeedCellSnapshotTests.swift \
  Demo/SwiftWeiboFeedTests/ReferenceImages \
  Demo/docs/performance/weibo-visual-parity-verification.md
git commit -m "test: establish Weibo visual parity baselines"
```

---

## Final Review Gate

Before calling the iteration complete:

- compare the first two visible fixture Cells against the supplied screenshot;
- verify the body begins at the original left inset;
- verify real avatar/member/toolbar resources are visible;
- verify `[喵喵]` and representative bundle emoticons render inline;
- verify reuse while rapidly scrolling does not show stale avatars or badges;
- run `git diff --check`;
- run the verification-before-completion skill and report exact build/test
  evidence, including any intentionally excluded pre-existing failures.
