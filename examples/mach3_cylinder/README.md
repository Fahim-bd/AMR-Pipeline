# Example: Mach 3 Cylinder

A 2D cylinder in supersonic Mach 3 flow at 50 km altitude.

## Geometry

* Domain: 1 m × 0.8 m rectangle
* Cylinder: 0.1 m radius, centered at (0.5, 0.4)
* Single-cell extrusion in z (OpenFOAM 2D)

## Free-stream conditions (U.S. Standard Atmosphere @ 50 km)

| Quantity | Value | Units |
|----------|-------|-------|
| Velocity (x) | 990 | m/s |
| Mach | ≈ 3.0 | — |
| Temperature | 270.65 | K |
| Pressure | 79.78 | Pa |
| Wall T (fixed) | 800 | K |

## Pipeline configuration

* Solver: `rhoCentralFoam` with Kurganov flux + Minmod limiter
* Extraction mode: `gradient`, `gradient_field = p` (pressure)
* `sizing_min = 0.002`, `sizing_max = 0.015`, `sizing_scale = 100`
* 3 AMR loops

## Why this case

Strong, well-defined bow shock that any working AMR pipeline should resolve
clearly. Use it to confirm the pipeline is configured correctly before
tackling your own geometry. Wall time is around 80 minutes on 8 cores.

## Files in this directory

This is the case bundled at the repository root. The `amr_pipeline.input`,
`.geo` files, and OpenFOAM case files are identical to what is at the root
of the repo. Symlinks are used here to avoid duplication.
