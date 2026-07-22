# Swift UIKit Weibo Feed Architecture Design

Date: 2026-07-22

## 1. Objective

Build the first phase of a Weibo-style timeline in Swift and UIKit while preserving the central performance ideas demonstrated by the YYKit Weibo demo: precomputed layout, asynchronous drawing, lightweight reusable cells, and an independent image pipeline.

The first phase covers the timeline only:

- user profile, time, source, and verification state;
- rich body text with tappable mentions, topics, links, and emoticons;
- single-image and grid media;
- repost content;
- cards and tags;
- repost, comment, and like toolbar;
- basic VoiceOver semantics;
- performance instrumentation.

Compose, comment entry, repost entry, and the emoticon keyboard are outside this phase.

## 2. Constraints and Success Criteria

- Language and UI: Swift with UIKit.
- Minimum deployment target: iOS 16.
- Performance baseline: iPhone 11, 60 Hz display.
- Dependencies: Apple frameworks only in the first implementation.
- Text: CoreText layout and asynchronous bitmap drawing.
- Images: URLSession, URLCache, ImageIO, and an in-memory decoded-bitmap cache.
- The image implementation must sit behind an interface so it can later be replaced without changing Feed UI or layout code.
- Rich text supports tapping and accessibility, but not selection or copying in phase one.
- Performance acceptance uses a Release build, at least 500 mixed feed items, and both cold- and warm-cache scrolling tests.

The engineering target is smooth sustained scrolling close to 60 fps, with no persistent user-visible hitching, incorrect images, content reuse errors, height jumps, or memory growth without a stable ceiling.

## 3. Relationship to the YYKit Demo

This is a modern Swift redesign rather than a file-by-file translation.

| YYKit demo | Swift design |
| --- | --- |
| `WBModel` | `FeedDomain` |
| `WBStatusHelper` | parsing, formatting, and resource services |
| `WBStatusLayout` | `FeedParsing` plus `FeedLayout` |
| `YYTextLayout` | immutable CoreText-backed `TextLayout` |
| `WBStatusCell` / `WBStatusView` | `FeedCell` / `FeedContentView` |
| `YYAsyncLayer` | `AsyncRenderLayer` |
| `YYWebImageManager` | `ImagePipeline` |
| `YYImageCache` / `YYMemoryCache` | layered layout and image caches |
| `WBStatusTimelineViewController` | `FeedViewController` plus `FeedRepository` |
| `YYFPSLabel` | `FeedPerformance` instrumentation |

The design retains three essential YYKit ideas:

1. Complete expensive layout work before cells need it.
2. Draw complex static content away from the main thread.
3. Make cells consume immutable layout results instead of parsing or measuring content.

## 4. System Architecture

The system has seven logical modules. They may initially be folders or Swift packages, but their dependency boundaries are mandatory regardless of physical packaging.

```text
FeedDomain
    -> FeedParsing
    -> FeedLayout
    -> FeedUI

AsyncDisplay -> FeedUI
ImagePipeline -> FeedUI
FeedPerformance observes all stages
```

### 4.1 FeedDomain

Owns Codable and Sendable business types such as `FeedItem`, `User`, `Picture`, `Card`, and `FeedTag`. It also owns stable feed identifiers, content versions, repository state, pagination, de-duplication, and change sets.

It must not depend on UIKit, CoreText, cells, image downloading, or layout geometry.

### 4.2 FeedParsing

Transforms raw body content into semantic spans:

- plain text;
- mention;
- topic;
- link;
- emoticon attachment.

It resolves overlap rules and produces click actions without performing CoreText measurement. This separation prevents regular-expression and business parsing work from leaking into layout or cell code.

### 4.3 FeedLayout

Consumes a feed item, parsed text, and a layout environment. It produces an immutable `FeedItemLayout` containing:

- total cell height;
- every visual frame;
- CoreText line results and line origins;
- interaction regions;
- image target sizes and requests;
- repost, card, tag, and toolbar sub-layouts;
- accessibility geometry.

No cell may synchronously measure text or calculate complex geometry during scrolling.

### 4.4 AsyncDisplay

Provides a business-agnostic asynchronous layer system. It draws immutable layout results into bitmap contexts on a bounded queue, checks cancellation between drawing stages, and commits a `CGImage` to `layer.contents` on the main actor only after identity and generation validation.

### 4.5 ImagePipeline

Provides downloading, request coalescing, caching, target-size downsampling, background decoding, priority, prefetching, and cancellation. Consumers depend on the pipeline protocol, not URLSession or ImageIO directly.

### 4.6 FeedUI

Owns the table view, view controller, prefetch coordinator, lightweight cells, render layers, network image layers, touch routing, and virtual accessibility elements.

It applies prepared results. It does not decode JSON, parse rich text, measure text, calculate cell heights, perform disk I/O, or decode images.

### 4.7 FeedPerformance

Uses metrics and `os_signpost` intervals to measure parsing, layout, drawing, download, decode, cache behavior, cell application, hitches, and memory. It observes behavior without changing business results.

## 5. Data Flow

```text
JSON or API response
    -> FeedDomain decoding
    -> FeedParsing semantic spans
    -> FeedLayout immutable layout
    -> AsyncDisplay static-region bitmaps
    -> ImagePipeline decoded target-size images
    -> FeedUI frame and layer-content submission
```

Paging items are not inserted as real feed cells until their exact layouts are available. If immediate feedback is required, a distinct skeleton cell is used and later replaced; the real feed cell does not begin with an estimated height.

## 6. Threading Model

### 6.1 MainActor

The main actor is limited to:

- table view data-source and lifecycle callbacks;
- cell dequeue and reuse;
- frame assignment;
- `CALayer.contents` submission;
- touch and accessibility handling;
- task initiation and cancellation.

JSON decoding, regular expressions, CoreText layout, bitmap drawing, image decoding, and disk I/O are forbidden on the main actor.

### 6.2 Actors

`FeedRepository` is an actor that protects ordered feed state, item versions, pagination, and change-set production. `ImagePipelineState` is an actor that protects in-flight request coalescing, subscriber counts, and cache metadata.

Actors protect state; they do not execute long CPU-bound work.

### 6.3 Bounded Executors

- `ParsingExecutor`: bounded semantic parsing, initial concurrency 2.
- `LayoutExecutor`: `OperationQueue` for CoreText layout, initial concurrency 2.
- `DisplayExecutor`: asynchronous bitmap drawing, initial concurrency 2.
- Image I/O queue: serialized or narrowly concurrent disk work.
- Image decode queue: bounded ImageIO downsampling and decode, initial concurrency 2.

These initial limits must be tuned using Instruments on the baseline device. The design deliberately avoids unbounded `Task.detached` fan-out.

### 6.4 Priority and Backpressure

Priority order is:

1. visible content missing a required result;
2. content immediately ahead of the scroll direction;
3. table-view prefetch range;
4. distant warming.

Tasks outside the active window are cancelled before execution where possible. When queues exceed configured thresholds, the system stops accepting low-priority pre-render work first, preserves exact layout work, and then narrows image prefetching.

## 7. Identity, Updates, and Consistency

Business and layout identity are separate:

```swift
struct FeedContentIdentity: Hashable, Sendable {
    let itemID: FeedID
    let contentVersion: UInt
}

struct FeedLayoutEnvironment: Hashable, Sendable {
    let containerPixelWidth: Int
    let displayScale: Int
    let contentSizeCategory: String
    let themeVersion: UInt
    let layoutAlgorithmVersion: UInt
}

struct FeedLayoutIdentity: Hashable, Sendable {
    let content: FeedContentIdentity
    let environment: FeedLayoutEnvironment
}
```

Content changes increment `contentVersion`. Width, scale, Dynamic Type, theme, or layout-algorithm changes produce a new layout environment.

Every asynchronous result carries an item identity, region, and cell generation. A result may be committed only if all values still match. Cell reuse increments the generation and cancels local subscriptions.

`FeedRepository` compares old and new data and emits insert, delete, move, full-content change, or toolbar-only change operations. Toolbar-only changes invalidate and redraw only the toolbar. Full content changes invalidate parsing, layout, and affected render results. Environment changes preserve models and parsed semantics but invalidate layout and render results.

Traditional stable-ID table data source updates and `performBatchUpdates` are used initially. A validated mismatch falls back to `reloadData()` in Release and asserts in Debug.

## 8. Cache Strategy

### 8.1 ParsedTextCache

Keyed by item ID, content version, and parser version. It stores compact semantic parsing results and may retain roughly the most recent 1,000 to 2,000 entries subject to measured memory cost.

### 8.2 LayoutCache

Keyed by content identity and every layout-environment property. Width and scale are represented as integer pixels to avoid floating-point key instability.

The cache is cost-based rather than only count-based. On memory pressure it preserves visible layouts and a small surrounding window, then removes distant results.

CoreText objects are isolated inside a narrowly scoped `CoreTextLayoutStorage: @unchecked Sendable`. This exception must not spread into business or UI models.

### 8.3 RenderCache

Whole-cell bitmap caching is not included initially. If profiling proves repeated drawing is material, a short-window region-based render cache may be added for visible items and approximately one to two screens around them.

Static content is separated into header/body, repost, card/tag, and toolbar regions so small changes do not require a full-cell redraw or an excessively tall bitmap.

### 8.4 Image Cache

The initial image cache has:

- an in-memory cache of target-size, already-decoded `CGImage` values;
- URLCache for HTTP response caching.

The image memory key includes URL, target pixel dimensions, content mode, scale, and processor version. Cost is the decoded pixel allocation, approximately `bytesPerRow * height`, not compressed file size.

A custom disk-data cache may be added later behind the same pipeline interface if profiling or offline requirements justify it.

## 9. Cell Rendering Structure

`FeedCell` owns lifecycle, identity, generation, image subscriptions, drawing cancellation, touch routing, and accessibility elements. `FeedContentView` assigns frames from `FeedItemLayout`.

Recommended layer structure:

```text
FeedCell
└── FeedContentView
    ├── backgroundLayer
    ├── headerRenderLayer
    ├── avatarLayer
    ├── bodyRenderLayer
    ├── mediaContainerLayer
    │   └── imageLayer[0...8]
    ├── repostRenderLayer
    ├── repostMediaContainerLayer
    ├── cardRenderLayer
    ├── tagRenderLayer
    ├── toolbarRenderLayer
    └── highlightLayer
```

Static backgrounds, CoreText, icons, and separators are asynchronously drawn in a small number of semantic render regions. Network images remain separate lightweight layers because they arrive independently. Pressed-link highlighting uses a temporary overlay and does not redraw body text.

Cells use explicit frames and do not use Auto Layout for per-item feed geometry.

Interaction regions are produced during layout and map rectangles to `FeedAction` values. Virtual `UIAccessibilityElement` instances expose user, text, topic, link, image, and toolbar semantics even though the visible content is bitmap-based.

## 10. Image Pipeline Contract and Behavior

The UI depends on an abstract pipeline capable of loading, prefetching, and cancelling target-size requests. An implementation may later be replaced by Nuke, a custom codec, or a YYWebImage bridge without changing Feed layout or cells.

Required behavior:

- request key includes URL and target pixel size;
- identical requests share download and decode work;
- cancelling one subscriber does not cancel work still required by another;
- ImageIO downsamples to the display target off the main thread;
- images are fully decoded before main-thread submission;
- EXIF orientation is honored;
- low-priority distant decoding is suspended or cancelled during rapid scrolling;
- assignment validates item ID, image position, cache key, and cell generation.

Image success or failure changes only layer content and never changes feed height.

## 11. Error Handling and Degradation

- Image failures retain a stable placeholder, do not change geometry, and retry only under a bounded visible-content policy.
- Cancellation is not reported as a business failure and does not trigger retries.
- Missing emoticon resources fall back to their original textual token.
- Invalid URLs do not create interaction regions.
- Missing noncritical fields receive safe defaults; a bad item does not discard an entire page.
- Layout validates finite geometry, constrains image aspect ratios, limits extremely long content, and falls back to safe system fonts and plain text.
- Excessively long text is truncated in phase one with a full-text action.
- Memory pressure clears distant render bitmaps first, then decoded images, distant layouts, and distant parsed text, while preserving visible state.
- Resource pressure degrades prefetch distance and pre-rendering before it degrades correctness or visible quality.

## 12. Testing Strategy

### 12.1 Unit Tests

- Domain decoding with complete, partial, unknown, and malformed fields.
- Semantic parsing for mentions, topics, links, emoticons, Unicode, overlap, and invalid syntax.
- Layout invariants: finite geometry, bounds containment, legal non-overlap, matching media counts, valid hit regions, and correct total height.
- Identity and cancellation races, especially an old slow task completing after a reused cell displays a new item.
- Image cache keys, request coalescing, cancellation subscriptions, target-size downsampling, EXIF orientation, error behavior, and memory eviction using a custom URLProtocol.
- Feed change sets, toolbar-only invalidation, environment invalidation, and batch-update consistency.

### 12.2 Snapshot and Integration Tests

Snapshot representative cells including plain text, long text, one/four/nine images, reposts, cards, tags, VIP state, rich semantic text, placeholders, success, and failure.

End-to-end tests exercise at least 500 mixed items through decoding, parsing, layout, drawing, and cell application. They verify refresh, paging, width changes, backgrounding, memory pressure, rapid reuse, no wrong images, and no height jumps.

### 12.3 Initial Performance Budgets

These are starting budgets to be tuned after baseline-device measurement:

| Stage | P95 target |
| --- | ---: |
| semantic parsing | under 1 ms per item |
| ordinary item layout | under 3 ms |
| complex item layout | under 8 ms |
| ordinary text-region drawing | under 5 ms |
| large-image downsampling | under 20 ms off-main |
| main-thread cell apply | under 1 ms |
| cached-image main-thread submission | under 0.5 ms |

### 12.4 Device Acceptance

Use an iPhone 11 Release build with at least 500 mixed items. Test cold and warm cache, rapid downward scrolling, repeated bidirectional scrolling for 30 seconds, image-heavy and long-text regions, slow or failing network responses, toolbar interactions during scrolling, and continued scrolling after memory pressure.

Acceptance expectations:

- average refresh remains close to 60 fps;
- 1% low is approximately 50 fps or better;
- scrolling hitch ratio is approximately 1% or lower;
- no persistent visible hitch sequence;
- the main thread performs no image decode or CoreText layout;
- no wrong image, blank reused content, stale asynchronous overwrite, or row-height jump;
- memory approaches a stable ceiling during repeated scrolling.

Time Profiler, Core Animation, Allocations, Leaks, Network, and Points of Interest are used for release acceptance. Signposts include `feed.parse`, `feed.layout`, `feed.display`, `image.download`, `image.decode`, and `cell.apply`.

## 13. Delivery Sequence

The subsequent implementation plan should preserve this dependency order:

1. Domain types, fixtures, identity, and repository foundations.
2. Semantic parsing and parsing tests.
3. CoreText layout primitives, layout environment, layout cache, and layout tests.
4. Async display engine and race/cancellation tests.
5. Image pipeline, decoded-image cache, and image tests.
6. Lightweight cell and timeline UI integration.
7. Prefetch coordination, backpressure, and partial invalidation.
8. Accessibility and interaction routing.
9. Instrumentation, integration fixtures, snapshots, and device performance tuning.

No implementation phase is considered complete solely because it compiles. Each phase must pass its correctness tests and demonstrate that forbidden work is absent from the main thread.
