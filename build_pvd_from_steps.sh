#!/bin/bash
# Build a .pvd collection from step_* folders containing field*.vtu files.
# Usage: ./build_pvd_from_steps.sh --field-dir PATH [--output FILE] [--pattern GLOB]
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'USAGE'
Usage: ./build_pvd_from_steps.sh --field-dir DIR [--output FILE] [--pattern GLOB]

Options:
  --field-dir DIR   Directory that contains step_* folders with VTU files.
  --output FILE     Output PVD file path (default: DIR/auto_field.pvd)
  --pattern GLOB    VTU glob inside each step folder (default: field*.vtu)
  -h, --help        Show this help.
USAGE
}

FIELD_DIR=""
OUTPUT=""
PATTERN="field*.vtu"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --field-dir) FIELD_DIR="$2"; shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    --pattern) PATTERN="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$FIELD_DIR" ]]; then
  echo "ERROR: --field-dir is required" >&2
  exit 1
fi

if [[ ! -d "$FIELD_DIR" ]]; then
  echo "ERROR: field dir not found: $FIELD_DIR" >&2
  exit 1
fi

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="${FIELD_DIR%/}/auto_field.pvd"
fi

FIELD_DIR_ABS="$(cd "$FIELD_DIR" && pwd)"
OUTPUT_ABS="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
VTU_PATTERN="$PATTERN"

python - "$FIELD_DIR_ABS" "$OUTPUT_ABS" "$VTU_PATTERN" <<'PY2'
import sys, re
from pathlib import Path
field_dir = Path(sys.argv[1])
output = Path(sys.argv[2])
pattern = sys.argv[3]

datasets = []
for d in sorted(field_dir.glob('step_*')):
    if not d.is_dir():
        continue
    m = re.search(r'step_([0-9]+)', d.name)
    if not m:
        continue
    ts = int(m.group(1))
    vtus = sorted(d.glob(pattern))
    for vtu in vtus:
        try:
            rel = vtu.relative_to(field_dir)
        except ValueError:
            rel = vtu.name
        datasets.append((ts, rel.as_posix()))

if not datasets:
    print(f"[WARN] No VTU files found in {field_dir} matching {pattern}; no PVD written.")
    sys.exit(0)

datasets.sort(key=lambda x: (x[0], x[1]))
lines = [
    '<?xml version="1.0"?>',
    '<VTKFile type="Collection" version="0.1" byte_order="LittleEndian" compressor="vtkZLibDataCompressor">',
    '<Collection>',
]
for ts, path in datasets:
    lines.append(f'  <DataSet timestep="{ts}" file="{path}"/>')
lines.append('</Collection>')
lines.append('</VTKFile>')

output.parent.mkdir(parents=True, exist_ok=True)
output.write_text('\n'.join(lines))
print(f"[INFO] Wrote PVD with {len(datasets)} entries -> {output}")
PY2
