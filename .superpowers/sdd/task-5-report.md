# Task 5 Report

Status: complete

Commit: `c0f280b` (`feat: compute CoreText feed layouts off main`)

Implemented:

- `FeedLayoutEngine.layout(item:parsedBody:parsedRepost:environment:) async throws -> FeedItemLayout`
- Bounded `OperationQueue` with `maxConcurrentOperationCount = 2`
- Off-main CoreText line construction with explicit 20-point line metrics
- Deterministic body, repost, media, card/tag spacing, avatar, and toolbar geometry
- Semantic attributed spans and interaction rects for mentions, topics, URLs, expand, repost, comment, and like
- One-up, four-up, and nine-up media grids
- Six-line truncation with a visible `… More` token and `.expand(itemID)` interaction
- Cancellation checks before queuing work, before expensive stages, throughout typesetting, and before returning
- Geometry validation covering frames, interaction rects, and CoreText origins

Tests:

- Focused `FeedLayoutEngineTests`: passed on iPhone 17 Pro simulator
- Full `SwiftWeiboFeed` scheme: passed on iPhone 17 Pro simulator
- Full run command exited 0; only existing linker deployment-version warnings were emitted (test target deployment 16.0 versus Xcode 27 XCTest built for 17.0)
- `git diff --check`: clean before commit

TDD evidence:

- RED: new engine tests initially failed to compile because `FeedLayoutEngine` did not exist.
- GREEN: focused suite passed after implementation and Swift 6-safe test fixture adjustments.
- REFACTOR/verification: truncation was tightened to append a CoreText token, then the complete scheme passed.

Concerns:

- The approved `FeedItemLayout` interface has no distinct public card/tag/profile frame fields, so phase-one card and tag presence are represented deterministically in vertical allocation, while the avatar is exposed through `avatarFrame`.
- Xcode produced an incomplete `.xcresult` metadata bundle despite a successful exit, so the exact aggregate test count could not be extracted; both focused and full test commands returned exit code 0.

## Architecture Review Fixes

Status: complete

Implemented:

- Replaced the hard-coded content version with a required caller-provided `FeedContentIdentity` and preserved it in `FeedLayoutIdentity`.
- Expanded `FeedItemLayout` with complete profile, card, tag, and repost-card layouts, including text storage, geometry, interactions, and accessibility labels.
- Added a tag action and generated user, card URL, tag, and toolbar interaction regions entirely in the layout layer.
- Replaced the self-capturing `BlockOperation` continuation path with a cancellation token and lock-protected single-resume completion box. A queued cancellation now resumes immediately even when both execution slots remain blocked.
- Calculated the actual visible UTF-16 boundary of the truncated final line after reserving the CoreText token width; invisible semantic spans are clipped and the expand hit rect matches the visible token.
- Strengthened tests for caller identity propagation, repeatability, bounded queued cancellation, complex Unicode truncation, hidden-link clipping, complete profile/card/tag/repost-card containment, interactions, and finite geometry.

Verification:

- Generic simulator build: passed.
- Focused `FeedLayoutEngineTests`: passed on the booted iPhone 17 Pro simulator (exit 0).
- Full `SwiftWeiboFeed` scheme tests: passed on the same simulator (exit 0).
- `git diff --check`: passed.

The earlier profile metadata limitation was resolved by the final review cycle below.

## Final Review Fix Cycle

Status: complete

Commit: pending at time of report update

Implemented:

- Added tolerant optional `createdAt` and normalized HTML `source` decoding to `FeedItem`; added tolerant verification flag/type/reason decoding to `FeedUser`, with bundled-fixture, valid-metadata, and malformed-metadata coverage.
- Replaced the fabricated profile source with optional time/source layouts, optional verification geometry, and a complete profile accessibility label. Missing metadata now remains absent.
- Kept one optional `TagLayout` from `tags.first`, with an implementation comment and test documenting intentional parity with the original YYKit Weibo demo.
- Rebuilt the truncated sixth line from an explicit attributed visible prefix plus `… More`; semantic ranges are clipped to that prefix and the expand rectangle starts at the measured prefix width. Added forced-newline, partial-URL, and complex-Unicode cases.
- Made single-line CoreText layouts width-aware, including zero/narrow-width handling, and verified long Unicode profile/card/tag lines never exceed declared bounds.
- Added observed concurrency (`<= 2`), all-frame repeatability, exact grid rows/columns/non-overlap, owner width/height containment, and line/origin-count checks.

Exact verification evidence:

- Focused `FeedModelsTests` + `FeedLayoutEngineTests` on iPhone 17 Pro simulator: `xcodebuild` exit 0.
- Full `SwiftWeiboFeed` scheme on iPhone 17 Pro simulator after final accessibility changes: `xcodebuild` exit 0.
- `git diff --check`: clean.

Concerns: none known within Task 5 scope.

## Final CoreText Index-Base Fix

Status: complete

- Added an explicit CoreText index base for each line. Normal typesetter lines retain absolute source indices; the rebuilt sixth line translates absolute semantic intersections into its local substring index space before asking CoreText for offsets.
- Strengthened the forced-newline partial-URL test to assert the first visible URL glyph begins exactly at the sixth-line origin and its final hit rect ends before the measured expand token.
- Extended source normalization to decode common named HTML entities and decimal/hex numeric entities after removing markup.

Verification:

- Focused `FeedModelsTests` + `FeedLayoutEngineTests`: exit 0 on iPhone 17 Pro simulator.
- Full `SwiftWeiboFeed` scheme: exit 0 on iPhone 17 Pro simulator.
- `git diff --check`: clean.
