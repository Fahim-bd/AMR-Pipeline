# Methodology

This document describes the AMR criterion the pipeline uses, the sizing
formula it applies, and the relevant literature.

The pipeline supports two extraction modes — **direct** and **gradient**.
They produce conceptually similar sizing fields but draw on different
information available from the underlying solver.

---

## 1. The problem we are solving

Computational meshes for shock-dominated flow, plume-surface interaction, or
strongly rarefied gas behavior need cells that are small in some regions
(the shock, the leading edge, the boundary layer) and can be much larger
elsewhere. Hand-tuning these meshes for every geometry and every flow
condition is slow, error-prone, and hard to defend in a publication.

Adaptive mesh refinement (AMR) replaces the hand-tuning with an automated
loop:

1. Run the solver on a coarse mesh.
2. Look at the result.
3. Identify a quantity that flags "interesting" cells.
4. Build a new mesh that is finer wherever that quantity is large.
5. Re-run the solver. Go back to step 2.

The choice of "quantity that flags interesting cells" is the heart of any
AMR method. There are many options in the literature:

* **Hessian-based metrics** (Frey & Alauzet, 2005)
* **Adjoint-based goal-oriented criteria** (Becker & Rannacher, 2001;
  Venditti & Darmofal, 2002)
* **Gradient-magnitude criteria** (Berger & Oliger, 1984; Powell et al.,
  1992)
* **Mean-free-path criteria for DSMC** (Bird, 1994; Rader et al., 2006)

Our pipeline implements two of these — the gradient-magnitude criterion (for
CFD) and the mean-free-path criterion (for DSMC). Both produce a continuous
*sizing field* `h(x, y, z)` rather than a discrete refine/coarsen flag.

---

## 2. Why a sizing field, not a flag

Two choices come up when implementing an AMR step:

**Discrete flagging.** Mark each cell as "refine" or "keep". Subdivide the
flagged cells into smaller cells (octree, quadtree, h-refinement). This is
how most in-solver AMR (OpenFOAM's `dynamicRefineFvMesh`, AMReX, Chombo)
works.

**Continuous sizing.** Compute a target cell size `h(x, y, z)` everywhere in
the domain. Hand the field to a mesh generator and let it remesh from
scratch.

The continuous approach is better suited to **unstructured triangular and
tetrahedral meshes from Gmsh**, where the mesh generator already accepts
sizing fields natively (the `Mesh.SizeMin`, `Mesh.SizeMax`,
`Background Field` mechanism). It also produces meshes that are smooth
everywhere instead of having sudden cell-size jumps at refinement boundaries.

The trade-off is that we lose direct field-to-field interpolation between
iterations. Each iteration is a fresh solver run on a brand-new mesh. For
steady-state and quasi-steady problems this is acceptable; for genuinely
transient AMR within one run, it would not be.

---

## 3. Mode 1: direct extraction (DSMC)

The DSMC solver (COMET) writes a `mean free path` field as part of its
standard output. The mean free path is

$$
\lambda = \frac{1}{\sqrt{2}\, \pi d^2 n}
$$

where `n` is the local number density of the simulated gas and `d` is the
hard-sphere diameter. This is a meaningful length scale for DSMC: a cell
larger than a few mean free paths violates the underlying assumption of the
direct simulation Monte Carlo method (Bird 1994, §1.4).

The classical DSMC AMR criterion is

$$
h \;=\; c\, \lambda
$$

with `c` typically between 1/3 and 1. We use `c = 1` directly (`pos_scale =
1.0` in the input file) so that target cell size = local mean free path.
Because DSMC needs cells **smaller** than λ in the dense regions, and a
fully resolved DSMC at `h = λ` is already an aggressive choice, we do not
try to oversample.

### What the pipeline does in this mode

`final.py` reads the existing `mean free path` column from the VTU file,
extracts `(x, y, z, λ)` per grid point, and writes a Gmsh `.pos` view:

```
View "MFP" {
  SP(0.012, 0.045, 0.005){0.000823};
  SP(0.013, 0.045, 0.005){0.000819};
  ...
};
```

Gmsh interpolates between these scalar points using its `Background Field`
mechanism. Cells around the `SP` location end up with size ≈ `λ` at that
point.

### References for the DSMC criterion

* G. A. Bird. *Molecular Gas Dynamics and the Direct Simulation of Gas
  Flows.* Oxford University Press, 1994. (The canonical text — §1.4 covers
  the mean free path; §11 covers cell-size requirements.)
* D. J. Rader, M. A. Gallis, J. R. Torczynski, W. Wagner.
  *Direct simulation Monte Carlo convergence behavior of the hard-sphere-gas
  thermal conductivity for Fourier heat flow.* Physics of Fluids 18, 077102
  (2006). (Modern numerical study of cell-size requirements.)

---

## 4. Mode 2: gradient extraction (CFD)

OpenFOAM does not output a mean-free-path field — it solves continuum
equations and the concept does not appear in its data structure. We need a
different criterion.

The standard continuum-CFD choice is to refine where a chosen scalar field
varies rapidly. For supersonic flow the natural pick is the pressure (sharp
shocks) or density (sharp shocks plus contact discontinuities). For
incompressible flow with vortices, the velocity-magnitude gradient or the
vorticity magnitude work better.

### The sizing formula

We map gradient magnitude to a target cell size with

$$
h(\mathbf{x}) \;=\; h_{\min} \;+\; \frac{h_{\max} - h_{\min}}{1 \;+\;
\alpha\, \dfrac{|\nabla F(\mathbf{x})|}{|\nabla F|_{\max}}}
$$

where

* `F` is the chosen scalar field (`p`, `rho`, `T`, …)
* `|∇F|` is the magnitude of its gradient at point `x`
* `|∇F|_max` is the maximum gradient magnitude over the whole domain
* `h_min`, `h_max` are user-specified lower/upper bounds (the keys
  `sizing_min` and `sizing_max` in `amr_pipeline.input`)
* `α` is a steepness parameter (the key `sizing_scale`)

### Behavior

The formula has three useful limits:

| Region                   | Value of `|∇F|/|∇F|_max` | `h(x)` ≈        |
|--------------------------|--------------------------|------------------|
| At the strongest gradient | 1                        | `h_min + (h_max−h_min)/(1+α)` ≈ `h_min` for large α |
| In a "moderate" region    | ~0.1                     | `h_min + (h_max−h_min)/(1 + 0.1·α)`                |
| Far field                 | 0                        | `h_max`                                            |

So with `α = 100`, a region with 10% of the maximum gradient gets ten times
the minimum cell size, and the far field gets `h_max`. With `α = 1000`, the
refinement is much sharper — cells go to `h_min` only at the very strongest
gradient and recover to `h_max` quickly elsewhere.

We picked this functional form deliberately. Three alternatives we
considered and rejected:

* **Linear:** `h = h_max − (h_max − h_min)·|∇F|/|∇F|_max`. Gives a smooth
  transition but produces too many fine cells in regions with moderate
  gradients.
* **Power-law:** `h = h_min · (|∇F|/|∇F|_max)^{−p}`. Diverges in the far
  field and needs a hard upper cap, which makes the result discontinuous.
* **Exponential:** `h = h_min · exp(−α·|∇F|/|∇F|_max)`. Saturates too
  quickly to `h_min`; doesn't smoothly recover.

The rational form `1 / (1 + α·x)` we use is bounded above and below by
construction, smooth everywhere, and has one tuning knob (`α`) with a clear
physical interpretation. It is the form recommended in Frey & Alauzet
(2005, §4.2) for goal-driven anisotropic adaptation; we use the isotropic
specialization (target `h` rather than a metric tensor) because Gmsh's
`Background Field` mechanism is isotropic.

### References for the gradient criterion

* P. J. Frey and F. Alauzet. *Anisotropic mesh adaptation for CFD
  computations.* Computer Methods in Applied Mechanics and Engineering,
  194(48–49):5068–5082, 2005. (The metric-based formulation we drew the
  sizing function from.)
* M. J. Berger and J. Oliger. *Adaptive mesh refinement for hyperbolic
  partial differential equations.* Journal of Computational Physics,
  53(3):484–512, 1984. (The original AMR paper.)
* R. Löhner. *Three-dimensional fluid-structure interaction using a finite
  element solver and adaptive remeshing.* Computer Systems in Engineering,
  1(2–4):257–272, 1990. (Early gradient-driven remeshing.)

---

## 5. Comparison of the two modes

| Aspect                         | Direct (DSMC)              | Gradient (CFD)             |
|--------------------------------|-----------------------------|-----------------------------|
| Solver requirement              | Must output mean free path  | Must output the chosen scalar |
| Solver dependency               | Strong (DSMC only)          | Solver-agnostic             |
| Tuning knobs                    | `pos_scale` only            | `sizing_min`, `sizing_max`, `sizing_scale` |
| Refines around                  | Dense gas, plumes           | Shocks, BLs (depending on `gradient_field`) |
| Physical interpretation         | Strong (λ is a real scale)  | Empirical                   |
| Behavior with poor solutions    | Gracefully degrades         | Sensitive (junk gradients → bad mesh) |

For DSMC problems, prefer direct mode. For CFD, gradient mode is the
practical choice.

---

## 6. Choice of `gradient_field` in CFD mode

Different scalars highlight different features. Some rules of thumb based on
my experience with the test cases in `examples/`:

* **`p` (pressure)**. Best for shock-dominated supersonic flow. Sharp,
  clean. The Mach 3 cylinder result in [TUTORIAL.md](TUTORIAL.md) uses this.
* **`rho` (density)**. Slightly more sensitive than `p`; picks up contact
  discontinuities and slip lines that pressure misses. Good for blast
  problems and for cases with strong species mixing.
* **`T` (temperature)**. Picks out boundary layers and viscous regions in
  addition to shocks. Good for hypersonic vehicles where boundary-layer
  resolution matters.
* **Velocity components** (`U:0`, `U:1`, `U:2`). Pick out vortex sheets
  and shear layers. Useful for incompressible separated flows.
* **Vorticity magnitude** (you'd need to add a `Calculator` step in
  `final.py`). Good for vortex-shedding problems.

Picking the right field matters more than tuning `sizing_scale`. A
correctly chosen field with default `α = 100` usually does better than a
poorly chosen field with carefully tuned `α`.

---

## 7. Limitations

The pipeline is honest about what it does and does not do. Three things
worth knowing:

### It is not anisotropic.

Gmsh's `Background Field = PostView` mechanism is isotropic — each cell
gets a single scalar size. Truly anisotropic adaptation (cells stretched
along the shock direction) needs metric-tensor information, which Gmsh
does not currently support in this mode. For most external flows the
isotropic version is good enough; for boundary layers it is not, and you
will need to fall back to a hand-built body-fitted mesh or a different
mesher (e.g. `mmg`, which does support full metric-driven adaptation).

### It re-runs the solver from scratch each iteration.

There is no time-marching across mesh changes. For steady-state problems
this is fine — each iteration converges to the same physical solution on a
better mesh. For genuinely transient AMR (the shock moves with time during
one run) this approach is wrong by construction.

### It uses the last-time-step solution to drive the next mesh.

`final.py` always reads the final timestep of the previous run. If the
solver has not yet converged by that timestep, the gradient field is
inaccurate and the AMR mesh will be refined in the wrong place. For
rhoCentralFoam, our default `endTime = 0.001` s is enough to reach a
steady wake for the Mach 3 cylinder; for slower-converging problems you
may need a longer run.

---

## 8. Sanity checks while running

The pipeline writes enough information to disk that you can confirm it is
doing the right thing without ever opening ParaView. Two things to watch:

**Cell count should grow with loop number.** Run

```bash
for f in gmsh/2d_cylinder*.msh; do
    echo -n "$f: "
    grep -A 1 '\$Elements' "$f" | tail -1
done
```

If the AMR mesh after iteration 2 is the same size as after iteration 1,
either the gradient field has reached its converged shape (rare after only
two loops) or the sizing parameters are too coarse to register the
refinement. Try a smaller `sizing_min` or larger `sizing_scale`.

**Maximum gradient should increase or stabilize.** `final.py` prints

```
[INFO] Max p gradient magnitude: 184523.7
```

once per iteration. Compare across `logs/csv_2_pos_1.txt`,
`csv_2_pos_2.txt`, `csv_2_pos_3.txt`. The number should grow (the finer
mesh resolves the shock more sharply, so the gradient measurement gets
sharper too) and eventually plateau. If it shrinks loop-to-loop, the AMR
has spread out instead of focusing — typically a sign of `sizing_scale` set
too low.

These are software-side checks. They tell you the pipeline is converging
on a self-consistent mesh, not that the physical solution is correct —
verifying the latter is the user's responsibility and should be done with
a problem-specific quantity of interest (drag, peak pressure, heat flux,
etc.) using whatever validation procedure your community considers
adequate.

---

## 9. Bibliography

```bibtex
@book{bird1994,
    author    = {G. A. Bird},
    title     = {Molecular Gas Dynamics and the Direct Simulation of Gas Flows},
    publisher = {Oxford University Press},
    year      = 1994
}

@article{frey_alauzet_2005,
    author  = {P. J. Frey and F. Alauzet},
    title   = {Anisotropic mesh adaptation for {CFD} computations},
    journal = {Computer Methods in Applied Mechanics and Engineering},
    volume  = 194,
    number  = {48--49},
    pages   = {5068--5082},
    year    = 2005
}

@article{berger_oliger_1984,
    author  = {M. J. Berger and J. Oliger},
    title   = {Adaptive mesh refinement for hyperbolic partial differential equations},
    journal = {Journal of Computational Physics},
    volume  = 53,
    number  = 3,
    pages   = {484--512},
    year    = 1984
}

@article{lohner_1990,
    author  = {R. L\"ohner},
    title   = {Three-dimensional fluid-structure interaction using a finite element solver and adaptive remeshing},
    journal = {Computer Systems in Engineering},
    volume  = 1,
    number  = {2--4},
    pages   = {257--272},
    year    = 1990
}

@article{rader_2006,
    author  = {D. J. Rader and M. A. Gallis and J. R. Torczynski and W. Wagner},
    title   = {Direct simulation Monte Carlo convergence behavior of the hard-sphere-gas thermal conductivity for {F}ourier heat flow},
    journal = {Physics of Fluids},
    volume  = 18,
    pages   = {077102},
    year    = 2006
}

@article{venditti_darmofal_2002,
    author  = {D. A. Venditti and D. L. Darmofal},
    title   = {Grid adaptation for functional outputs: application to two-dimensional inviscid flows},
    journal = {Journal of Computational Physics},
    volume  = 176,
    number  = 1,
    pages   = {40--69},
    year    = 2002
}

@article{powell_1992,
    author  = {K. G. Powell and P. L. Roe and J. Quirk},
    title   = {Adaptive-mesh algorithms for computational fluid dynamics},
    booktitle = {Algorithmic Trends in Computational Fluid Dynamics},
    publisher = {Springer},
    pages   = {303--337},
    year    = 1992
}
```
