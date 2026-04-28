# Tutorial: Reproducing the Mach 3 cylinder result

This tutorial walks through the bundled example case from a clean checkout to
the final adapted mesh and post-processed flow field. Every command is real;
every output file is one I have on disk after running it on my own machine.

If something on your system looks different from what I show, that is worth
flagging — please open an issue with the actual log. The pipeline is meant to
be reproducible and I want to know when it isn't.

The case is a **2D cylinder in a Mach-3 supersonic free stream at 50 km
altitude**. The geometry is a unit-by-0.8-meter rectangular domain with a
0.1 m radius cylinder placed at (0.5, 0.4). The free-stream conditions are
the U.S. Standard Atmosphere values at 50 km:

| Quantity        | Value     | Units    |
|-----------------|-----------|----------|
| Velocity (x)    | 990       | m/s      |
| Temperature     | 270.65    | K        |
| Pressure        | 79.78     | Pa       |
| Wall temperature| 800       | K (fixed)|
| Mach number     | ≈ 3.0     | —        |

The wall is heated to 800 K to mimic an Artemis-class reentry surface
temperature. We use **rhoCentralFoam** with **Kurganov central schemes** and
the **Minmod limiter**, which is the standard OpenFOAM combination for
supersonic compressible flow.

After three AMR loops on my machine, the bow shock and recirculation zone are
captured cleanly. The number of cells in the wake more than triples; the
front-stagnation region also gets several extra layers of refinement.

---

## 0. Pre-flight check

Before starting, make sure everything from [INSTALL.md](INSTALL.md) is in
place. Quick verification:

```bash
gmsh --version                             # 4.11.1
pvpython --version                         # 5.13.2
which rhoCentralFoam                       # path to OpenFOAM solver
which gmshToFoam                           # path to OpenFOAM utility
```

If any of those don't print sensibly, go back to the install page.

Then clone the repository and `cd` into it:

```bash
git clone https://github.com/Fahim-bd/AMR-Pipeline.git
cd AMR-Pipeline
ls
```

Expected listing:

```
README.md           amr_pipeline.input    final.py            run_openfoam_amr.sh
INSTALL.md          all_run.sh            gmsh/               run_openfoam.sh
TUTORIAL.md         build_pvd_from_steps.sh   logs/           openfoam_case/
CONFIG_REFERENCE.md  comet_result/         ...
```

---

## 1. Edit the one input file

Open `amr_pipeline.input` and update the three paths near the top to point at
your binaries:

```ini
&amr_input
  ! Pipeline settings
  loops              = 3
  gmsh_bin           = /home/YOUR_USER/gmsh/gmsh-4.11.1-Linux64/bin/gmsh
  pvpython           = /home/YOUR_USER/paraview/ParaView-5.13.2-MPI-Linux-Python3.10-x86_64/bin/pvpython

  ! Geometry & mesh
  geo_file           = 2d_cylinder.geo
  geo_file_amr       = 2d_cylinder_amr.geo
  sim_mesh           = 2d_cylinder.msh
  sim_mesh_amr       = 2d_cylinder_amr.msh

  ! Solver run scripts
  case_script        = run_openfoam.sh
  case_script_amr    = run_openfoam_amr.sh
  final_py           = final.py

  ! Extraction settings
  extraction_mode    = gradient
  gradient_field     = p
  sizing_min         = 0.002
  sizing_max         = 0.015
  sizing_scale       = 100.0
  mfp_column         = p_sizing
  pos_scale          = 1.0

  ! OpenFOAM solver settings
  foam_source        = /home/YOUR_USER/OpenFOAM/OpenFOAM-v2406/etc/bashrc
  solver             = rhoCentralFoam
  case_dir           = openfoam_case
  boundary_fix       = frontAndBack:empty, wall:wall
  foam_sigfpe        = false
/
```

Every key in this file is documented in
[CONFIG_REFERENCE.md](CONFIG_REFERENCE.md). For now, the only ones you need
to change are `gmsh_bin`, `pvpython`, and `foam_source`.

---

## 2. Look at the geometry

Before running anything, it is useful to open the `.geo` files and see what
the pipeline is actually meshing.

### 2.1 The coarse mesh: `gmsh/2d_cylinder.geo`

```gmsh
SetFactory("OpenCASCADE");
Rectangle(1) = {0, 0, 0, 1, 0.8};                  // domain: 1 m x 0.8 m
Disk(2)      = {0.5, 0.4, 0, 0.1};                 // cylinder: r = 0.1 m at (0.5, 0.4)
BooleanDifference(3) = { Surface{1}; Delete; }{ Surface{2}; Delete; };

out[] = Extrude {0, 0, 0.01} { Surface{3}; Layers{1}; Recombine; };

Physical Surface("inlet")        = {5};            // left wall (x = 0)
Physical Surface("outlet")       = {4, 6, 7};      // bottom, right, top
Physical Surface("wall")         = {8};            // cylinder
Physical Surface("frontAndBack") = {3, 9};         // front and back (z = 0, z = 0.01)
Physical Volume("internalMesh")  = {out[1]};

Mesh.CharacteristicLengthMin = 0.005;
Mesh.CharacteristicLengthMax = 0.02;
Mesh.MshFileVersion          = 2.2;                // OpenFOAM gmshToFoam needs v2.x
Mesh 3;
```

A few things worth noticing:

* The 2D rectangle is extruded one layer in z to make a 3D mesh. OpenFOAM is
  inherently 3D; for a "2D" run you give it one layer and tag the front and
  back faces as `empty`. That is what `frontAndBack` does in the boundary
  conditions later.
* `Mesh.MshFileVersion = 2.2` is mandatory. OpenFOAM's `gmshToFoam` does not
  read v4 mesh files reliably as of v2406. If you forget this line, you will
  get a confusing parse error from `gmshToFoam` and no mesh.
* The characteristic-length range (0.005–0.02 m) is what gives us the initial
  coarse mesh of roughly 5 000–8 000 cells in 2D.
* The four physical surfaces — `inlet`, `outlet`, `wall`, `frontAndBack` —
  match the patch names used in `openfoam_case/0.orig/p`, `U`, `T`. The
  pipeline rewrites their *types* automatically (see step 5 below); you only
  need to keep the *names* consistent.

### 2.2 The AMR mesh: `gmsh/2d_cylinder_amr.geo`

```gmsh
SetFactory("OpenCASCADE");
Rectangle(1) = {0, 0, 0, 1, 0.8};
Disk(2)      = {0.5, 0.4, 0, 0.1};
BooleanDifference(3) = { Surface{1}; Delete; }{ Surface{2}; Delete; };

Merge "mfp.pos";                              // <-- the AMR sizing field
Field[1] = PostView;
Field[1].ViewTag = 1;
Mesh.MeshSizeFromPoints      = 0;             // disable curvature-based sizing
Mesh.MeshSizeFromCurvature   = 0;
Mesh.MeshSizeExtendFromBoundary = 0;
Mesh.CharacteristicLengthMin = 0.002;
Mesh.CharacteristicLengthMax = 0.015;
Background Field = 1;                         // <-- drive sizing from the .pos
Mesh 2;

out[] = Extrude {0, 0, 0.01} { Surface{3}; Layers{1}; Recombine; };

Physical Surface("inlet")        = {5};
Physical Surface("outlet")       = {4, 6, 7};
Physical Surface("wall")         = {8};
Physical Surface("frontAndBack") = {3, 9};
Physical Volume("internalMesh")  = {out[1]};

Mesh.MshFileVersion = 2.2;
```

The AMR `.geo` is the same geometry, but with three extra lines that take Gmsh
out of "size from points and curvature" mode and into "size from background
view" mode. The background view is `mfp.pos`, which the pipeline writes after
each solver run. On the first run, `mfp.pos` does not yet exist — that's why
iteration 1 always uses the coarse `.geo`, not the AMR one.

### 2.3 Where the `.pos` file comes from

`final.py` produces `gmsh/mfp.pos`. The format Gmsh expects is:

```
View "MFP" {
  SP(0.123, 0.456, 0.005){0.0042};
  SP(0.124, 0.456, 0.005){0.0041};
  ...
};
```

Each `SP(x,y,z){h}` is a "scalar point": at coordinate `(x,y,z)` the requested
mesh size is `h`. Gmsh interpolates between these points using the
`Background Field`. For the cylinder case `final.py` writes about 7 000 SP
records — one per cell-center point in the previous solution.

---

## 3. Look at the OpenFOAM case

```bash
ls openfoam_case/
# 0.orig/  constant/  system/
```

### 3.1 Initial conditions: `openfoam_case/0.orig/`

The pipeline never edits this directory. The wrapper script (`run_openfoam.sh`)
copies it to `0/` before each run.

`p`:
```
internalField   uniform 79.78;
boundaryField {
    inlet         { type fixedValue; value uniform 79.78; }
    outlet        { type zeroGradient; }
    wall          { type zeroGradient; }
    frontAndBack  { type empty; }
}
```

`U`:
```
internalField   uniform (990 0 0);
boundaryField {
    inlet         { type fixedValue; value uniform (990 0 0); }
    outlet        { type zeroGradient; }
    wall          { type noSlip; }
    frontAndBack  { type empty; }
}
```

`T`:
```
internalField   uniform 270.65;
boundaryField {
    inlet         { type fixedValue; value uniform 270.65; }
    outlet        { type zeroGradient; }
    wall          { type fixedValue; value uniform 800; }
    frontAndBack  { type empty; }
}
```

### 3.2 System: `openfoam_case/system/`

`controlDict`:
```
application     rhoCentralFoam;
endTime         0.001;          # 1 ms physical time
deltaT          1e-08;
writeInterval   0.0002;         # → 6 written times per run
adjustTimeStep  yes;
maxCo           0.3;
maxDeltaT       1e-05;
```

`fvSchemes` uses Kurganov flux + Minmod reconstruction:
```
fluxScheme       Kurganov;
ddtSchemes       { default Euler; }
gradSchemes      { default Gauss linear; }
divSchemes       { default none; div(tauMC) Gauss linear; }
laplacianSchemes { default Gauss linear corrected; }
interpolationSchemes {
    default            linear;
    reconstruct(rho)   Minmod;
    reconstruct(U)     MinmodV;
    reconstruct(T)     Minmod;
}
snGradSchemes    { default corrected; }
```

`fvSolution` is the standard rhoCentralFoam recipe — diagonal solvers for the
density equations, smoothSolver/GaussSeidel for `U`, `h`, `e`. No tweaks.

### 3.3 Constant: `openfoam_case/constant/`

`thermophysicalProperties`:
```
thermoType {
    type            hePsiThermo;
    mixture         pureMixture;
    transport       sutherland;            # μ(T) = As·T^1.5/(T+Ts)
    thermo          hConst;
    equationOfState perfectGas;
    specie          specie;
    energy          sensibleInternalEnergy;
}
mixture {
    specie         { molWeight 28.9; }
    thermodynamics { Cp 1005; Hf 0; }
    transport      { As 1.458e-06; Ts 110.4; }   # Sutherland constants for air
}
```

`turbulenceProperties`:
```
simulationType  laminar;
```

The case is **inviscid-ish but not strictly inviscid** — Sutherland viscosity
is on, but no turbulence model. For a cylinder at this Reynolds number, that
combination produces a reasonable steady wake.

---

## 4. Run the pipeline

```bash
./all_run.sh
```

That's it. The pipeline auto-detects the binaries you set in
`amr_pipeline.input`, prints a configuration summary, then enters the loop.

What you should see in the first few seconds:

```
Using input file: /home/fahim/AMR-Pipeline/amr_pipeline.input
Auto-detected gmsh binary: /home/fahim/gmsh/gmsh-4.11.1-Linux64/bin/gmsh

Running pipeline with:
  Base dir            /home/fahim/AMR-Pipeline
  Gmsh binary         /home/fahim/gmsh/gmsh-4.11.1-Linux64/bin/gmsh
  Loops               3
  Geo                 /home/fahim/AMR-Pipeline/gmsh/2d_cylinder.geo
  Geo AMR             /home/fahim/AMR-Pipeline/gmsh/2d_cylinder_amr.geo
  ...

===============================================
 ITERATION 1 / 3
===============================================
Generating normal mesh with Gmsh...
```

If you instead see an `ERROR:` line in the first 10 seconds, that is a
config or path problem. The most common ones are listed in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#step-1-errors).

---

## 5. What happens, step by step

Each iteration of the loop runs roughly this sequence. The first iteration
also runs the "normal" (coarse) mesh; iterations 2 and 3 skip straight to AMR.

### Step A — Generate the mesh

```
Generating normal mesh with Gmsh...
Saving backup mesh → gmsh/2d_cylinder1.msh
Updating simulation mesh → gmsh/2d_cylinder.msh
```

Gmsh runs the `.geo` file and writes a `.msh` (v2.2) to disk. The orchestrator
saves a numbered backup (`2d_cylinder1.msh`, `2d_cylinder2.msh`, …) so you can
diff meshes later.

### Step B — Run the solver

```
Running MPI case for the normal mesh...
============================================
 OpenFOAM AMR Pipeline — Normal Mesh Run
 Mesh:   .../gmsh/2d_cylinder.msh
 Solver: rhoCentralFoam
============================================
[STEP 1] gmshToFoam...
[STEP 2] Fixing boundaries...
[OK] Boundaries fixed
[STEP 3] Setting up initial conditions...
[STEP 4] Running rhoCentralFoam...
[OK] Solver exit: 0
[STEP 5] foamToVTK...
[STEP 6] Organizing VTK output...
============================================
 Done! 6 timesteps -> .../comet_result/field
============================================
```

The wrapper does six things:

1. **`gmshToFoam`** — convert the .msh to OpenFOAM polyMesh format.
2. **Fix boundary types** — Gmsh writes all patches as `patch`, but OpenFOAM
   needs `empty` for the front/back face and `wall` for the cylinder. The
   inline Python regex script edits `constant/polyMesh/boundary` based on the
   `boundary_fix` rules in `amr_pipeline.input`. This is the only "magic"
   step in the whole wrapper.
3. **Copy `0.orig/` to `0/`** — fresh initial conditions for each run.
4. **Run the solver** — `rhoCentralFoam`, output to `log.rhoCentralFoam`.
5. **`foamToVTK`** — convert results to VTU files, one per write step.
6. **Reorganize the VTU files** into `comet_result/field/step_0_m1_g1/`,
   `step_1_m1_g1/`, … so the rest of the pipeline can find them in a
   solver-independent layout.

The solver run itself is the slow part. On 8 cores, the Mach 3 case takes
about **8–12 minutes per loop** for the coarse mesh and **15–25 minutes per
loop** for the AMR mesh.

### Step C — Build the PVD

The orchestrator runs `build_pvd_from_steps.sh`, which scans the
`step_*_m*_g*/field*.vtu` directory tree and writes a
[ParaView-readable `.pvd`](https://www.paraview.org/Wiki/ParaView/Data_formats)
that links them as a time series. This is what `final.py` reads.

### Step D — Extract the sizing field

```
Converting results to POS (source: .../auto_field.pvd)...
[INFO] Max p gradient magnitude: 184523.7
[INFO] Exported point data with p_sizing to CSV: gmsh/all_data.csv
[INFO] Wrote filtered CSV with coords and p_sizing: gmsh/filtered_mfp.csv
[INFO] Wrote 7218 points to POS file: gmsh/mfp.pos
```

`final.py` is invoked by the orchestrator with `pvpython`. In `gradient`
mode (which we use for OpenFOAM), it:

1. Reads the PVD, advances to the last timestep.
2. Computes `grad(p)` and its magnitude.
3. Finds `max_grad` over the domain.
4. Computes the sizing field
   `h = h_min + (h_max − h_min) / (1 + scale · |∇p| / max_grad)`
   so that the largest gradient gets `h ≈ h_min` and zero gradient gets
   `h ≈ h_max`.
5. Writes `gmsh/all_data.csv` (full export), `gmsh/filtered_mfp.csv`
   (just `x, y, z, p_sizing`), and `gmsh/mfp.pos` (Gmsh background view).

The exact formula and its motivation are in [METHODOLOGY.md](METHODOLOGY.md).

### Step E — Generate the AMR mesh

```
Generating adaptive mesh with Gmsh...
Saving backup amr mesh → gmsh/2d_cylinder_amr1.msh
Updating simulation AMR mesh → gmsh/2d_cylinder_amr.msh
```

Gmsh runs `2d_cylinder_amr.geo`, which `Merge`s the freshly written `mfp.pos`
and uses it as the `Background Field`. The output is a new `.msh` with cells
sized according to the previous gradient field.

### Step F — Run the solver on the AMR mesh

Same as Step B, but using `run_openfoam_amr.sh` and `2d_cylinder_amr.msh`.
Results are archived to `comet_result/output_amr1_result/`.

### Step G — Repeat

For loops 2 and 3, the orchestrator skips the normal-mesh run (which would
just produce identical coarse-mesh results) and goes straight from "extract
new sizing from previous AMR" → "regenerate AMR mesh" → "run solver" →
"archive".

---

## 6. Expected wall-time and output size

These are the numbers from one of my runs on a 32-core CentOS box (8 cores
actually used by `rhoCentralFoam` since it's serial here):

| Iteration | Mesh cells | Solver time | Total iter time |
|-----------|-----------:|------------:|----------------:|
| 1 (normal) | ~5 800     | 9 min       | 11 min          |
| 1 (AMR)    | ~14 200    | 19 min      | 22 min          |
| 2          | ~16 700    | 22 min      | 25 min          |
| 3          | ~17 300    | 22 min      | 25 min          |
| **Total**  |            |             | **~83 min**     |

Disk usage at the end is roughly 1.4 GB (mostly VTK files in
`comet_result/`). If that is a concern, you can run with fewer write steps by
increasing `writeInterval` in `system/controlDict`.

---

## 7. Looking at the result

After the last iteration finishes:

```bash
ls comet_result/
# field/
# output_amr1_result/  output_amr2_result/  output_amr3_result/
# output_normal1_result/

ls gmsh/
# 2d_cylinder.geo  2d_cylinder1.msh  2d_cylinder.msh
# 2d_cylinder_amr.geo  2d_cylinder_amr1.msh  2d_cylinder_amr2.msh
# 2d_cylinder_amr3.msh  2d_cylinder_amr.msh
# all_data.csv  filtered_mfp.csv  mfp.pos
```

To open the final adapted result in ParaView:

```bash
paraview comet_result/output_amr3_result/field/auto_field.pvd
```

Apply, click "Last frame", and color by `p` or `U` magnitude. The bow shock
should be a sharp curved feature ahead of the cylinder; the wake should
extend roughly 0.3–0.4 m downstream with two counter-rotating vortices.

To compare meshes side by side:

```bash
paraview \
  comet_result/output_normal1_result/field/auto_field.pvd \
  comet_result/output_amr3_result/field/auto_field.pvd
```

In ParaView use "Surface with Edges" representation to see the cells. The
difference between the two is the whole point of the pipeline.

---

## 8. Modifying the case

A few common things you might want to change.

**Use a different free-stream Mach number.**
Edit `openfoam_case/0.orig/U` (`uniform (V 0 0)` where `V = M·sqrt(γRT)` for
your altitude) and re-run. Mach 3.0 is the upper stable limit on the
unstructured Gmsh mesh I tested. Mach 3.5+ blows up due to negative
internal-energy errors in cells with bad aspect ratio after AMR. (The
in-progress structured-mesh path may eventually fix this; see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#mach-35-crashes).)

**Use a different scalar field for AMR.**
Change `gradient_field = p` to `gradient_field = rho` or `gradient_field = T`
in `amr_pipeline.input`, and update `mfp_column` to match
(`rho_sizing`, `T_sizing`). Density gradient gives sharper wakes; pressure
gradient gives sharper shocks. For Mach 3 I prefer `p`.

**Change the geometry.**
Replace `2d_cylinder.geo` and `2d_cylinder_amr.geo` with your own. The only
hard requirements are:

* The two `.geo` files must produce meshes with the same physical-surface
  names.
* `Mesh.MshFileVersion = 2.2`.
* The AMR `.geo` must end with `Background Field = 1` and `Merge "mfp.pos"`.

**Change the number of loops.**
`loops = 5` in `amr_pipeline.input`. Diminishing returns kick in around 4–5
for most problems; I have not seen meaningful additional refinement past 5.

---

## 9. What to check if something goes sideways

* **The solver exits with a floating-point error.** Open
  `openfoam_case/log.rhoCentralFoam` and look at the last 50 lines. The most
  common cause is a bad cell in the AMR mesh. Bump `sizing_min` up by 25%
  and try again.
* **`pvpython` reports zero data points.** The PVD pointed to an empty
  result tree. Check `logs/output_amr*.txt` to see whether the solver ever
  wrote a result file.
* **Mesh refinement is happening in the wrong place.** Re-check
  `gradient_field` and `mfp_column`. They must agree (e.g. `p` and
  `p_sizing`). If they don't, `final.py` will export the wrong column to the
  POS file and Gmsh will refine wherever the placeholder values are largest.

The full troubleshooting catalog is in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).
