# Example: Subsonic Cylinder (Mach 0.5)

A 2D cylinder in subsonic compressible flow. Same geometry as the Mach 3
case but at much milder conditions, useful as a quick test that the
pipeline is wired up correctly without waiting an hour for solver
convergence.

## Geometry

Same as `mach3_cylinder/`: 1 m × 0.8 m domain, 0.1 m cylinder at (0.5, 0.4),
single-cell z-extrusion.

## Free-stream conditions

| Quantity | Value | Units |
|----------|-------|-------|
| Velocity (x) | 168 | m/s |
| Mach | ≈ 0.5 | — |
| Temperature | 288.15 | K |
| Pressure | 101325 | Pa |
| Wall T (fixed) | 300 | K |

## Pipeline configuration

* Solver: `rhoCentralFoam`
* Extraction mode: `gradient`, `gradient_field = rho` (density picks
  out the wake more clearly than pressure at low Mach)
* `sizing_min = 0.001`, `sizing_max = 0.015`, `sizing_scale = 100`
* 3 AMR loops

## Why this case

A reasonably sharp wake to refine around, but no shock. Use it as a quick
end-to-end smoke test: total wall time is around 25 minutes on 8 cores
versus 80+ minutes for the Mach 3 case.

The Mach 0.5 case was the original test case used during pipeline
development, before we extended it to supersonic conditions.

## Note on subsonic AMR

For subsonic incompressible flow, AMR around density gradients is somewhat
artificial — there's no real discontinuity. For practical incompressible
problems, vorticity-magnitude or velocity-component gradients usually work
better. We keep this case mainly as a regression test.
