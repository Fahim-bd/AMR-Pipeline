# Configuration reference

Every key the pipeline reads from `amr_pipeline.input`, what it does, what the
default is, and what kinds of values make sense. Keys are grouped by what
part of the pipeline they affect.

The file format is a simple Fortran-style namelist: lines look like
`key = value`, blank lines and `!` or `#` comment lines are ignored, and the
file is bracketed by `&amr_input` ... `/`. Strings can be quoted or not;
booleans are `true`/`false` (case-insensitive).

The pipeline can also read every one of these as a CLI flag (`--loops 5`,
`--gradient-field rho`, etc.) and as a shell environment variable in
upper-case (`LOOPS=5 ./all_run.sh`). Resolution order is: CLI flag overrides
input file overrides environment variable overrides default.

---

## Core pipeline settings

### `loops`

How many AMR iterations to run. Minimum is 1. There is no hard upper bound,
but in practice 3–5 is enough for most steady cases. Beyond that the cell
count keeps growing without much improvement in the solution.

* Default: `3`
* Typical: `3` to `5`

### `base_dir`

The working directory the pipeline operates in. If left blank, `all_run.sh`
auto-detects: it picks the current directory if it contains a `gmsh/`
subfolder, otherwise the directory where `all_run.sh` itself lives.

Almost no one needs to set this. Leave it blank.

* Default: auto-detect

### `gmsh_bin`

Absolute path to the `gmsh` binary. The pipeline calls Gmsh in batch mode
(`gmsh file.geo -3 -o file.msh`) once per iteration to generate the mesh.

If left blank, the orchestrator searches `$HOME`, `$PATH`, and a couple of
hard-coded locations under `~/dsmc` for a working `gmsh`. If you have only
one Gmsh on the machine and it's on `$PATH`, the auto-detect will find it.

* Default: auto-detect
* Typical: `/home/USER/gmsh/gmsh-4.11.1-Linux64/bin/gmsh`

### `pvpython`

Absolute path to ParaView's `pvpython`. This is what runs `final.py` to do
the field extraction. Must be the **MPI build** of ParaView (the OSMesa
build is missing some filters `final.py` uses).

* Default: `pvpython` (assumes it's on `$PATH`)
* Typical: `/home/USER/paraview/ParaView-5.13.2-MPI-Linux-Python3.10-x86_64/bin/pvpython`

---

## Geometry and mesh files

### `geo_file`

The Gmsh `.geo` file used to generate the **first** (coarse) mesh. Resolved
relative to `base_dir/gmsh/` if not absolute.

* Default: `2d_axisym.geo`
* Bundled example: `2d_cylinder.geo`

### `geo_file_amr`

The Gmsh `.geo` file used for **every iteration after the first**. Must
contain `Merge "mfp.pos";` and `Background Field = 1;` so that Gmsh reads
the AMR sizing field. Otherwise it would just produce another coarse mesh.

* Default: `2d_axisym_amr.geo`
* Bundled example: `2d_cylinder_amr.geo`

### `sim_mesh`

The output filename of the coarse mesh. The orchestrator writes this once
per first iteration and copies it both to `gmsh/` (working file) and as a
numbered backup `<basename>1.msh`.

* Default: `2d_axisym.msh`
* Bundled example: `2d_cylinder.msh`

### `sim_mesh_amr`

The output filename of each AMR mesh. The orchestrator overwrites this each
iteration but also keeps numbered backups (`<basename>1.msh`,
`<basename>2.msh`, …) so all intermediate meshes are preserved.

* Default: `2d_axisym_amr.msh`
* Bundled example: `2d_cylinder_amr.msh`

### `start_amr_mesh`

Optional. If you already have a refined mesh you want to use as the starting
point (e.g. from a previous run), set this to its path. The pipeline will
skip generating a coarse mesh and start from your mesh on iteration 1.

* Default: blank (start from `geo_file`)

---

## Solver run scripts

### `case_script`

The shell script the orchestrator runs to invoke the solver on the
**coarse** mesh. The script is responsible for:

1. Converting `gmsh/<sim_mesh>` into the solver's mesh format
2. Running the solver
3. Producing VTK/VTU output under `comet_result/field/step_*/field*.vtu`

For OpenFOAM cases this is `run_openfoam.sh`, which reads everything else it
needs from `amr_pipeline.input`. For COMET cases this is the project-supplied
`run_centos_gmsh_nparts=*_groupsize=*.sh`. For your own solver, see
[ADDING_A_SOLVER.md](ADDING_A_SOLVER.md).

* Default: `run_centos_gmsh_nparts=1_groupsize=1.sh`
* OpenFOAM: `run_openfoam.sh`

### `case_script_amr`

Same idea as `case_script`, but used for **every iteration after the first**.
For OpenFOAM this is `run_openfoam_amr.sh` (which reads `sim_mesh_amr`
instead of `sim_mesh` — that's the only difference).

* Default: `run_centos_gmsh_nparts=1_groupsize=1_amr.sh`
* OpenFOAM: `run_openfoam_amr.sh`

### `final_py`

Path to the field-extraction Python script that runs under `pvpython`. You
should not need to change this unless you are doing development on the
extractor itself.

* Default: `final.py`

---

## Field extraction

### `extraction_mode`

How `final.py` produces the per-point sizing values.

* `direct` — read an existing column from the solver's output. This is what
  COMET uses; the column is `mean free path`, written by the DSMC solver
  natively.
* `gradient` — compute `grad(field)` and convert it to a sizing field via
  the formula in [METHODOLOGY.md](METHODOLOGY.md). This is what OpenFOAM
  uses, since OpenFOAM does not write a mean-free-path field.

* Default: `direct`
* For OpenFOAM: `gradient`

### `gradient_field`

Only used when `extraction_mode = gradient`. The scalar field whose gradient
is computed. Pick whichever one represents the feature you want to refine
around:

| Field | What it picks out                                       |
|-------|---------------------------------------------------------|
| `p`   | Shocks (sharp pressure jumps)                           |
| `rho` | Shocks and contact discontinuities (slightly sharper than `p`) |
| `T`   | Boundary layers and shocks                              |
| `U:0` | Vortex sheets and shear layers (vector components)      |

* Default: blank
* Mach 3 cylinder: `p`

### `sizing_min`

Lower bound on the sizing field, in meters. Cells in the highest-gradient
region of the domain end up with this size. **Don't go too small** — a cell
size of 1 mm in a 1 m domain is already quite a lot of cells, and pushing
below 0.1 mm starts producing aspect-ratio problems and unstable solver runs.

* Default: `0.001`
* Mach 3 cylinder: `0.002`

### `sizing_max`

Upper bound on the sizing field, in meters. Far-field cells (where the
gradient is essentially zero) end up close to this size. Set to roughly the
characteristic-length-max of your `.geo` file.

* Default: `0.015`

### `sizing_scale`

Steepness of the gradient → size mapping. Larger values make the refinement
"sharper" — more concentrated in the high-gradient region, less smearing
into surrounding cells.

* Default: `100.0`
* Range I have used: `50.0` (smooth) to `300.0` (very sharp)

The full formula is

```
h = sizing_min + (sizing_max − sizing_min) / (1 + sizing_scale · |∇F|/max|∇F|)
```

so `sizing_scale = 0` would give a uniform mesh at `sizing_max` and
`sizing_scale → ∞` would give a step function.

### `mfp_column`

The CSV column name `final.py` extracts after running. In `direct` mode this
must match the name written by the solver (`mean free path` for COMET). In
`gradient` mode this is the name `final.py` uses for the computed sizing
column — it should match `<gradient_field>_sizing`.

| Mode      | Typical value      |
|-----------|--------------------|
| `direct`  | `mean free path`   |
| `gradient` (p)   | `p_sizing`  |
| `gradient` (rho) | `rho_sizing`|
| `gradient` (T)   | `T_sizing`  |

* Default: `mean free path`

### `pos_scale`

Multiplier applied to every value before writing the `.pos`. Useful if your
sizing field is in mm but Gmsh expects meters, or if you want to globally
coarsen/refine the AMR result.

* Default: `1.0`

---

## OpenFOAM-specific settings

These keys are read by `run_openfoam.sh` and `run_openfoam_amr.sh`. They are
ignored by COMET and by other solver wrappers.

### `foam_source`

Absolute path to the OpenFOAM environment script. The wrapper sources this
before calling `gmshToFoam`, `rhoCentralFoam`, `foamToVTK`, etc.

* Default: blank
* Typical: `/home/USER/OpenFOAM/OpenFOAM-v2406/etc/bashrc`

### `solver`

The OpenFOAM solver executable. Anything that takes a polyMesh and writes
field output works here:

| Solver             | When to use it                        |
|--------------------|---------------------------------------|
| `rhoCentralFoam`   | Compressible, supersonic              |
| `sonicFoam`        | Compressible, transonic               |
| `simpleFoam`       | Steady incompressible                 |
| `pisoFoam`         | Transient incompressible              |
| `chtMultiRegionFoam` | Conjugate heat transfer            |

* Default: `rhoCentralFoam`

### `case_dir`

The OpenFOAM case directory, relative to `base_dir`. Must contain `0.orig/`,
`constant/`, and `system/`. The wrapper copies `0.orig` to `0` before each
run, so `0.orig` is never touched.

* Default: `openfoam_case`

### `boundary_fix`

A comma-separated list of `patch_name:openfoam_type` rules that the wrapper
applies after `gmshToFoam`. Gmsh writes every patch as type `patch`, but
OpenFOAM needs specific types for some of them.

Format:

```
boundary_fix = frontAndBack:empty, wall:wall, top:symmetryPlane
```

Common types you'll need:

| OpenFOAM type    | When to use                                  |
|------------------|----------------------------------------------|
| `empty`          | The two faces of a 2D extruded mesh          |
| `wall`           | No-slip walls                                |
| `symmetryPlane`  | A symmetry boundary                          |
| `cyclic`         | Periodic boundary                            |
| `wedge`          | Axisymmetric (single-sector) geometry        |
| `patch`          | Generic — explicit pass-through              |

The matching is done by patch name, so the names in your `.geo` file must
match the names in your `0.orig/` boundary conditions.

* Default: blank (no fixes — assumes Gmsh-written types are correct)

### `foam_sigfpe`

Whether OpenFOAM should trap floating-point exceptions. With `true`, NaN or
overflow during solve immediately stops the run. With `false`, the solver
sometimes pushes through transient garbage and recovers. For AMR runs where
mesh quality varies between iterations, **`false` is safer**.

* Default: `false`

---

## Output and archiving

### `result_root`

Where the orchestrator stores per-iteration archives of solver output. The
default is `<base_dir>/comet_result/`, kept for backward compatibility with
the original COMET-only version of the pipeline.

* Default: `<base_dir>/comet_result`

### `pv_output_dir`

The pattern of result subdirectories the orchestrator looks for after each
solver run. Default is `field*` which matches `field`, `field_g0`, etc.
Change only if your solver wrapper writes results under a different name.

* Default: `field*`

### `log_dir`

Where pipeline logs go. Each iteration produces files like
`output_normal1.txt`, `output_amr1.txt`, `csv_2_pos_1.txt`, and
`<mesh>_normal_1.txt` / `<mesh>_amr_1.txt` for the Gmsh stages.

* Default: `<base_dir>/logs`

### `pvd_create`

Whether the orchestrator should auto-build a `.pvd` time-series file from
the VTU outputs in each result directory. This is what `final.py` reads.

* Default: `true`
* Set to `false` only if your solver already writes its own `.pvd`.

### `pvd_pattern`

The glob the PVD builder uses to find VTU files inside each `step_*/`
folder. Default `field*.vtu` matches the layout that `run_openfoam.sh`
produces.

* Default: `field*.vtu`

### `pvd_file`

If you set this to a specific path, the pipeline reads (or builds) a `.pvd`
at exactly that location instead of letting the orchestrator pick the
latest one. Useful for re-running just the extraction step on an old result.

* Default: blank (orchestrator chooses)

### `raw_csv`

The full point-data export from `pvpython`, before filtering. Contains every
field at every grid point, which is occasionally useful for debugging.

* Default: `gmsh/all_data.csv`

### `filtered_csv`

A compact `(x, y, z, sizing_value)` CSV — a much smaller intermediate file
that gets converted to the `.pos`. Also useful as a sanity check
(`head gmsh/filtered_mfp.csv` to eyeball the values).

* Default: `gmsh/filtered_mfp.csv`

### `pos_file`

The Gmsh `.pos` background view that `geo_file_amr` reads. Default name is
`mfp.pos` for historical reasons (the name comes from the original
mean-free-path-driven version).

* Default: `gmsh/mfp.pos`

---

## Distributed and partitioned runs (DSMC only)

The following keys are used only by the COMET wrapper, which uses PUMI-PIC
to partition the mesh for MPI runs. They are ignored by the OpenFOAM
wrapper.

### `partition_mesh`

`true` → run PUMI-PIC's `print_pumipic_partition` after Gmsh, before the
solver. Used for distributed COMET runs.

* Default: `false`

### `partition_parts`

How many partitions to create. Defaults to the number embedded in the
case-script filename (`run_centos_gmsh_nparts=4_groupsize=1.sh` → 4).

* Default: derived from `case_script` name

### `partition_script` / `partition_script_amr`

Names of the partition helper scripts on the coarse and AMR meshes
respectively.

* Default: `print_pumipic_partition.sh`, `print_pumipic_partition_amr.sh`

### `pumi_bin`

Directory containing PUMI-PIC's `from_gmsh` and `print_pumipic_partition`
binaries. Auto-detected from `case_script` if blank.

* Default: auto-detect

---

## Restarting from a previous result

### `refine_from`

A directory or archive (`.tar.gz`, `.zip`) of a previous result. If set, the
pipeline skips iteration-1 mesh-and-solver work and starts the AMR loop from
this seed. Useful when you have a pre-converged solution and just want to
adapt around it.

* Default: blank

---

## A worked example

The bundled `amr_pipeline.input` for the Mach 3 cylinder case:

```ini
&amr_input
  loops              = 3
  gmsh_bin           = /home/fahim/gmsh/gmsh-4.11.1-Linux64/bin/gmsh
  pvpython           = /home/fahim/paraview/.../bin/pvpython

  geo_file           = 2d_cylinder.geo
  geo_file_amr       = 2d_cylinder_amr.geo
  sim_mesh           = 2d_cylinder.msh
  sim_mesh_amr       = 2d_cylinder_amr.msh

  case_script        = run_openfoam.sh
  case_script_amr    = run_openfoam_amr.sh
  final_py           = final.py

  extraction_mode    = gradient
  gradient_field     = p
  sizing_min         = 0.002
  sizing_max         = 0.015
  sizing_scale       = 100.0
  mfp_column         = p_sizing
  pos_scale          = 1.0

  foam_source        = /home/fahim/OpenFOAM/OpenFOAM-v2406/etc/bashrc
  solver             = rhoCentralFoam
  case_dir           = openfoam_case
  boundary_fix       = frontAndBack:empty, wall:wall
  foam_sigfpe        = false

  partition_mesh     = false
  pv_output_dir      = field
  pvd_create         = true
  raw_csv            = gmsh/all_data.csv
  filtered_csv       = gmsh/filtered_mfp.csv
  pos_file           = gmsh/mfp.pos
/
```

This is the file that produced the results in
[TUTORIAL.md](TUTORIAL.md#6-expected-wall-time-and-output-size).
