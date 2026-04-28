#!/bin/bash
# --------------------------------------------------------------------------------
# Coded by Fahim Shahriyar under the supervision of Dr. Chonglin Zhang
#
# Adaptive AMR pipeline with:
#   - configurable loops and file names via CLI or simple input file
#   - optional refinement from existing results (directory or archive)
#   - archival per iteration (normal + AMR) and support for partitioned result folders
#   - final AMR meshes always run to produce accompanying results
# --------------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'USAGE'
Usage: ./all_run.sh [options]

Options:
  --input FILE              Namelist-style input (default: amr_pipeline.input next to script if present)
  --base DIR                Base directory (auto-detect if omitted)
  --loops N                 Number of AMR loops (default: 3)
  --gmsh FILE               Path to gmsh binary
  --geo FILE                GEO for normal mesh (default: 2d_axisym.geo)
  --geo-amr FILE            GEO for AMR mesh (default: 2d_axisym_amr.geo)
  --sim-mesh FILE           Normal mesh used by solver (default: 2d_axisym.msh)
  --sim-mesh-amr FILE       AMR mesh used by solver (default: 2d_axisym_amr.msh)
  --case FILE               Case script for normal mesh (default: run_centos_gmsh_nparts=1_groupsize=1.sh)
  --case-amr FILE           Case script for AMR mesh (default: run_centos_gmsh_nparts=1_groupsize=1_amr.sh)
  --final FILE              pvpython converter script (default: final.py)
  --pvpython FILE           pvpython executable (default: pvpython in PATH)
  --result-root DIR         Root results dir (default: BASE_DIR/comet_result)
  --pv-output SPEC          Path or glob to ParaView output folders; if relative, resolved under result-root (default: field*)
  --logs DIR                Log directory (default: BASE_DIR/logs)
  --refine-from PATH        Existing results (dir or .tar(.gz)/.zip) to start refinement
  --raw-csv FILE            CSV path for full export (default: gmsh/all_data.csv)
  --filtered-csv FILE       CSV path for filtered data (default: gmsh/filtered_mfp.csv)
  --pos FILE                POS file path for Gmsh AMR (default: gmsh/mfp.pos)
  --mfp-column NAME         Column name to use from CSV (default: "mean free path")
  --pos-scale FLOAT         Multiplier applied to POS values (default: 1.0)
  --pvd-file FILE           Explicit PVD file to use (optional)
  --pvd-create BOOL         true/false: build PVD from step_* if missing (default: true)
  --pvd-pattern GLOB        VTU glob to use when building PVD (default: field*.vtu)
  --partition-mesh BOOL     true/false: generate partitions via print_pumipic_partition*.sh (default: false)
  --partition-parts N       Partition count (default: parsed from case script name or 1)
  --partition-script FILE   Partition script for normal mesh (default: print_pumipic_partition.sh)
  --partition-script-amr FILE Partition script for AMR mesh (default: print_pumipic_partition_amr.sh)
  --extraction-mode MODE    Extraction mode: 'direct' or 'gradient' (default: direct)
  --gradient-field NAME     Scalar field for gradient (e.g., rho, p). Required if mode=gradient
  --sizing-min FLOAT        Min cell size in sizing formula (default: 0.001)
  --sizing-max FLOAT        Max cell size in sizing formula (default: 0.015)
  --sizing-scale FLOAT      Scaling factor in sizing formula (default: 100.0)
  -h, --help                Show help

Env overrides:
  BASE_DIR, LOOPS, GMSH_BIN, GEO_FILE, GEO_FILE_AMR, SIM_MESH, SIM_MESH_AMR,
  CASE_SCRIPT, CASE_SCRIPT_AMR, FINAL_PY, RESULT_ROOT, PV_OUTPUT_DIR, LOG_DIR,
  PVPYTHON, REFINE_FROM, RAW_CSV, FILTERED_CSV, POS_FILE, MFP_COLUMN, POS_SCALE, PVD_FILE, PVD_CREATE, PVD_PATTERN,
  PARTITION_MESH, PARTITION_PARTS, PARTITION_SCRIPT, PARTITION_SCRIPT_AMR,
  EXTRACTION_MODE, GRADIENT_FIELD, SIZING_MIN, SIZING_MAX, SIZING_SCALE

Notes:
  - ParaView output spec supports partitioned results (e.g., field_proc*).
  - If --refine-from is supplied, iteration 1 skips the normal run and refines from the provided results.
USAGE
}

stat_mtime() {
  local path="$1"
  stat -c %Y "$path" 2>/dev/null || stat -f %m "$path"
}

abs_path() {
  local path="$1" base="${2:-}"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  else
    local root="${base:-$PWD}"
    printf '%s\n' "$(cd "$root" && cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  fi
}

detect_gmsh_binary() {
  local candidate
  if command -v gmsh >/dev/null 2>&1; then
    candidate="$(command -v gmsh)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  fi

  local -a search_dirs=()
  [[ -n "${BASE_DIR:-}" ]] && search_dirs+=("${BASE_DIR}" "${BASE_DIR}/.." "${BASE_DIR}/gmsh" "${BASE_DIR}/../gmsh")
  [[ -n "${SCRIPT_DIR:-}" ]] && search_dirs+=("${SCRIPT_DIR}" "${SCRIPT_DIR}/..")
  [[ -n "${PWD:-}" ]] && search_dirs+=("$PWD")
  [[ -n "${HOME:-}" ]] && search_dirs+=("${HOME}" "${HOME}/gmsh")

  local dir dir_abs direct found
  for dir in "${search_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    if ! dir_abs="$(cd "$dir" 2>/dev/null && pwd)"; then
      continue
    fi
    [[ -d "$dir_abs" ]] || continue

    for direct in "$dir_abs/gmsh" "$dir_abs/bin/gmsh"; do
      if [[ -x "$direct" ]]; then
        echo "$direct"
        return 0
      fi
    done

    found="$(find "$dir_abs" -maxdepth 4 -type f -name gmsh -perm -111 -print -quit 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
  done

  return 1
}

expand_result_sources() {
  local spec="$1"
  local -a matches=()
  local glob pattern

  for pattern in $spec; do
    if [[ "$pattern" == *"*"* || "$pattern" == *"?"* || "$pattern" == *"["* ]]; then
      if [[ "$pattern" = /* ]]; then
        glob="$pattern"
      else
        glob="${RESULT_ROOT}/${pattern}"
      fi
      while IFS= read -r p; do
        matches+=("$p")
      done < <(compgen -G "$glob" || true)
    else
      if [[ "$pattern" = /* ]]; then
        matches+=("$pattern")
      else
        matches+=("${RESULT_ROOT}/${pattern}")
      fi
    fi
  done

  printf '%s\n' "${matches[@]}"
}

select_latest_path() {
  local latest="" latest_m=0 candidate m
  for candidate in "$@"; do
    [[ -e "$candidate" ]] || continue
    m="$(stat_mtime "$candidate" 2>/dev/null || echo 0)"
    if [[ -z "$latest" || "$m" -gt "$latest_m" ]]; then
      latest="$candidate"
      latest_m="$m"
    fi
  done
  printf '%s\n' "$latest"
}

find_latest_pvd() {
  local -a roots=("$@") pvds=()
  local root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r f; do
      pvds+=("$f")
    done < <(find "$root" -maxdepth 3 -type f -name '*.pvd' -print 2>/dev/null || true)
  done
  select_latest_path "${pvds[@]}"
}

clear_live_results() {
  local spec="$1"
  mapfile -t paths < <(expand_result_sources "$spec")
  local p
  for p in "${paths[@]}"; do
    [[ -e "$p" ]] || continue
    rm -rf "$p"
  done
}

archive_results() {
  local dest="$1" spec="$2"
  mapfile -t sources < <(expand_result_sources "$spec")
  rm -rf "$dest"
  mkdir -p "$dest"

  local copied=0 src
  for src in "${sources[@]}"; do
    [[ -e "$src" ]] || continue
    cp -a "$src" "$dest/$(basename "$src")"
    copied=1
  done

  if [[ "$copied" -eq 0 ]]; then
    echo "WARNING: No results found to archive for spec '$spec'" >&2
  fi
}

convert_results_to_pos() {
  local label="$1"
  mapfile -t result_roots < <(expand_result_sources "$RESULT_SPEC")

  local pvd=""

  # If a PVD path is specified, prefer it
  if [[ -n "$PVD_FILE" ]]; then
    pvd="$(abs_path "$PVD_FILE" "$RESULT_ROOT")"
    if [[ ! -f "$pvd" ]]; then
      if [[ "$PVD_CREATE" == "true" && -x "$BUILD_PVD_HELPER" ]]; then
        local build_dir
        build_dir="$(cd "$(dirname "$pvd")" 2>/dev/null && pwd || true)"
        if [[ -z "$build_dir" || ! -d "$build_dir" ]]; then
          build_dir="${result_roots[0]:-}"
        fi
        if [[ -z "$build_dir" || ! -d "$build_dir" ]]; then
          echo "ERROR: Cannot build PVD: no valid build dir found for $pvd" >&2
          exit 1
        fi
        "$BUILD_PVD_HELPER" --field-dir "$build_dir" --output "$pvd" --pattern "${PVD_PATTERN}" || true
      else
        echo "ERROR: PVD file specified but not found: $pvd" >&2
        exit 1
      fi
    fi
  fi

  # If no PVD yet, try auto-build from result roots
  if [[ -z "$pvd" ]]; then
    if [[ "$PVD_CREATE" == "true" && -x "$BUILD_PVD_HELPER" ]]; then
      local rr
      for rr in "${result_roots[@]}"; do
        [[ -d "$rr" ]] || continue
        "$BUILD_PVD_HELPER" --field-dir "$rr" --output "$rr/auto_field.pvd" --pattern "${PVD_PATTERN}" || true
      done
    fi
    pvd="$(find_latest_pvd "${result_roots[@]}")"
  fi

  if [[ -z "$pvd" ]]; then
    echo "ERROR: No .pvd found under ${RESULT_ROOT}/${RESULT_SPEC}. Cannot generate POS." >&2
    exit 1
  fi

  echo "Converting results to POS (source: $pvd)..."
  local -a final_args=(
    --pvd "$pvd"
    --raw-csv "$RAW_CSV_PATH"
    --filtered-csv "$FILTERED_CSV_PATH"
    --pos "$POS_PATH"
    --multiply-factor "$POS_SCALE"
    --mfp-column "$MFP_COLUMN"
    --extraction-mode "$EXTRACTION_MODE"
    --sizing-min "$SIZING_MIN"
    --sizing-max "$SIZING_MAX"
    --sizing-scale "$SIZING_SCALE"
    --results-root "$RESULT_ROOT"
    --field-pattern "$RESULT_SPEC"
  )
  [[ -n "$GRADIENT_FIELD" ]] && final_args+=(--gradient-field "$GRADIENT_FIELD")
  (cd "$BASE_DIR" && "$PVPYTHON" "$FINAL_PY_PATH" "${final_args[@]}") \
    2>&1 | tee "${LOG_DIR}/csv_2_pos_${label}.txt"
}

build_pvd_for_dir() {
  local dir="$1" target="$2"
  [[ "$PVD_CREATE" == "true" ]] || return 0
  [[ -x "$BUILD_PVD_HELPER" ]] || return 0
  [[ -d "$dir" ]] || return 0
  "$BUILD_PVD_HELPER" --field-dir "$dir" --output "$target" --pattern "${PVD_PATTERN}" || true
}

derive_parts() {
  local parts="$1" script_name="$2"
  if [[ -n "$parts" ]]; then
    echo "$parts"; return
  fi
  if [[ "$script_name" =~ nparts=([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"; return
  fi
  echo "1"
}

rewrite_partition_script() {
  echo ""  # no-op placeholder (function unused after simplification)
}

run_partition() {
  local mesh_path="$1" script_name="$2" parts="$3"
  [[ "$PARTITION_MESH" == "true" ]] || return 0
  [[ -f "$mesh_path" ]] || { echo "ERROR: mesh file not found: $mesh_path" >&2; exit 1; }
  local mesh_base
  mesh_base="$(basename "$mesh_path")"
  mesh_base="${mesh_base%.*}"
  local dmg="${mesh_base}.dmg"
  local smb="${mesh_base}-serial.smb"
  local ptn="${mesh_base}_${parts}.ptn"
  local ptn_path="${GMESH_DIR}/${ptn}"

  local pumi_bin="${PUMI_BIN:-}"
  if [[ -z "$pumi_bin" ]]; then
    local script_path="${GMESH_DIR}/${script_name}"
    if [[ -f "$script_path" ]]; then
      pumi_bin="$(grep -Eo '.*/(?=from_gmsh|print_pumipic_partition)' "$script_path" | head -n1 || true)"
      pumi_bin="${pumi_bin%/}"
    fi
  fi

  if [[ -z "$pumi_bin" || ! -x "${pumi_bin}/from_gmsh" || ! -x "${pumi_bin}/print_pumipic_partition" ]]; then
    for root in "$HOME/dsmc" "$HOME" "/hdd1/dsmc" "/home"; do
      [[ -d "$root" ]] || continue
      found_from=$(find "$root" -type f -name from_gmsh -perm -u+x -print -quit 2>/dev/null || true)
      if [[ -n "${found_from:-}" ]]; then
        candidate_dir=$(dirname "$found_from")
        if [[ -x "$candidate_dir/print_pumipic_partition" ]]; then
          pumi_bin="$candidate_dir"
          break
        fi
      fi
    done
  fi

  local from_gmsh="${pumi_bin}/from_gmsh"
  local print_ptn="${pumi_bin}/print_pumipic_partition"
  if [[ ! -x "$from_gmsh" || ! -x "$print_ptn" ]]; then
    echo "ERROR: from_gmsh or print_pumipic_partition not found; set PUMI_BIN env to their directory." >&2
    exit 1
  fi

  (cd "$GMESH_DIR" && "$from_gmsh" none "$mesh_path" "$smb" "$dmg")
  (cd "$GMESH_DIR" && "$print_ptn" "$dmg" "$smb" "$parts" "$mesh_base")

  if [[ -f "${ptn_path}" ]]; then
    cp -f "${ptn_path}" "$BASE_DIR/"
    echo "Copied partition file to base dir: $ptn"
  else
    echo "WARNING: partition file not found after run: ${GMESH_DIR}/${ptn}" >&2
  fi
}

run_gmsh() {
  local geo="$1" out="$2" log_file="$3"
  (cd "$GMESH_DIR" && "$GMSH_BIN" "$geo" -3 -o "$out" 2>&1 | tee "$log_file")
}

load_input_file() {
  local file="$1"
  declare -gA INPUT_CFG=()
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%!*}"
    line="${line%%#*}"
    line="${line#${line%%[![:space:]]*}}"
    line="${line%${line##*[![:space:]]}}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \&* ]] && continue
    [[ "$line" == "/" ]] && continue
    [[ "$line" == \;* ]] && continue
    [[ "$line" != *"="* ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key#${key%%[![:space:]]*}}"
    key="${key%${key##*[![:space:]]}}"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    if [[ ${#value} -ge 2 ]]; then
      local first="${value:0:1}" last="${value: -1}"
      if { [[ "$first" == '"' && "$last" == '"' ]] || [[ "$first" == "'" && "$last" == "'" ]]; }; then
        value="${value:1:-1}"
      fi
    fi
    key="$(echo "$key" | tr '[:upper:]' '[:lower:]')"
    INPUT_CFG["$key"]="$value"
  done < "$file"
}

apply_input_value() {
  local key="$1" current="$2" default="$3"
  if [[ -n "${INPUT_CFG[$key]:-}" ]]; then
    printf '%s' "${INPUT_CFG[$key]}"
  elif [[ -n "$current" ]]; then
    printf '%s' "$current"
  else
    printf '%s' "$default"
  fi
}

# ---------------------------
# Defaults (env overrides)
# ---------------------------
BASE_DIR="${BASE_DIR:-}"
LOOPS="${LOOPS:-3}"
GMSH_BIN="${GMSH_BIN:-}"
PUMI_BIN="${PUMI_BIN:-}"
START_AMR_MESH="${START_AMR_MESH:-}"
GEO_FILE="${GEO_FILE:-2d_axisym.geo}"
GEO_FILE_AMR="${GEO_FILE_AMR:-2d_axisym_amr.geo}"
SIM_MESH="${SIM_MESH:-2d_axisym.msh}"
SIM_MESH_AMR="${SIM_MESH_AMR:-2d_axisym_amr.msh}"
CASE_SCRIPT="${CASE_SCRIPT:-run_centos_gmsh_nparts=1_groupsize=1.sh}"
CASE_SCRIPT_AMR="${CASE_SCRIPT_AMR:-run_centos_gmsh_nparts=1_groupsize=1_amr.sh}"
FINAL_PY="${FINAL_PY:-final.py}"
RESULT_ROOT="${RESULT_ROOT:-}"
PV_OUTPUT_DIR="${PV_OUTPUT_DIR:-}"
LOG_DIR="${LOG_DIR:-}"
PVPYTHON="${PVPYTHON:-pvpython}"
REFINE_FROM="${REFINE_FROM:-}"
RAW_CSV="${RAW_CSV:-gmsh/all_data.csv}"
FILTERED_CSV="${FILTERED_CSV:-gmsh/filtered_mfp.csv}"
POS_FILE="${POS_FILE:-gmsh/mfp.pos}"
MFP_COLUMN="${MFP_COLUMN:-mean free path}"
POS_SCALE="${POS_SCALE:-1.0}"
PVD_FILE="${PVD_FILE:-}"
PVD_CREATE="${PVD_CREATE:-true}"
PVD_PATTERN="${PVD_PATTERN:-field*.vtu}"
PARTITION_MESH="${PARTITION_MESH:-false}"
PARTITION_PARTS="${PARTITION_PARTS:-}"
PARTITION_SCRIPT="${PARTITION_SCRIPT:-print_pumipic_partition.sh}"
PARTITION_SCRIPT_AMR="${PARTITION_SCRIPT_AMR:-print_pumipic_partition_amr.sh}"
EXTRACTION_MODE="${EXTRACTION_MODE:-direct}"
GRADIENT_FIELD="${GRADIENT_FIELD:-}"
SIZING_MIN="${SIZING_MIN:-0.001}"
SIZING_MAX="${SIZING_MAX:-0.015}"
SIZING_SCALE="${SIZING_SCALE:-100.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_PVD_HELPER="${SCRIPT_DIR}/build_pvd_from_steps.sh"
INPUT_FILE=""
ARGS=("$@")

# First pass: pick up --input and --help
idx=0
while [[ $idx -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$idx]}" in
    --input|-i)
      INPUT_FILE="${ARGS[$((idx+1))]:-}"
      idx=$((idx+2))
      ;;
    -h|--help)
      usage; exit 0;;
    *) idx=$((idx+1));;
  esac
done

DEFAULT_INPUT_FILE="${SCRIPT_DIR}/amr_pipeline.input"
if [[ -z "$INPUT_FILE" && -f "$DEFAULT_INPUT_FILE" ]]; then
  INPUT_FILE="$DEFAULT_INPUT_FILE"
fi

# Load input file if provided
if [[ -n "$INPUT_FILE" ]]; then
  [[ -f "$INPUT_FILE" ]] || { echo "ERROR: Input file not found: $INPUT_FILE" >&2; exit 1; }
  echo "Using input file: $INPUT_FILE"
  load_input_file "$INPUT_FILE"
  BASE_DIR="$(apply_input_value base_dir "$BASE_DIR" "")"
  LOOPS="$(apply_input_value loops "$LOOPS" "3")"
  GMSH_BIN="$(apply_input_value gmsh_bin "$GMSH_BIN" "")"
  PUMI_BIN="$(apply_input_value pumi_bin "$PUMI_BIN" "")"
  START_AMR_MESH="$(apply_input_value start_amr_mesh "$START_AMR_MESH" "")"
  GEO_FILE="$(apply_input_value geo_file "$GEO_FILE" "2d_axisym.geo")"
  GEO_FILE_AMR="$(apply_input_value geo_file_amr "$GEO_FILE_AMR" "2d_axisym_amr.geo")"
  SIM_MESH="$(apply_input_value sim_mesh "$SIM_MESH" "2d_axisym.msh")"
  SIM_MESH_AMR="$(apply_input_value sim_mesh_amr "$SIM_MESH_AMR" "2d_axisym_amr.msh")"
  CASE_SCRIPT="$(apply_input_value case_script "$CASE_SCRIPT" "run_centos_gmsh_nparts=1_groupsize=1.sh")"
  CASE_SCRIPT_AMR="$(apply_input_value case_script_amr "$CASE_SCRIPT_AMR" "run_centos_gmsh_nparts=1_groupsize=1_amr.sh")"
  FINAL_PY="$(apply_input_value final_py "$FINAL_PY" "final.py")"
  PVPYTHON="$(apply_input_value pvpython "$PVPYTHON" "pvpython")"
  RESULT_ROOT="$(apply_input_value result_root "$RESULT_ROOT" "")"
  PV_OUTPUT_DIR="$(apply_input_value pv_output_dir "$PV_OUTPUT_DIR" "")"
  LOG_DIR="$(apply_input_value log_dir "$LOG_DIR" "")"
  REFINE_FROM="$(apply_input_value refine_from "$REFINE_FROM" "")"
  RAW_CSV="$(apply_input_value raw_csv "$RAW_CSV" "gmsh/all_data.csv")"
  FILTERED_CSV="$(apply_input_value filtered_csv "$FILTERED_CSV" "gmsh/filtered_mfp.csv")"
  POS_FILE="$(apply_input_value pos_file "$POS_FILE" "gmsh/mfp.pos")"
  MFP_COLUMN="$(apply_input_value mfp_column "$MFP_COLUMN" "mean free path")"
  POS_SCALE="$(apply_input_value pos_scale "$POS_SCALE" "1.0")"
  PVD_FILE="$(apply_input_value pvd_file "$PVD_FILE" "")"
  PVD_CREATE="$(apply_input_value pvd_create "$PVD_CREATE" "true")"
  PVD_PATTERN="$(apply_input_value pvd_pattern "$PVD_PATTERN" "field*.vtu")"
  PARTITION_MESH="$(apply_input_value partition_mesh "$PARTITION_MESH" "false")"
  PARTITION_PARTS="$(apply_input_value partition_parts "$PARTITION_PARTS" "")"
  PARTITION_SCRIPT="$(apply_input_value partition_script "$PARTITION_SCRIPT" "print_pumipic_partition.sh")"
  PARTITION_SCRIPT_AMR="$(apply_input_value partition_script_amr "$PARTITION_SCRIPT_AMR" "print_pumipic_partition_amr.sh")"
  EXTRACTION_MODE="$(apply_input_value extraction_mode "$EXTRACTION_MODE" "direct")"
  GRADIENT_FIELD="$(apply_input_value gradient_field "$GRADIENT_FIELD" "")"
  SIZING_MIN="$(apply_input_value sizing_min "$SIZING_MIN" "0.001")"
  SIZING_MAX="$(apply_input_value sizing_max "$SIZING_MAX" "0.015")"
  SIZING_SCALE="$(apply_input_value sizing_scale "$SIZING_SCALE" "100.0")"
fi

# Second pass: normal CLI overrides (ignore --input which was handled)
set -- "${ARGS[@]}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input|-i) shift 2;;
    --base) BASE_DIR="$2"; shift 2;;
    --loops) LOOPS="$2"; shift 2;;
    --gmsh) GMSH_BIN="$2"; shift 2;;
    --pumi-bin) PUMI_BIN="$2"; shift 2;;
    --start-amr-mesh) START_AMR_MESH="$2"; shift 2;;
    --geo) GEO_FILE="$2"; shift 2;;
    --geo-amr) GEO_FILE_AMR="$2"; shift 2;;
    --sim-mesh) SIM_MESH="$2"; shift 2;;
    --sim-mesh-amr) SIM_MESH_AMR="$2"; shift 2;;
    --case) CASE_SCRIPT="$2"; shift 2;;
    --case-amr) CASE_SCRIPT_AMR="$2"; shift 2;;
    --final) FINAL_PY="$2"; shift 2;;
    --pvpython) PVPYTHON="$2"; shift 2;;
    --result-root) RESULT_ROOT="$2"; shift 2;;
    --pv-output) PV_OUTPUT_DIR="$2"; shift 2;;
    --logs) LOG_DIR="$2"; shift 2;;
    --refine-from) REFINE_FROM="$2"; shift 2;;
    --raw-csv) RAW_CSV="$2"; shift 2;;
    --filtered-csv) FILTERED_CSV="$2"; shift 2;;
    --pos) POS_FILE="$2"; shift 2;;
    --mfp-column) MFP_COLUMN="$2"; shift 2;;
    --pos-scale) POS_SCALE="$2"; shift 2;;
    --pvd-file) PVD_FILE="$2"; shift 2;;
    --pvd-create) PVD_CREATE="$2"; shift 2;;
    --pvd-pattern) PVD_PATTERN="$2"; shift 2;;
    --partition-mesh) PARTITION_MESH="$2"; shift 2;;
    --partition-parts) PARTITION_PARTS="$2"; shift 2;;
    --partition-script) PARTITION_SCRIPT="$2"; shift 2;;
    --partition-script-amr) PARTITION_SCRIPT_AMR="$2"; shift 2;;
    --extraction-mode) EXTRACTION_MODE="$2"; shift 2;;
    --gradient-field) GRADIENT_FIELD="$2"; shift 2;;
    --sizing-min) SIZING_MIN="$2"; shift 2;;
    --sizing-max) SIZING_MAX="$2"; shift 2;;
    --sizing-scale) SIZING_SCALE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if ! [[ "$LOOPS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --loops must be a positive integer (got '$LOOPS')" >&2
  exit 1
fi

PVD_CREATE=$(echo "$PVD_CREATE" | tr "[:upper:]" "[:lower:]")
[[ "$PVD_CREATE" == "false" ]] || PVD_CREATE="true"

PVD_PATTERN="$(echo "$PVD_PATTERN" | xargs)"
[[ -z "$PVD_PATTERN" ]] && PVD_PATTERN="field*.vtu"

PARTITION_MESH="$(echo "$PARTITION_MESH" | tr "[:upper:]" "[:lower:]")"
[[ "$PARTITION_MESH" == "true" ]] && PARTITION_MESH="true" || PARTITION_MESH="false"
START_AMR_MESH="$(echo "$START_AMR_MESH" | xargs)"

# ---------------------------
# Autodetect BASE_DIR as before
# ---------------------------
if [[ -z "${BASE_DIR}" ]]; then
  if [[ -d "$(pwd)/gmsh" ]]; then
    BASE_DIR="$(pwd)"
  else
    CANDIDATE="${SCRIPT_DIR}"
    [[ -d "${SCRIPT_DIR}/../gmsh" ]] && CANDIDATE="${SCRIPT_DIR}/.."
    BASE_DIR="$(cd "$CANDIDATE" && pwd)"
  fi
fi
BASE_DIR="$(cd "$BASE_DIR" && pwd)"

# ---------------------------
# Derived paths
# ---------------------------
GMESH_DIR="${BASE_DIR}/gmsh"
RESULT_ROOT="${RESULT_ROOT:-${BASE_DIR}/comet_result}"
RESULT_SPEC="${PV_OUTPUT_DIR:-field*}"
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"

[[ -d "$GMESH_DIR" ]] || { echo "ERROR: Gmsh dir not found: $GMESH_DIR"; exit 1; }
mkdir -p "$LOG_DIR" "$RESULT_ROOT"

if [[ -z "$GMSH_BIN" || ! -x "$GMSH_BIN" ]]; then
  if detected_gmsh="$(detect_gmsh_binary)"; then
    gmsh_dirname="$(cd "$(dirname "$detected_gmsh")" && pwd)"
    GMSH_BIN="${gmsh_dirname}/$(basename -- "$detected_gmsh")"
    echo "Auto-detected gmsh binary: $GMSH_BIN"
  else
    echo "ERROR: Unable to auto-detect gmsh binary. Please provide --gmsh or set GMSH_BIN." >&2
    exit 1
  fi
fi

command -v "$PVPYTHON" >/dev/null 2>&1 || { echo "ERROR: pvpython '$PVPYTHON' not found"; exit 1; }
[[ -x "$GMSH_BIN" ]] || { echo "ERROR: gmsh binary not executable: $GMSH_BIN"; exit 1; }

GEO_PATH="$(abs_path "$GEO_FILE" "$GMESH_DIR")"
GEO_AMR_PATH="$(abs_path "$GEO_FILE_AMR" "$GMESH_DIR")"
[[ -f "$GEO_PATH" ]] || { echo "ERROR: GEO not found: $GEO_PATH"; exit 1; }
[[ -f "$GEO_AMR_PATH" ]] || { echo "ERROR: AMR GEO not found: $GEO_AMR_PATH"; exit 1; }

CASE_SCRIPT_PATH="$(abs_path "$CASE_SCRIPT" "$BASE_DIR")"
CASE_SCRIPT_AMR_PATH="$(abs_path "$CASE_SCRIPT_AMR" "$BASE_DIR")"
[[ -x "$CASE_SCRIPT_PATH" ]] || { echo "ERROR: case script not found/executable: $CASE_SCRIPT_PATH"; exit 1; }
[[ -x "$CASE_SCRIPT_AMR_PATH" ]] || { echo "ERROR: AMR case script not found/executable: $CASE_SCRIPT_AMR_PATH"; exit 1; }

FINAL_PY_PATH="$(abs_path "$FINAL_PY" "$BASE_DIR")"
[[ -f "$FINAL_PY_PATH" ]] || { echo "ERROR: final.py not found: $FINAL_PY_PATH"; exit 1; }

SIM_MESH_PATH="$(abs_path "$SIM_MESH" "$BASE_DIR")"
SIM_MESH_AMR_PATH="$(abs_path "$SIM_MESH_AMR" "$BASE_DIR")"
RAW_CSV_PATH="$(abs_path "$RAW_CSV" "$BASE_DIR")"
FILTERED_CSV_PATH="$(abs_path "$FILTERED_CSV" "$BASE_DIR")"
POS_PATH="$(abs_path "$POS_FILE" "$BASE_DIR")"

mkdir -p "$(dirname "$SIM_MESH_PATH")" "$(dirname "$SIM_MESH_AMR_PATH")" \
         "$(dirname "$RAW_CSV_PATH")" "$(dirname "$FILTERED_CSV_PATH")" \
         "$(dirname "$POS_PATH")"

SIM_MESH_BASE="$(basename "$SIM_MESH_PATH")"
SIM_MESH_AMR_BASE="$(basename "$SIM_MESH_AMR_PATH")"
SIM_EXT=""
[[ "$SIM_MESH_BASE" == *.* ]] && SIM_EXT=".${SIM_MESH_BASE##*.}"
SIM_AMR_EXT=""
[[ "$SIM_MESH_AMR_BASE" == *.* ]] && SIM_AMR_EXT=".${SIM_MESH_AMR_BASE##*.}"

NORMAL_TMP="${GMESH_DIR}/${SIM_MESH_BASE%.*}_tmp${SIM_EXT}"
AMR_TMP="${GMESH_DIR}/${SIM_MESH_AMR_BASE%.*}_tmp${SIM_AMR_EXT}"
PARTS="$(derive_parts "$PARTITION_PARTS" "$CASE_SCRIPT")"

start_from_refine="false"
start_from_amr_mesh="false"
START_AMR_MESH_PATH=""
if [[ -n "${REFINE_FROM}" ]]; then
  start_from_refine="true"
  echo "Preparing refinement from existing results: ${REFINE_FROM}"
  clear_live_results "$RESULT_SPEC"
  seed_dir="${RESULT_ROOT}/field_refine_seed"
  rm -rf "$seed_dir"
  mkdir -p "$seed_dir"

  if [[ -d "${REFINE_FROM}" ]]; then
    cp -a "${REFINE_FROM}/." "$seed_dir/"
  elif [[ -f "${REFINE_FROM}" ]]; then
    case "${REFINE_FROM}" in
      *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2) tar -xf "${REFINE_FROM}" -C "$seed_dir";;
      *.zip) unzip -q "${REFINE_FROM}" -d "$seed_dir";;
      *) echo "ERROR: --refine-from must be a directory or supported archive"; exit 1;;
    esac
  else
    echo "ERROR: --refine-from path invalid: ${REFINE_FROM}"; exit 1;
  fi

  RESULT_SPEC+=" field_refine_seed"
fi
if [[ -n "${START_AMR_MESH}" ]]; then
  START_AMR_MESH_PATH="$(abs_path "$START_AMR_MESH" "$BASE_DIR")"
  [[ -f "$START_AMR_MESH_PATH" ]] || { echo "ERROR: start_amr_mesh not found: $START_AMR_MESH_PATH"; exit 1; }
  start_from_amr_mesh="true"
  # Skip normal mesh generation when starting from an existing AMR mesh
  start_from_refine="true"
fi

echo
echo "Running pipeline with:"
printf '  %-18s %s\n' \
  "Base dir" "$BASE_DIR" \
  "Gmsh binary" "$GMSH_BIN" \
  "Loops" "$LOOPS" \
  "Geo" "$GEO_PATH" \
  "Geo AMR" "$GEO_AMR_PATH" \
  "Mesh" "$SIM_MESH_PATH" \
  "Mesh AMR" "$SIM_MESH_AMR_PATH" \
  "Case script" "$CASE_SCRIPT_PATH" \
  "Case AMR" "$CASE_SCRIPT_AMR_PATH" \
  "Result spec" "$RESULT_SPEC" \
  "Converter" "$FINAL_PY_PATH" \
  "pvpython" "$PVPYTHON"
[[ -n "$REFINE_FROM" ]] && printf '  %-18s %s\n' "Refine from" "$REFINE_FROM"
echo

for i in $(seq 1 "$LOOPS"); do
  echo
  echo "==============================================="
  echo " ITERATION $i / $LOOPS"
  echo "==============================================="

  if [[ "$start_from_amr_mesh" == "true" && "$i" -eq 1 ]]; then
    echo "Using provided AMR mesh as starting point → $START_AMR_MESH_PATH"
    cp -f "$START_AMR_MESH_PATH" "$SIM_MESH_AMR_PATH"
    run_partition "$SIM_MESH_AMR_PATH" "$PARTITION_SCRIPT_AMR" "$PARTS"

    echo "Clearing previous results matching '$RESULT_SPEC'..."
    clear_live_results "$RESULT_SPEC"
    echo "Running MPI case for the starting AMR mesh..."
    (cd "$BASE_DIR" && "$CASE_SCRIPT_AMR_PATH") 2>&1 | tee "${LOG_DIR}/output_amr${i}.txt"

    mapfile -t live_results < <(expand_result_sources "$RESULT_SPEC")
    if [[ ${#live_results[@]} -gt 0 ]]; then
      pvd_target="${PVD_FILE:+$(abs_path "$PVD_FILE" "$RESULT_ROOT")}"
      [[ -z "$pvd_target" ]] && pvd_target="${live_results[0]%/}/auto_field.pvd"
      build_pvd_for_dir "${live_results[0]}" "$pvd_target"
    else
      echo "[WARN] No live results found for PVD build."
    fi

    ARCHIVE_DIR="${RESULT_ROOT}/output_amr${i}_result"
    echo "Archiving ParaView results for AMR mesh → $ARCHIVE_DIR"
    archive_results "$ARCHIVE_DIR" "$RESULT_SPEC"

    # POS and next-mesh prep for subsequent iterations
    convert_results_to_pos "$i"
    if [[ "$i" -lt "$LOOPS" ]]; then
      echo "Generating adaptive mesh with Gmsh..."
      run_gmsh "$GEO_AMR_PATH" "$AMR_TMP" "${LOG_DIR}/${SIM_MESH_AMR_BASE%.*}_amr_${i}.txt"
      BACKUP_MESH_AMR="${GMESH_DIR}/${SIM_MESH_AMR_BASE%.*}${i}${SIM_AMR_EXT}"
      echo "Saving backup amr mesh → $BACKUP_MESH_AMR"
      cp -f "$AMR_TMP" "$BACKUP_MESH_AMR"
      echo "Updating simulation AMR mesh → $SIM_MESH_AMR_PATH"
      cp -f "$AMR_TMP" "$SIM_MESH_AMR_PATH"
      run_partition "$SIM_MESH_AMR_PATH" "$PARTITION_SCRIPT_AMR" "$PARTS"
    fi
    continue

  elif [[ "$start_from_refine" == "true" || "$i" -gt 1 ]]; then
    echo "Skipping normal mesh generation/run (AMR-only loop)"
  else
    # -------- Normal mesh generation --------
    echo "Generating normal mesh with Gmsh..."
    run_gmsh "$GEO_PATH" "$NORMAL_TMP" "${LOG_DIR}/${SIM_MESH_BASE%.*}_normal_${i}.txt"

    NORMAL_BACKUP="${GMESH_DIR}/${SIM_MESH_BASE%.*}${i}${SIM_EXT}"
    echo "Saving backup mesh → $NORMAL_BACKUP"
    cp -f "$NORMAL_TMP" "$NORMAL_BACKUP"

    echo "Updating simulation mesh → $SIM_MESH_PATH"
    cp -f "$NORMAL_TMP" "$SIM_MESH_PATH"

    # -------- Partition normal mesh (optional) --------
    run_partition "$SIM_MESH_PATH" "$PARTITION_SCRIPT" "$PARTS"

    echo "Clearing previous results matching '$RESULT_SPEC'..."
    clear_live_results "$RESULT_SPEC"
    echo "Running MPI case for the normal mesh..."
    (cd "$BASE_DIR" && "$CASE_SCRIPT_PATH") 2>&1 | tee "${LOG_DIR}/output_normal${i}.txt"

    # Build PVD in the live results before archiving (so archives include it)
    mapfile -t live_results < <(expand_result_sources "$RESULT_SPEC")
    if [[ ${#live_results[@]} -gt 0 ]]; then
      pvd_target="${PVD_FILE:+$(abs_path "$PVD_FILE" "$RESULT_ROOT")}"
      [[ -z "$pvd_target" ]] && pvd_target="${live_results[0]%/}/auto_field.pvd"
      build_pvd_for_dir "${live_results[0]}" "$pvd_target"
    fi

    ARCHIVE_DIR="${RESULT_ROOT}/output_normal${i}_result"
    echo "Archiving ParaView results for normal mesh → $ARCHIVE_DIR"
    archive_results "$ARCHIVE_DIR" "$RESULT_SPEC"
  fi

  # -------- POS export to drive AMR --------
  convert_results_to_pos "$i"

  # -------- AMR mesh generation --------
  echo "Generating adaptive mesh with Gmsh..."
  run_gmsh "$GEO_AMR_PATH" "$AMR_TMP" "${LOG_DIR}/${SIM_MESH_AMR_BASE%.*}_amr_${i}.txt"

  BACKUP_MESH_AMR="${GMESH_DIR}/${SIM_MESH_AMR_BASE%.*}${i}${SIM_AMR_EXT}"
  echo "Saving backup amr mesh → $BACKUP_MESH_AMR"
  cp -f "$AMR_TMP" "$BACKUP_MESH_AMR"

  echo "Updating simulation AMR mesh → $SIM_MESH_AMR_PATH"
  cp -f "$AMR_TMP" "$SIM_MESH_AMR_PATH"

  # -------- Partition AMR mesh (optional) --------
  run_partition "$SIM_MESH_AMR_PATH" "$PARTITION_SCRIPT_AMR" "$PARTS"

  echo "Clearing previous results matching '$RESULT_SPEC'..."
  clear_live_results "$RESULT_SPEC"

  # -------- AMR run to ensure final mesh has results --------
  echo "Running MPI case for the AMR mesh..."
  (cd "$BASE_DIR" && "$CASE_SCRIPT_AMR_PATH") 2>&1 | tee "${LOG_DIR}/output_amr${i}.txt"

  # Build PVD in the live results before archiving AMR results
  mapfile -t live_results < <(expand_result_sources "$RESULT_SPEC")
  if [[ ${#live_results[@]} -gt 0 ]]; then
    pvd_target="${PVD_FILE:+$(abs_path "$PVD_FILE" "$RESULT_ROOT")}"
    [[ -z "$pvd_target" ]] && pvd_target="${live_results[0]%/}/auto_field.pvd"
    build_pvd_for_dir "${live_results[0]}" "$pvd_target"
  fi

  ARCHIVE_DIR="${RESULT_ROOT}/output_amr${i}_result"
  echo "Archiving ParaView results for AMR mesh → $ARCHIVE_DIR"
  archive_results "$ARCHIVE_DIR" "$RESULT_SPEC"

  echo "Iteration $i complete."
done

echo
echo "All ${LOOPS} iteration(s) finished."
echo "Backups in: $GMESH_DIR → ${SIM_MESH_BASE%.*}{1..${LOOPS}}${SIM_EXT} and ${SIM_MESH_AMR_BASE%.*}{1..${LOOPS}}${SIM_AMR_EXT}"
echo "Archived results in: $RESULT_ROOT → output_normal{1..${LOOPS}}_result, output_amr{1..${LOOPS}}_result"
