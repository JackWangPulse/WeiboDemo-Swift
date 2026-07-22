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

## Review Follow-up

- Orientation-aware sizing now reads EXIF orientation before scale calculation and swaps the display axes for orientations 5 through 8. Non-square orientation-6 aspect-fit and aspect-fill regressions were added.
- Decode operations now have locked, single-resume cancellation state. Queued operations are canceled before execution; running operations check cancellation before metadata, thumbnail creation, caching, and return.
- Cancellation tests cover a third decode queued behind two controlled blockers and cancellation during controlled decode, including specific `CancellationError` assertions and proof that canceled output is not decoded-cache resident.
- Prefetch entries now use ownership tokens and install a placeholder before starting their task. Completion removes an entry only when its token still owns that request, preventing stale completion and immediate-completion races.
- The custom URL protocol now records `stopLoading` and suppresses every subsequent callback after cancellation.
- Fresh verification after these fixes: `xcodebuild ... -sdk iphonesimulator -arch arm64 ... build-for-testing` completed with `** TEST BUILD SUCCEEDED **`. Runtime simulator execution was intentionally left to the parent because no concrete simulator destinations are visible in this environment.

## Second Review Follow-up

- Each in-flight request now owns a lock-backed subscriber set. Cancellation consumes its subscriber token synchronously before actor cleanup, preventing double-decrement and closing the last-subscriber actor-hop race.
- Decoded-cache insertion and active-subscriber eligibility are checked under the same lock. Last-subscriber cancellation removes any image that won an immediately preceding insertion race; another active subscriber preserves caching.
- The decode queue exposes a test-only enqueue hook. The queued-cancellation regression now proves the third operation was installed behind two blockers before canceling it.
- Sole-subscriber URL cancellation now has a deterministic regression asserting `CancellationError` and an observed custom-URL-protocol `stopLoading` call. The shared-waiter cancellation assertion also requires `CancellationError` exactly.
- Fresh second-cycle verification: arm64 iOS Simulator `build-for-testing` completed with `** TEST BUILD SUCCEEDED **`. Only existing deployment-target linker warnings were emitted.
