# Adding support for a new solver

The pipeline is solver-agnostic by design. The orchestrator (`all_run.sh`),
the field extractor (`final.py`), and the Gmsh background-field mechanism do
not know or care which solver is producing the field data. All
solver-specific behavior lives in **a single wrapper script** that the
orchestrator invokes by name.

This document describes what that wrapper script has to do and walks through
how the OpenFOAM wrapper is built, so that you can use it as a template for
new solvers.

The pipeline currently ships with two wrappers:

* `run_openfoam.sh` (and `run_openfoam_amr.sh`) — for OpenFOAM v2406+
* `run_centos_gmsh_nparts=1_groupsize=1.sh` (and the AMR variant) — for our
  in-house COMET DSMC code

Adding a third — say, **SU2**, **Fluent**, or **DSMC OpenFOAM** — is a
matter of writing one new shell script.

---

## 1. The contract

The orchestrator will call your wrapper once per iteration. Your wrapper
must:

| # | Responsibility                                                  | How OpenFOAM wrapper handles it |
|---|------------------------------------------------------------------|---------------------------------|
| 1 | Read `sim_mesh` (or `sim_mesh_amr`) from `amr_pipeline.input`    | Inline `parse_conf` function    |
| 2 | Convert that mesh to whatever format the solver needs            | `gmshToFoam`                    |
| 3 | Apply any solver-specific boundary patch fixes                   | Inline Python regex             |
| 4 | Run the solver and capture its log                               | `$SOLVER > log.${SOLVER} 2>&1`  |
| 5 | Convert the solver's output to VTK/VTU                           | `foamToVTK`                     |
| 6 | Place the VTU files at `comet_result/field/step_*/field*.vtu`    | Loop renaming after `foamToVTK` |

That last step (#6) is the only contract item that is non-negotiable. The
orchestrator scans `comet_result/field/step_*/` for `.vtu` files and feeds
them to `final.py`. As long as your wrapper produces files at that path,
the rest of the pipeline does not care how it got them.

---

## 2. What the wrapper *does not* need to do

* It does not need to compute the AMR sizing field.
* It does not need to read or write `.pos` files.
* It does not need to know what `gradient_field` or `extraction_mode` is.
* It does not need to clean up `comet_result/` between runs (the orchestrator
  archives the previous result before invoking the wrapper).

All of that lives in the orchestrator and the field extractor.

---

## 3. The OpenFOAM wrapper, annotated

`run_openfoam.sh` is 119 lines, about 30 of which are config-parsing
boilerplate. The actual solver-specific work is the middle 50 lines.
Here is a summary, broken down by responsibility from the contract above.

### 3.1 Reading the input file

```bash
parse_conf() {
    local key="$1" file="$2" default="$3"
    local val
    val=$(grep -E "^\s*${key}\s*=" "$file" 2>/dev/null \
          | head -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*[!#].*//' | xargs)
    echo "${val:-$default}"
}

FOAM_SOURCE=$(parse_conf foam_source   "$INPUT_FILE" "")
SOLVER=$(parse_conf      solver        "$INPUT_FILE" "rhoCentralFoam")
CASE_DIR_REL=$(parse_conf case_dir     "$INPUT_FILE" "openfoam_case")
BOUNDARY_FIX=$(parse_conf boundary_fix "$INPUT_FILE" "")
MESH_NAME=$(parse_conf   sim_mesh      "$INPUT_FILE" "")
```

`parse_conf` is a portable bash function that reads `key = value` lines
from a namelist-style file, returning the value or a default. It tolerates
comments, optional whitespace, and `!` or `#` end-of-line comments. The
same function appears in `run_openfoam_amr.sh` (which differs only in
reading `sim_mesh_amr` instead of `sim_mesh`) and is the only piece of
boilerplate worth copying as-is.

### 3.2 Converting the mesh

```bash
gmshToFoam "$MESH_FILE" > log.gmshToFoam 2>&1
```

OpenFOAM ships with `gmshToFoam`. SU2 has `gmsh2su2`. DSMC OpenFOAM uses
the same `gmshToFoam` as OpenFOAM. Fluent has `tgrid` — but most users
already have a Fluent mesh in a different format anyway.

### 3.3 Fixing boundary types

This is the only step that is genuinely OpenFOAM-specific. After
`gmshToFoam` runs, all patches are tagged as type `patch`. OpenFOAM expects
specific types for some of them (`empty` for the front/back of a 2D mesh,
`wall` for solid walls, `symmetryPlane` for symmetry, etc.). The wrapper
applies the rules from the `boundary_fix` key in `amr_pipeline.input`:

```bash
python3 - "$CASE_DIR/constant/polyMesh/boundary" "$BOUNDARY_FIX" <<'PYEOF'
import sys, re
bfile = sys.argv[1]
rules_str = sys.argv[2] if len(sys.argv) > 2 else ""
with open(bfile) as f:
    txt = f.read()
for rule in rules_str.split(","):
    rule = rule.strip()
    if ":" not in rule:
        continue
    patch, btype = rule.split(":", 1)
    txt = re.sub(
        rf'({re.escape(patch.strip())}\s*\{{[^}}]*type\s+)\w+',
        rf'\1{btype.strip()}',
        txt
    )
with open(bfile, 'w') as f:
    f.write(txt)
PYEOF
```

For a different solver this whole block is either replaced (e.g. SU2 has
boundary tags built into the SU2 file format directly) or removed (DSMC
solvers usually consume the Gmsh file unchanged).

### 3.4 Running the solver

```bash
cp -r 0.orig 0
$SOLVER > log.${SOLVER} 2>&1
```

Two lines: copy the initial conditions, run the solver. For OpenFOAM the
solver name comes from `amr_pipeline.input`. For other solvers the
invocation may take more arguments, but the structure is the same.

### 3.5 Converting to VTU

```bash
foamToVTK > log.foamToVTK 2>&1
```

OpenFOAM writes VTK files in `case_dir/VTK/`, one subdirectory per write
step. Other solvers write VTK natively (SU2 with `OUTPUT_FILES = VTK`),
some write it via a separate post-processor (Fluent CFD-Post), some need a
custom converter (DSMC OpenFOAM).

### 3.6 Reorganizing into the pipeline's expected layout

```bash
RESULT_DIR="${SCRIPT_DIR}/comet_result/field"
rm -rf "$RESULT_DIR"; mkdir -p "$RESULT_DIR"
idx=0
for d in $(ls -d "$CASE_DIR"/VTK/*/ 2>/dev/null | sort -t_ -k3 -n); do
    [ -d "$d" ] || continue
    mkdir -p "$RESULT_DIR/step_${idx}_m1_g1"
    [ -f "$d/internal.vtu" ] && \
        cp "$d/internal.vtu" "$RESULT_DIR/step_${idx}_m1_g1/field_g0_m0.vtu"
    idx=$((idx + 1))
done
```

This is the contract step. The orchestrator expects:

```
comet_result/field/step_0_m1_g1/field_g0_m0.vtu
comet_result/field/step_1_m1_g1/field_g0_m0.vtu
...
```

The naming convention (`step_N_mM_gG/field_gG_mM.vtu`) is a holdover from
COMET, which uses MPI partitioning (`m`) and group (`g`) indices. For
OpenFOAM we always write `m1 g1` and a single `field_g0_m0.vtu` because
there is no partitioning. As long as your wrapper produces files at this
path with `.vtu` extensions, the pipeline finds them.

---

## 4. Adding a new solver: a worked recipe

Here is the procedure I would follow to add a new solver — let's say
**SU2**, the open-source compressible CFD code from Stanford.

### Step 1: Copy and rename

```bash
cp run_openfoam.sh     run_su2.sh
cp run_openfoam_amr.sh run_su2_amr.sh
```

### Step 2: Replace mesh conversion

In `run_su2.sh`, replace the `gmshToFoam` step with SU2's `gmsh2su2`:

```bash
gmsh2su2 -i "$MESH_FILE" -o "$CASE_DIR/mesh.su2"
```

(Or pre-write a `.geo` file that emits a `.su2` directly — Gmsh supports
both via `-format su2`.)

### Step 3: Replace the boundary-fix block

SU2 reads boundary conditions from a `config.cfg` file rather than from
the mesh, so this whole block can be deleted. SU2 will pick up boundaries
by name from the `MARKER_*` lines in your config.

### Step 4: Replace the solver call

```bash
SU2_CFD config.cfg > log.su2 2>&1
```

Or, for parallel:

```bash
mpirun -np 8 SU2_CFD config.cfg > log.su2 2>&1
```

### Step 5: Replace the VTK conversion

SU2 writes VTU files natively when `OUTPUT_FILES = VTK` is set in the
config. They land at `flow.vtu` (or `flow_<step>.vtu` for unsteady runs).
The "convert to VTU" step is therefore a no-op for SU2.

### Step 6: Reorganize into `comet_result/field/step_*/`

This step is unchanged from the OpenFOAM wrapper. SU2's VTU files just go
into `step_*_m1_g1/` directories with the standard names.

### Step 7: Update `amr_pipeline.input`

```ini
case_script        = run_su2.sh
case_script_amr    = run_su2_amr.sh
extraction_mode    = gradient
gradient_field     = Pressure
mfp_column         = Pressure_sizing
```

Note: SU2 names its pressure field `Pressure` (capital P) instead of
OpenFOAM's `p`. Keep this in mind when setting `gradient_field` and
`mfp_column`.

### Step 8: Run

```bash
./all_run.sh
```

The orchestrator and `final.py` do not change. Only the wrapper, the
`.geo` files (if you want to use SU2-specific markers), and the
`amr_pipeline.input` field names change.

---

## 5. Solvers that are easy / hard to wrap

| Solver           | Ease of wrapping | Why                                      |
|------------------|------------------|------------------------------------------|
| **OpenFOAM**     | done             | gmshToFoam + foamToVTK both ship with it |
| **COMET (DSMC)** | done             | Reads Gmsh natively, writes VTU natively |
| **SU2**          | easy             | Native Gmsh import + native VTK output   |
| **Fluent**       | medium           | Mesh format mismatch; requires tgrid     |
| **DSMC OpenFOAM**| easy             | Same gmshToFoam as OpenFOAM              |
| **Star-CCM+**    | hard             | Closed format, batch mode is awkward     |
| **CFX**          | hard             | Same as Star-CCM+                        |

The pipeline is biased towards open-source CFD/DSMC codes that read Gmsh
natively or accept it via a one-step converter. For commercial codes that
maintain proprietary mesh formats, you would need a meaningful amount of
glue work.

---

## 6. What if my solver does not write VTU?

Two options:

**Option A: post-process to VTU.** Most major solvers either ship a VTK
exporter or have a community tool that produces VTK. ParaView itself can
read many formats and re-save as VTU; you can script this with `pvpython`
in your wrapper.

**Option B: change `final.py`.** If you have a different output format
(say HDF5, or a custom binary), the cleanest path is to extend `final.py`
to read your format directly. The function `_export_direct` and
`_export_gradient` both go through ParaView, so as long as ParaView reads
your format, no other change is needed. If ParaView does not, you would
write a separate field-extraction script that reads your format and writes
the same `.pos` Gmsh expects, and point `final_py` in `amr_pipeline.input`
at it.

In practice, almost every CFD/DSMC code can be coaxed into producing VTU,
so option A is what we recommend.

---

## 7. Submitting your wrapper upstream

If you write a wrapper for a solver and it works, please open a pull
request. We would like the pipeline to ship with wrappers for as many
solvers as the community needs. Wrappers should:

* Be self-contained shell or Python scripts.
* Read all configuration from `amr_pipeline.input` (no hard-coded paths).
* Produce VTU files at `comet_result/field/step_*/`.
* Include a short comment block explaining what they do, what version of
  the solver they were tested with, and any known quirks.

A working wrapper plus a one-page entry in this doc is enough.
