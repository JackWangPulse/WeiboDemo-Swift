# SwiftWeiboFeed iPhone 11 Release Acceptance

This record is intentionally unfilled until it is run on a physical iPhone 11. Simulator results are correctness evidence only and must not be copied into the device fields below.

## Build and environment

- Commit:
- Date/time and tester:
- Device: iPhone 11
- iOS version:
- Configuration: Release, installed without debugger
- Dataset: 500 mixed bundled feed items
- Cache state: cold / warm (run and record both)
- Network profile: normal / slow / failure

## Procedure

1. Launch after terminating the app and clearing its URL/decoded caches for the cold run.
2. Scroll continuously in both directions for 30 seconds, including image-heavy, repost, card, and semantic-text rows.
3. Repeat warm, then repeat under a slow network and injected HTTP failures.
4. Activate profile, topic/link/mention, expand, media, and all toolbar actions while scrolling.
5. Issue a memory warning from Xcode, verify visible content remains, and repeat the 30-second scroll.
6. Record an Instruments Core Animation, Allocations, and Time Profiler trace. Preserve the `.trace` path with this record.

## Results

| Run | Average FPS | 1% low | Hitch ratio | Peak memory | Stable memory | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Cold | TBD | TBD | TBD | TBD | TBD | Not run |
| Warm | TBD | TBD | TBD | TBD | TBD | Not run |
| Slow/failing network | TBD | TBD | TBD | TBD | TBD | Not run |
| After memory pressure | TBD | TBD | TBD | TBD | TBD | Not run |

## Main-thread audit

- Semantic parsing absent from main thread: TBD
- CoreText layout absent from main thread: TBD
- Bitmap drawing absent from main thread: TBD
- Image downsampling/decode absent from main thread: TBD
- JSON decoding, disk I/O absent from main thread: TBD
- Time Profiler trace path: TBD
- Variance from 60 fps / memory targets and explanation: TBD

