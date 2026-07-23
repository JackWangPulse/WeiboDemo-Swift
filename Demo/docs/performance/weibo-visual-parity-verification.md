# Swift Weibo Cell Visual Parity Verification

Date: 2026-07-23

## Environment

- Xcode 27 beta
- Swift 6
- iPhone 17 simulator, iOS 27.0
- Acceptance width: 414 points
- Appearance: light

## Verified behavior

- Original `ResourceWeibo.bundle` toolbar, profile-more, membership, and
  verification images render in the pure-Swift UIKit Cell.
- Avatars are independently bound, circularly clipped, bordered, and protected
  from stale reuse completion by item identity and generation checks.
- `[喵喵]`, base emoticons, and additional JSON emoticon packages render as
  inline CoreText attachments.
- Verified/member names use the original orange color and append the original
  membership image.
- The profile, 12-point body inset, 35-point toolbar, and four-point media-grid
  spacing match the original demo metrics.
- Resource lookup is completed before asynchronous display tasks are submitted.
  CoreText layout, emoticon directory I/O, bitmap rendering, and remote image
  decode remain off the main scrolling path.

## Build evidence

- Debug simulator build: PASS
- Release generic iOS Simulator build: PASS
- Focused resource, layout, and performance suites passed earlier in the
  implementation.
- Xcode 27 beta subsequently stalled while finalizing simulator test logs. The
  app compiled and launched, but the affected result bundles were incomplete;
  this was treated as a toolchain/test-service issue rather than reported as a
  passing test run.

## Visual review

The launched app was inspected from a real simulator screenshot. The first
visible cells show orange member names, membership and avatar verification
badges, inline emoticons, semantic link coloring, original toolbar icons,
repost/card backgrounds, and original spacing.

## Remaining difference

The bundled 2015 fixtures use cleartext HTTP avatar and media URLs. Current iOS
ATS rejects those requests, so remote images remain deterministic placeholders.
Restoring those network images requires either HTTPS URL normalization, explicit
ATS exceptions, or a bundled deterministic fixture image pipeline and is kept
separate from the Cell visual-resource work.
