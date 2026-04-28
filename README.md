# AMR-Pipeline

**A solver-agnostic adaptive mesh refinement pipeline for CFD and DSMC simulations.**

---

I built this pipeline during my master's research at the Computational Gas
Dynamics Lab (UND) because I kept losing days to manual remeshing. Every time a
shock moved or a plume sharpened, I had to stop the run, open Gmsh, redraw
characteristic lengths, regenerate the mesh, edit the case directory by hand,
and restart. After the third or fourth iteration of doing this for a single
case I decided to script it.

The pipeline is solver-agnostic. The only thing it really needs from a solver
is a folder of VTU files at the end of the run. We currently demonstrate it
with two solvers:

* **OpenFOAM v2406** — `rhoCentralFoam` for compressible CFD (and any other
  finite-volume solver that produces VTK output).
* **COMET** — an in-house DSMC code for rarefied flows.

Adding a third solver only takes a small wrapper script. The orchestrator
(`all_run.sh`), the field extractor (`final.py`), and the Gmsh background-field
mechanism do not change.

The pipeline is described in the SoftwareX manuscript currently in preparation:

> Shahriyar, F., Diallo, A., Zhang, C. *Automated mean-free-path-based AMR for
> rarefied gas flow simulations.* (in prep, 2026).

---

## What it does, in one paragraph

Given a Gmsh `.geo` file, an OpenFOAM (or COMET) case directory, and a single
text input file, the pipeline runs the solver, reads the VTU output, computes a
sizing field from either the mean free path (DSMC) or the gradient of a chosen
scalar (CFD), writes that sizing field as a Gmsh `.pos` background view,
regenerates the mesh from the same `.geo` file, and re-runs the solver on the
new mesh. It does this for as many adaptive loops as you ask for, archiving
every intermediate mesh and result so you can compare them later.

## The flow

```
.geo  ─────►  Gmsh  ─────►  .msh  ─────►  Solver  ─────►  .vtu
                                                            │
                                                            ▼
                                              pvpython + final.py
                                                            │
                                                            ▼
                                                  sizing field (.pos)
                                                            │
                                                            ▼
.geo_amr  ───►  Gmsh (background field)  ───►  .msh (refined)  ──►  Solver  ──► …
```

Repeat *N* times. The Gmsh `.geo` file with the AMR background field is the
trick — Gmsh natively supports `Background Field = 1` driven by a `PostView`,
and that is all we use to communicate "make cells smaller here" back to the
mesher. No custom mesh-modification library, no remapping of solution data.
Each loop is a clean restart on a freshly generated mesh.

## What you get out of it

Three things, archived per iteration:

1. **Meshes**: `gmsh/2d_cylinder1.msh`, `gmsh/2d_cylinder_amr1.msh`,
   `2d_cylinder_amr2.msh`, `2d_cylinder_amr3.msh`, …
2. **Solver results**: `comet_result/output_normal1_result/`,
   `comet_result/output_amr1_result/`, … (full VTK trees plus a `.pvd`).
3. **Logs**: `logs/output_normal1.txt`, `logs/output_amr1.txt`, … and the
   field-extraction logs.

Nothing is overwritten between iterations. You can plot mesh-1 vs mesh-3 in
ParaView or scp the whole tree to a local machine for post-processing.

---

## Quick look (5 minutes)

Assuming OpenFOAM v2406, Gmsh 4.x, and ParaView 5.x are already on your
machine (see [INSTALL.md](INSTALL.md) if not):

```bash
git clone https://github.com/Fahim-bd/AMR-Pipeline.git
cd AMR-Pipeline

# Edit just one file: paths to your gmsh/pvpython binaries
$EDITOR amr_pipeline.input

# Run
./all_run.sh
```

That kicks off the bundled Mach-3 cylinder case (50 km altitude, 990 m/s,
T∞=270.65 K, isothermal wall at 800 K) on three AMR loops. On a desktop with
8 cores, total wall time is in the 30–60 minute range.

The full step-by-step walkthrough — what every command does, what to expect at
each stage, how to read the logs — is in [TUTORIAL.md](TUTORIAL.md).

---

## What's in this repository

```
AMR-Pipeline/
├── README.md                      this file
├── INSTALL.md                     OpenFOAM + Gmsh + ParaView setup
├── TUTORIAL.md                    Mach-3 cylinder reproduction, end-to-end
├── CONFIG_REFERENCE.md            every key in amr_pipeline.input, explained
├── METHODOLOGY.md                 sizing formula and refs (Frey & Alauzet etc.)
├── ADDING_A_SOLVER.md             how to wrap a new solver
├── TROUBLESHOOTING.md             real errors I hit, how I fixed them
├── CITATION.cff                   citation metadata
├── LICENSE
│
├── amr_pipeline.input             ◄── the only file users edit
├── all_run.sh                     pipeline orchestrator
├── final.py                       field extractor (pvpython)
├── run_openfoam.sh                OpenFOAM wrapper, normal mesh
├── run_openfoam_amr.sh            OpenFOAM wrapper, AMR mesh
├── build_pvd_from_steps.sh        helper for building .pvd files
│
├── gmsh/
│   ├── 2d_cylinder.geo            coarse-mesh geometry (Mach 3 demo)
│   └── 2d_cylinder_amr.geo        same geometry, with PostView background
│
├── openfoam_case/
│   ├── 0.orig/                    initial conditions (p, U, T)
│   ├── constant/                  thermo and turbulence properties
│   └── system/                    controlDict, fvSchemes, fvSolution
│
└── examples/
    ├── subsonic_cylinder/         Mach 0.5 (the early test case)
    ├── mach3_cylinder/            the Mach 3 case used as primary demo
    └── comet_dsmc_psi/            DSMC plume-surface example (config only)
```

---

## Software requirements

The pipeline shells out to several external tools. Versions I have tested
against are listed first; older versions may work but are not exercised.

| Tool      | Tested        | Purpose                          | Where it's used                |
|-----------|---------------|----------------------------------|--------------------------------|
| Gmsh      | 4.11.1        | Mesh generation                  | `run_gmsh` in `all_run.sh`     |
| OpenFOAM  | v2406         | CFD solver (one of the demos)    | `run_openfoam.sh`              |
| ParaView  | 5.13.2-MPI    | Field extraction (`pvpython`)    | `final.py`                     |
| Python    | 3.9+          | Boundary-fix logic in wrappers   | `run_openfoam.sh` (inline)     |
| Bash      | 4.0+          | Orchestrator language            | `all_run.sh`                   |
| GCC       | 11.x          | Building OpenFOAM from source    | (install only)                 |

Linux is the only OS I have tested. The development host is CentOS Stream 9
with 32 cores and 64 GB RAM. WSL2 should work but I have not personally run it.

For the COMET DSMC demo you also need our in-house solver, which is documented
separately. The Mach 3 OpenFOAM case is fully self-contained.

---

## Why a wrapper, not in-solver AMR?

OpenFOAM ships with `dynamicMeshDict`-based refinement and several other
projects (Basilisk, AMReX, OpenFOAM's own `dynamicRefineFvMesh`) handle mesh
adaptation inside the solver. Those work well when:

* The grid is structured or hex-cell.
* The solver is the one you control.

Most of our work is on **unstructured triangular/tetrahedral meshes from
Gmsh**, with the same geometry being passed between an in-house DSMC code and
OpenFOAM for cross-validation. In-solver AMR ties the mesh to one solver. We
needed a workflow where the mesh, the geometry, and the AMR criterion live
**outside** any solver and can be swapped between codes.

That's why this is a wrapper. It does mean we re-run the solver from scratch
each iteration (no time-marching across mesh changes). For steady-state and
quasi-steady problems that's a fine trade-off. For genuinely transient AMR
during a single run, it isn't the right tool.

---

## Citing

If this pipeline helps your work, please cite the SoftwareX paper (when
published) and this repository:

```bibtex
@software{shahriyar_amr_pipeline_2026,
  author  = {Shahriyar, Fahim and Diallo, Alseny and Zhang, Chonglin},
  title   = {AMR-Pipeline: A solver-agnostic adaptive mesh refinement pipeline
             for CFD and DSMC simulations},
  year    = {2026},
  url     = {https://github.com/Fahim-bd/AMR-Pipeline},
  note    = {Computational Gas Dynamics Lab, University of North Dakota}
}
```

A `CITATION.cff` is also provided so GitHub's "Cite this repository" button
picks it up.

---

## Authors and acknowledgements

* **Fahim Shahriyar** — design, implementation, testing
  (M.S. Mechanical Engineering, University of North Dakota, 2026)
* **Dr. Chonglin Zhang** — supervision and review
* **Alseny Diallo** — earlier prototyping of the COMET-only version

Built as part of work on plume-surface interaction for the Artemis II program
context. The mean-free-path AMR criterion grew out of the DSMC side of that
work; the gradient-based criterion was added later so the same pipeline could
drive OpenFOAM.

This material is based on work supported by the University of North Dakota.
Any opinions, findings, conclusions, or recommendations expressed are those of
the authors and do not necessarily reflect the views of the supporting
institutions.

---

## License

MIT License. See [LICENSE](LICENSE).

---

## Where to go next

* **Install the dependencies →** [INSTALL.md](INSTALL.md)
* **Reproduce the Mach 3 cylinder →** [TUTORIAL.md](TUTORIAL.md)
* **Understand the sizing formula →** [METHODOLOGY.md](METHODOLOGY.md)
* **Wrap a new solver →** [ADDING_A_SOLVER.md](ADDING_A_SOLVER.md)
* **Hit an error? →** [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
