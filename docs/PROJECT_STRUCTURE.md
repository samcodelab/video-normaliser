# Project structure

Xcode and Swift Package Manager compile the same sources. Physical folders and Xcode groups match. The macOS application remains one module; grouping code does not imply that its platform dependencies have already been removed for iOS.

- `Sources/FrankLuma/App`: application entry point and observable orchestration.
- `UI`: timeline interaction. The main SwiftUI screen currently remains in `App/FrankLumaApp.swift`; splitting that large view is a separate behavioural refactor.
- `Documents`: project persistence.
- `Platform`: sandbox file access.
- `Core/Analysis`: exposure measurements, patch metering and illumination evidence.
- `Core/Correction`: scene targets, spatial tracking, correction models and opt-in prototypes.
- `Core/Rendering`: the image correction renderer.
- `Core/Media`: AVFoundation analysis, geometry, playback and export.
- `Tests/FrankLumaTests`: matching responsibility groups, shared test support and copied fixtures.
- `Configuration`: shared, application and distribution build settings.
- `Resources`: shipping application assets.
- `scripts/validation`: research and benchmark executables, separate from application target membership.
- `docs`: implementation reviews and evidence summaries. Frozen benchmark artifacts remain under `.build` and `dist/Benchmarks`.

Use `FrankLuma.xcodeproj` and the shared `FrankLuma` scheme for development and tests. Existing Developer ID and App Store schemes retain their signing configurations. `swift test` remains supported. Native audit build scripts share `scripts/correction-sources.sh`; update that manifest when adding a core source used by their standalone executables.

All Swift tests on disk are registered in the Xcode test target, including persistent lighting, surface identity and shared flash tests previously available only to Swift Package Manager. Run `python3 scripts/validate-project.py` to check membership and paths. For new files, add Xcode target membership as well as placing them in the appropriate folder. Do not add research harnesses or generated output to shipping resources.

Correction prototypes remain opt-in. `FRANKLUMA_QUIET_COLOUR_DIAGNOSTICS=1` prints aggregate evidence-gate rejection counts when the quiet-colour prototype is explicitly run; it does not enable correction or change its decisions. Counts describe evaluated footprints, not independent observations or probabilities.
