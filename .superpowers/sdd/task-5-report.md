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

Remaining note:

- The phase-one domain model currently has no timestamp/source fields, so `ProfileLayout.source` uses a deterministic `Weibo` placeholder until the domain DTO is expanded by a later task.
