# Swift Weibo Feed Cell Visual Parity Design

## Goal

Bring the pure-Swift UIKit feed Cell into visual parity with the original
YYKit Weibo demo while preserving the current CoreText layout, asynchronous
rendering, image-pipeline abstraction, and iOS 16 minimum deployment target.

The first acceptance target is light appearance with the fixed text sizing
used by the original demo. Dark appearance and Dynamic Type are outside this
iteration.

## Reference and Acceptance Baseline

The original implementation is the source of truth:

- `YYKitDemo/WBStatusCell.m`
- `YYKitDemo/WBStatusLayout.m`
- `YYKitDemo/WBStatusHelper.m`
- `YYKitDemo/ResourceWeibo.bundle`
- `YYKitDemo/EmoticonWeibo.bundle`
- the supplied side-by-side screenshot

For the same fixture and container width, the Swift version must match the
original information hierarchy, resource choices, frame relationships,
colors, text transformations, and visible Cell states. The implementation
must not link YYKit or reuse the Objective-C Cell at runtime.

## Chosen Approach

Port the original visual rules into focused Swift components and load the
original bundles through a resource provider. Keep layout as immutable data
produced off the main thread, and keep rendering asynchronous.

Rejected alternatives:

- Linking YYKit and embedding `WBStatusCell` would provide visual reuse but
  would violate the pure-Swift architecture.
- Rebuilding the Cell from ordinary labels, image views, and buttons would be
  faster initially but would weaken the established scrolling-performance
  design and duplicate CoreText behavior.

## Components

### WeiboResourceProvider

`WeiboResourceProvider` is the only component that knows the bundle layout.
It resolves scale-correct `CGImage` values from `ResourceWeibo.bundle` and
emoticon images from `EmoticonWeibo.bundle`.

It provides typed semantic resources rather than accepting arbitrary names:

- repost, comment, unlike, and like toolbar icons;
- verified, grassroots, and membership badges;
- more, location, GIF, and long-image markers;
- deterministic placeholders for unresolved remote images.

Missing optional resources return `nil` and leave layout stable. Required
parity resources are covered by tests so a renamed or unbundled file fails
before runtime.

### Model and Presentation Metadata

The decoded user model retains the fields needed by the original presentation:
verified type, membership rank/type, and related badge state. Presentation
metadata maps model state to nickname color and semantic resource identifiers.

Remote avatars and media remain URL-backed. They are not represented as bundle
resources because the original fixture contains only old remote Sina URLs.

### Rich Text Normalization

Text normalization runs before CoreText layout and produces a display string,
semantic spans, and attachments.

It must:

- replace every mapped Weibo emoticon token with an inline attachment;
- preserve UTF-16/source-to-display range mapping after replacements;
- render mentions, topics, and links with the original accent color;
- transform supported short-link metadata into labels such as “查看图片”
  when the fixture provides the necessary URL/title information;
- compose repost author prefixes in the same order as the original demo;
- preserve hit-testing and accessibility actions after display replacement.

Unknown emoticons and links remain readable text rather than disappearing.

### Layout

The layout engine ports the original Cell geometry instead of approximating it.

Key structural rules:

- the profile header contains the circular avatar, avatar badge, nickname,
  membership badge, timestamp, source, and more icon;
- the body begins at the Cell's left content inset below the profile header,
  not at the nickname's x-coordinate;
- repost content has the original background, padding, author prefix, media,
  and card ordering;
- media uses the original one-image and grid sizing rules;
- toolbar icons and counts are centered as paired groups in three equal
  sections;
- Cell spacing, separators, and bottom margin reproduce the original hierarchy;
- truncation uses the original visible line limit and expansion presentation.

All frames remain pixel-aligned at the current display scale. Layout continues
off the main thread and returns immutable render data.

### Rendering

`FeedContentView` consumes only prepared layout and typed resources.

- text and flat backgrounds continue to render through `AsyncRenderLayer`;
- profile badges are drawn in the profile pass, and toolbar icons are drawn in
  the toolbar pass, using cached `CGImage` values;
- avatar/media layers remain separate so asynchronous image completion does not
  redraw CoreText;
- the avatar layer is circular with the original border, with the verification
  badge layered above it;
- unresolved images show a neutral deterministic placeholder with the final
  geometry, avoiding layout movement when the request finishes.

No file or bundle lookup occurs in the scrolling hot path. Resources are
resolved and cached before drawing.

## Data Flow

1. JSON decoding creates the domain model including presentation-relevant user
   metadata.
2. Rich-text parsing creates normalized display text, actions, and attachments.
3. The layout engine combines domain data, text results, visual metrics, and
   semantic resource identifiers into `FeedItemLayout`.
4. The Cell applies immutable frames immediately.
5. Async render layers draw text, backgrounds, and static icons.
6. The image pipeline independently fills avatar, media, and card image layers.
7. Reuse cancellation prevents stale image or bitmap commits.

## Failure Handling

- A missing required bundle is surfaced by resource-contract tests.
- A missing optional icon omits only that decoration and never changes frames.
- A failed avatar or media request keeps the deterministic placeholder.
- An unknown emoticon remains its original token.
- Invalid short-link metadata keeps the original URL text and action.
- Cancellation continues to prevent stale work from being installed.

## Testing and Verification

### Contract tests

- every required `ResourceWeibo.bundle` semantic resource resolves;
- representative default and additional Weibo emoticons resolve;
- membership and verification metadata selects the expected resource and color.

### Layout tests

At the fixed reference width, assert the structural relationships that caused
the current mismatch:

- body x equals the Cell content inset;
- avatar, nickname, badges, timestamp, and source match reference geometry;
- repost, media, card, toolbar, and Cell separator geometry match reference
  constants;
- toolbar resources map to repost/comment/unlike actions.

### Rich-text tests

- known emoticons become attachments with correct display ranges;
- short-link display replacement preserves action and hit regions;
- repost author composition and truncation match the reference.

### Snapshot tests

Create light-mode, fixed-font-size golden images at 414-point width for:

- plain text;
- mentions/topics/links/emoticons;
- repost;
- one image and nine-image grid;
- card;
- verified/member profile;
- image loading, failure, and placeholder states;
- truncated and expanded text.

Snapshots must include real bundle icons. Golden images are reviewed before
being accepted and are not auto-recorded during normal test runs.

### Build and performance regression

- Xcode 27 beta Debug and Release simulator builds must pass.
- Non-snapshot unit tests touched by this work must pass.
- Existing asynchronous layout/render cancellation tests must remain green.
- Scrolling must not introduce synchronous bundle reads, image decoding, or
  CoreText layout on the main thread.

Stable-Xcode compiler compatibility and image-pipeline cancellation/cache test
failures are separate follow-up scopes unless a change in this iteration causes
a regression.

## Out of Scope

- linking YYKit, YYText, or YYWebImage;
- changing the `ImagePipeline` abstraction;
- repairing obsolete remote Sina URLs beyond deterministic fallback behavior;
- dark-mode visual parity;
- Dynamic Type parity;
- repost/comment business flows and like animation;
- stable-Xcode compiler decomposition work.
