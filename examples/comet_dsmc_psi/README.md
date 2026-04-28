# Example: COMET DSMC Plume-Surface Interaction

A rarefied-gas plume impinging on a flat surface, simulated with the
in-house COMET DSMC solver. Demonstrates the **direct extraction mode** of
the pipeline, where the AMR criterion is the local mean free path rather
than a gradient.

## What this case requires

Unlike the OpenFOAM examples, this case depends on **COMET**, our in-house
DSMC code. Compilation instructions for COMET are not part of this
repository (COMET has its own build system and is currently maintained by
the Computational Gas Dynamics Lab at UND). If you do not have COMET, this
example is for reference only — the pipeline configuration is shown to
illustrate how `direct` mode is wired up, but you cannot actually run the
case without the solver.

## Geometry

* 2D axisymmetric (wedge in OpenFOAM terminology, single-sector in COMET)
* 5 m radial × 80 m axial domain
* Inlet representing a thruster exit
* Far-field outlet on top and downstream
* Reflective surface (the spacecraft) at the outlet end

## Pipeline configuration

```ini
loops              = 3
extraction_mode    = direct
mfp_column         = mean free path
case_script        = run_centos_gmsh_nparts=1_groupsize=1.sh
case_script_amr    = run_centos_gmsh_nparts=1_groupsize=1_amr.sh
```

In `direct` mode, the pipeline reads the existing `mean free path` field
from COMET's VTU output and uses it directly as the AMR sizing target
(scaled by `pos_scale`, default 1.0). No gradient computation is involved.

## Why this case

This is the case the pipeline was originally written for. The DSMC
mean-free-path criterion is physically meaningful in a way the gradient
criterion is not — the mean free path is a real length scale that the DSMC
method needs the cells to resolve. Refining cells to be ~1 λ is the
canonical DSMC AMR criterion (Bird, 1994).

## Adapting `direct` mode to other solvers

If your solver writes a meaningful length scale (any well-known turbulence
length, Kolmogorov scale, integral scale, debris-flow particle size, etc.),
you can drive `direct` mode with that field instead. Just set:

```ini
extraction_mode    = direct
mfp_column         = your_field_name
```

and `final.py` will use that column as-is.

## Files

* `amr_pipeline.input` — shows the COMET configuration
* No `.geo` files or `0.orig` directory in this folder — those live in the
  COMET case directory and are not part of this repository.
