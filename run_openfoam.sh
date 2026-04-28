#!/bin/bash
# ---------------------------------------------------------------
# OpenFOAM run script for AMR pipeline — NORMAL mesh
# Reads ALL config from amr_pipeline.input — no editing needed.
# ---------------------------------------------------------------
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_FILE="${SCRIPT_DIR}/amr_pipeline.input"

# --- Parse key=value from amr_pipeline.input ---
parse_conf() {
    local key="$1" file="$2" default="$3"
    local val
    val=$(grep -E "^\s*${key}\s*=" "$file" 2>/dev/null | head -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*[!#].*//' | xargs)
    echo "${val:-$default}"
}

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: amr_pipeline.input not found at $INPUT_FILE" >&2; exit 1
fi

# Read all config from the ONE input file
FOAM_SOURCE=$(parse_conf foam_source "$INPUT_FILE" "")
SOLVER=$(parse_conf solver "$INPUT_FILE" "rhoCentralFoam")
CASE_DIR_REL=$(parse_conf case_dir "$INPUT_FILE" "openfoam_case")
BOUNDARY_FIX=$(parse_conf boundary_fix "$INPUT_FILE" "")
FOAM_SIGFPE_VAL=$(parse_conf foam_sigfpe "$INPUT_FILE" "false")
MESH_NAME=$(parse_conf sim_mesh "$INPUT_FILE" "")

CASE_DIR="${SCRIPT_DIR}/${CASE_DIR_REL}"

if [ -z "$MESH_NAME" ]; then
    echo "ERROR: sim_mesh not set in $INPUT_FILE" >&2; exit 1
fi
if [ -f "${SCRIPT_DIR}/${MESH_NAME}" ]; then
    MESH_FILE="${SCRIPT_DIR}/${MESH_NAME}"
else
    MESH_FILE="${SCRIPT_DIR}/gmsh/${MESH_NAME}"
fi

# --- Source OpenFOAM environment ---
export PATH="/usr/lib64/openmpi/bin:$PATH"
export LD_LIBRARY_PATH="/usr/lib64/openmpi/lib:${LD_LIBRARY_PATH:-}"
if [ -n "$FOAM_SOURCE" ]; then
    source "$FOAM_SOURCE" 2>/dev/null || true
fi
[ "$FOAM_SIGFPE_VAL" = "true" ] || [ "$FOAM_SIGFPE_VAL" = "false" ] && export FOAM_SIGFPE="$FOAM_SIGFPE_VAL"

echo "============================================="
echo " OpenFOAM AMR Pipeline — Normal Mesh Run"
echo " Mesh:   ${MESH_FILE}"
echo " Solver: ${SOLVER}"
echo "============================================="

cd "$CASE_DIR"

# 1. Clean previous run
rm -rf processor* constant/polyMesh VTK log.* postProcessing
ls -d [0-9]* 2>/dev/null | grep -v "0.orig" | xargs rm -rf 2>/dev/null || true

# 2. Convert gmsh mesh to OpenFOAM format
echo "[STEP 1] gmshToFoam..."
gmshToFoam "$MESH_FILE" > log.gmshToFoam 2>&1

# 3. Fix boundary types (data-driven from amr_pipeline.input boundary_fix)
echo "[STEP 2] Fixing boundaries..."
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
    patch = patch.strip()
    btype = btype.strip()
    txt = re.sub(
        rf'({re.escape(patch)}\s*\{{[^}}]*type\s+)\w+',
        rf'\1{btype}',
        txt
    )
txt = re.sub(r'\s*defaultFaces\s*\{[^}]*\}', '', txt)
with open(bfile, 'w') as f:
    f.write(txt)
print("[OK] Boundaries fixed")
PYEOF

# 4. Copy initial conditions
echo "[STEP 3] Setting up initial conditions..."
cp -r 0.orig 0

# 5. Run solver
echo "[STEP 4] Running ${SOLVER}..."
$SOLVER > log.${SOLVER} 2>&1
echo "[OK] Solver exit: $?"

# 6. Convert results to VTK
echo "[STEP 5] foamToVTK..."
foamToVTK > log.foamToVTK 2>&1

# 7. Organize into field/step_*/field*.vtu structure for the AMR pipeline
echo "[STEP 6] Organizing VTK output..."
RESULT_DIR="${SCRIPT_DIR}/comet_result/field"
rm -rf "$RESULT_DIR"; mkdir -p "$RESULT_DIR"
idx=0
for d in $(ls -d "$CASE_DIR"/VTK/*/ 2>/dev/null | sort -t_ -k3 -n); do
    [ -d "$d" ] || continue
    mkdir -p "$RESULT_DIR/step_${idx}_m1_g1"
    [ -f "$d/internal.vtu" ] && cp "$d/internal.vtu" "$RESULT_DIR/step_${idx}_m1_g1/field_g0_m0.vtu"
    idx=$((idx + 1))
done

echo "============================================="
echo " Done! $idx timesteps -> $RESULT_DIR"
echo "============================================="
