# Repository-wide code-generation constraints

These constraints apply to all generated and modified code in this workspace. They are mandatory; do not weaken, bypass, or silently substitute them.

## Strict Swift concurrency

- Use Swift 6 and enable strict concurrency checking for Swift targets.
- Do not use completion handlers for asynchronous work. Use structured concurrency with `async`/`await`, `Task`, and appropriate actors.
- Isolate UI state and UI updates to `@MainActor`. Keep expensive work off the main actor and transfer data across actor boundaries safely.
- Every SwiftData model must conform to `Sendable`. Do not use `@unchecked Sendable` to bypass compiler diagnostics; keep model access actor-isolated and pass `Sendable` value snapshots across concurrency boundaries when needed.

## Native Apple frameworks only

- Do not add or use third-party dependencies, including CocoaPods or Swift Package Manager packages.
- Use only Apple's native frameworks.
- Route all matrix and vector transformations exclusively through Accelerate, vDSP, and SIMD.
- Route all drawing exclusively through Core Graphics and Metal.

## Topology verification

- Every generated UV-unwrapping or topological-morphing algorithm must include and run a Chain-of-Verification function.
- The verification must calculate the source 3D mesh surface area and resulting 2D island area using consistent units and triangulation, then calculate their relative area delta.
- If the delta is greater than 5%, throw `TopologyError`. Do not return an unverified result as successful.
- Reject degenerate or non-finite geometry explicitly; do not silently accept it as verified.

## Print output standards

- Any code that interacts with `CGPath`, `NSPrintOperation`, or PDFKit must, by default, generate a mathematically correct 1/4-inch parallel seam-offset curve and include a locked 5 cm × 5 cm (2 in × 2 in) calibration square on the first page.
- Keep the calibration square at its physical dimensions; do not let fit-to-page scaling or printer margins resize it.
- Preserve physical scale in print and PDF output. Surface unsupported geometry or print configurations as explicit errors.
