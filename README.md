# Plushboii 🪡

**Plushboii** is a native macOS desktop application designed to automatically generate 2D plushie sewing patterns from 2D reference images or 3D models. It is built exclusively for Apple Silicon, running all neural inferences entirely on-device without external APIs.

## 🏗️ Core Architecture & Tech Stack

- **Platform:** macOS 14+ (Apple Silicon exclusive)
- **Language:** Swift 6 (Strict Concurrency enabled: `async/await`, `@MainActor`, `Sendable`)
- **UI Framework:** SwiftUI
- **Local Database:** SwiftData (Schemas: `Pattern`, `PatternPiece`, `ControlPoint`)
- **On-Device AI:** Core ML & Vision
- **Math & Geometry:** Accelerate (vDSP/SIMD), Metal Compute Shaders, SceneKit, ModelIO

## 🧠 The Generation Pipeline

Plushboii relies on a completely local, multi-stage pipeline to go from a flat image to a printable sewing pattern:

1. **Vision Preprocessing:** The user selects a 2D image. Apple's `Vision` framework (`VNGenerateForegroundInstanceMaskRequest`) strips the background. Core Image crops and scales the isolated subject into a 512x512 `CVPixelBuffer`.
2. **Neural Inference (TripoSR):** The buffer is passed to a custom `.mlpackage` (TripoSR) bundled in the app. The Core ML model utilizes the Apple Neural Engine (ANE) to output a dense 3D volumetric grid (shape: `[1, 1, 64, 64, 64]`).
3. **Topology Math Engine:** A native Swift/Metal implementation of the Marching Cubes algorithm evaluates the Core ML density grid to extract 3D vertices and faces (`MDLMesh`).
4. **Parametric Grading & Flattening:** The 3D geometry is algorithmically flattened into 2D vector panels. Thin Plate Splines and material elasticity parameters (e.g., for fleece vs. duck canvas) stretch and morph the pattern.
5. **Print & Export:** The final 2D vectors are output via `NSPrintOperation` for tiled printing (US Letter with crop marks) or exported as A0 vector PDFs for projector tracing.

## 🤖 Copilot Engineering Guidelines

If you are an AI agent or Copilot contributing to this repository, you must adhere to the following rules:

- **NO Third-Party Dependencies:** Do not suggest CocoaPods, Carthage, or SPM packages unless explicitly requested. Rely on native Apple frameworks.
- **NO External APIs:** Do not implement REST calls, Python subprocesses, or cloud generative APIs. All AI processing happens locally via `.mlpackage`.
- **Strict Swift 6:** Do not use completion handlers or GCD (`DispatchQueue`). Use `Task`, `async/await`, and `Actor` isolation exclusively.
- **Parametric Priority:** Hardcoded UI frames are banned. All pattern manipulation must be parametric and driven by SwiftData state.
