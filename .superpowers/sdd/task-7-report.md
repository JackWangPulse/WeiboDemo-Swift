# Task 7 Report: Replaceable System Image Pipeline

## Implemented

- Added the exact `PixelSize`, `ImageContentMode`, `ImageRequest`, `ImageResponse`, and `ImagePipeline` API.
- Added an actor-backed `SystemImagePipeline` with request-key coalescing and per-subscriber cancellation state.
- Added `URLSession` configured for `URLCache`, decoded `CGImage` memory caching through `NSCache`, and byte-cost overflow guards.
- Added an ImageIO thumbnail decoder on an `OperationQueue` capped at two concurrent operations.
- Added target-size validation, source pixel/decompressed-size bounds, EXIF transform, and immediate thumbnail caching.
- Added prefetch and prefetch cancellation without coupling one subscriber's cancellation to other subscribers.
- Kept non-Sendable `CGImage` crossing concurrency boundaries limited to a narrow `@unchecked Sendable` wrapper and the required `ImageResponse` API.

## Tests

`SystemImagePipelineTests` uses a deterministic custom `URLProtocol` and generated fixtures to cover:

- identical concurrent request coalescing;
- distinct decoded keys for distinct target sizes while encoded bytes use `URLCache`;
- cancellation of one waiter while another survives;
- 4000-pixel fixture downsampling to a 300-pixel envelope;
- decode hook verification that ImageIO work is off the main thread;
- orientation transform during thumbnail decode.

Verification evidence:

- Generic iOS Simulator production build: `** BUILD SUCCEEDED **`.
- Arm64 iOS Simulator test build: `** TEST BUILD SUCCEEDED **`.
- Runtime test attempts against simulator IDs `7B094ABA-6597-4156-96CA-BE32B7C147E3` and `539405CE-DFD0-4808-B0EF-AF5028F643D7` could not start because Xcode reported both destinations unavailable and listed only the generic simulator placeholder.
- Designed-for-iPad/iPhone Mac fallback reached signing and was rejected because the project has no development team; no signing settings were changed.

## Review Notes

- In-flight worker tasks capture only immutable dependencies, not the pipeline actor, avoiding an actor/task retain cycle.
- Checked continuations are resumed on every decoder operation path.
- Cache costs and source pixel multiplication are guarded before arithmetic.
- Encoded payloads, target dimensions, and source pixel counts are bounded to limit decompression-bomb exposure.
