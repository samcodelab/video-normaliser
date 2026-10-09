# Shared source manifest for native correction audit executables.
# Source after changing to the repository root (zsh).
typeset -a CORRECTION_SOURCES
CORRECTION_SOURCES=(
  Sources/FrankLuma/Core/Analysis/CommonIllumination.swift
  Sources/FrankLuma/Core/Analysis/Exposure.swift
  Sources/FrankLuma/Core/Analysis/PatchExposure.swift
  Sources/FrankLuma/Core/Correction/PulseReconstruction.swift
  Sources/FrankLuma/Core/Correction/QuietColourContinuity.swift
  Sources/FrankLuma/Core/Correction/Scenes.swift
  Sources/FrankLuma/Core/Correction/SpatialLighting.swift
  Sources/FrankLuma/Core/Media/VideoEngine.swift
  Sources/FrankLuma/Core/Media/VideoExporter.swift
  Sources/FrankLuma/Core/Media/VideoGeometry.swift
  Sources/FrankLuma/Core/Rendering/SpatialRenderer.swift
)
