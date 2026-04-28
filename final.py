#!/usr/bin/env pvpython
"""
final.py — field extraction step of the AMR pipeline.

Reads the latest timestep from a PVD/VTU result tree, builds a per-point
sizing field, and writes a Gmsh .pos background view. The orchestrator
(all_run.sh) calls this once per AMR loop.

Two extraction modes are supported:

  direct    : the solver already wrote a meaningful length scale (e.g.
              COMET's "mean free path" field). We just export it as-is.

  gradient  : compute |grad(F)| of a chosen scalar field F (e.g. p, rho),
              and map it through the sizing formula
                  h = h_min + (h_max - h_min) / (1 + alpha * |grad F| / max|grad F|)
              so that high-gradient regions get small cells and far-field
              regions get large cells.

Usage examples:

  # DSMC (direct mode is the default):
  pvpython final.py --pvd results.pvd --mfp-column "mean free path"

  # OpenFOAM, density-gradient driven AMR:
  pvpython final.py --pvd results.pvd --extraction-mode gradient \
      --gradient-field rho --sizing-min 0.001 --sizing-max 0.015 --sizing-scale 100.0

  # OpenFOAM, pressure-gradient driven AMR:
  pvpython final.py --pvd results.pvd --extraction-mode gradient \
      --gradient-field p --sizing-min 0.002 --sizing-max 0.015 --sizing-scale 100.0

The script must be run with pvpython (ParaView's Python). Calling it with
system python3 will fail at "from paraview.simple import *".
"""

import argparse
import csv
import math
import re
from pathlib import Path
from paraview.simple import *  # noqa: F401,F403


def _export_direct(pvd_file, output_csv):
    """Direct mode: read PVD, go to last timestep, export all point data as-is."""
    reader = PVDReader(FileName=pvd_file)
    animationScene = GetAnimationScene()
    animationScene.UpdateAnimationUsingDataTimeSteps()
    if hasattr(reader, "TimestepValues") and reader.TimestepValues:
        last_time = reader.TimestepValues[-1]
        reader.UpdatePipeline(time=last_time)
        animationScene.GoToLast()

    cd2pd = CellDatatoPointData(Input=reader)
    cd2pd.UpdatePipeline()

    spreadsheet_view = CreateView("SpreadSheetView")
    Show(cd2pd, spreadsheet_view, "SpreadSheetRepresentation")
    spreadsheet_view.FieldAssociation = "Point Data"
    spreadsheet_view.Update()

    ExportView(output_csv, view=spreadsheet_view)
    print(f"[INFO] Exported all point data to CSV: {output_csv}")


def _export_gradient(pvd_file, output_csv, gradient_field,
                     sizing_min, sizing_max, sizing_scale):
    """Gradient mode: compute gradient of a field, then create sizing field."""
    from paraview import servermanager

    reader = PVDReader(FileName=pvd_file)
    animationScene = GetAnimationScene()
    animationScene.UpdateAnimationUsingDataTimeSteps()
    if hasattr(reader, "TimestepValues") and reader.TimestepValues:
        last_time = reader.TimestepValues[-1]
        reader.UpdatePipeline(time=last_time)
        animationScene.GoToLast()

    cd2pd = CellDatatoPointData(Input=reader)
    cd2pd.UpdatePipeline()

    # Compute gradient of the requested field
    grad_name = f"grad_{gradient_field}"
    gradient = Gradient(Input=cd2pd)
    gradient.ScalarArray = ['POINTS', gradient_field]
    gradient.ResultArrayName = grad_name
    gradient.UpdatePipeline()

    # Compute magnitude
    mag_name = f"{grad_name}_mag"
    calculator = Calculator(Input=gradient)
    calculator.Function = f'mag({grad_name})'
    calculator.ResultArrayName = mag_name
    calculator.UpdatePipeline()

    # Get max gradient for normalization
    calc_data = servermanager.Fetch(calculator)
    grad_array = calc_data.GetPointData().GetArray(mag_name)
    max_grad = 1e-10
    if grad_array:
        for i in range(grad_array.GetNumberOfTuples()):
            v = grad_array.GetValue(i)
            if v > max_grad:
                max_grad = v
    print(f"[INFO] Max {gradient_field} gradient magnitude: {max_grad}")

    # Sizing formula: high gradient -> small cells, low gradient -> large cells
    # sizing = sizing_min + (sizing_max - sizing_min) / (1 + sizing_scale * grad/max_grad)
    sizing_range = sizing_max - sizing_min
    sizing_col = f"{gradient_field}_sizing"
    sizing = Calculator(Input=calculator)
    sizing.Function = f'{sizing_min} + {sizing_range} / (1.0 + {sizing_scale} * {mag_name} / {max_grad})'
    sizing.ResultArrayName = sizing_col
    sizing.UpdatePipeline()

    spreadsheet_view = CreateView("SpreadSheetView")
    Show(sizing, spreadsheet_view, "SpreadSheetRepresentation")
    spreadsheet_view.FieldAssociation = "Point Data"
    spreadsheet_view.Update()

    ExportView(output_csv, view=spreadsheet_view)
    print(f"[INFO] Exported point data with {sizing_col} to CSV: {output_csv}")


def export_all_point_data(pvd_file, output_csv, extraction_mode="direct",
                          gradient_field=None, sizing_min=0.001,
                          sizing_max=0.015, sizing_scale=100.0):
    """Route to the correct export path based on extraction mode."""
    if extraction_mode == "gradient":
        if not gradient_field:
            raise ValueError("--gradient-field is required when --extraction-mode is 'gradient'")
        _export_gradient(pvd_file, output_csv, gradient_field,
                         sizing_min, sizing_max, sizing_scale)
    else:
        _export_direct(pvd_file, output_csv)


def _normalize(name):
    return re.sub(r"_+", "_", re.sub(r"[^0-9a-zA-Z]+", "_", name)).strip("_").lower()


def _find_index(header, target, fallbacks=None):
    fallbacks = fallbacks or []
    norm_map = {_normalize(h): i for i, h in enumerate(header)}
    for key in [_normalize(target)] + [_normalize(x) for x in fallbacks]:
        if key in norm_map:
            return norm_map[key]
    raise KeyError(f"Column '{target}' not found. Available: {header}")


def extract_coords_and_field(input_csv, filtered_csv, field_column="mean free path"):
    """Extract x, y, z and chosen column into a compact CSV."""
    with open(input_csv, newline="") as fin:
        reader = csv.reader(fin)
        header = next(reader)
        try:
            idx_x = _find_index(header, "coordinates_0",
                                fallbacks=["x", "points_0", "Points:0"])
            idx_y = _find_index(header, "coordinates_1",
                                fallbacks=["y", "points_1", "Points:1"])
            idx_z = _find_index(header, "coordinates_2",
                                fallbacks=["z", "points_2", "Points:2"])
            idx_field = _find_index(header, field_column,
                                    fallbacks=["mean free path", "mean_free_path"])
        except KeyError as e:
            raise RuntimeError(f"[ERROR] Required column missing: {e}") from e

        with open(filtered_csv, "w", newline="") as fout:
            writer = csv.writer(fout)
            writer.writerow(["x", "y", "z", "mean_free_path"])
            for row in reader:
                try:
                    writer.writerow([row[idx_x], row[idx_y], row[idx_z], row[idx_field]])
                except Exception:
                    continue

    print(f"[INFO] Wrote filtered CSV with coords and {field_column}: {filtered_csv}")


def convert_csv_to_pos(csv_file, pos_file, multiply_factor=1.0, fallback_value=0.015):
    """Convert CSV (x,y,z,value) to Gmsh POS format."""
    data = []
    with open(csv_file, newline="") as f:
        reader = csv.reader(f)
        next(reader, None)
        for row in reader:
            try:
                x, y, z, val = row[:4]
                x = float(x.strip())
                y = float(y.strip())
                z = float(z.strip())
                val = float(val.strip())
                if math.isnan(val) or math.isinf(val) or val <= 0:
                    val = fallback_value
                data.append((x, y, z, val * multiply_factor))
            except Exception:
                continue

    with open(pos_file, "w") as f:
        f.write('View "MFP" {\n')
        for (x, y, z, v) in data:
            f.write(f"SP({x},{y},{z}){{{v}}};\n")
        f.write("};\n")

    print(f"[INFO] Wrote {len(data)} points to POS file: {pos_file}")


def main():
    parser = argparse.ArgumentParser(
        description="Universal field extraction for AMR pipeline (COMET + OpenFOAM).")
    parser.add_argument("--pvd", required=True, help="Path to the PVD file")
    parser.add_argument("--raw-csv", default="gmsh/all_data.csv", help="Full CSV export")
    parser.add_argument("--filtered-csv", default="gmsh/filtered_mfp.csv", help="Filtered CSV")
    parser.add_argument("--pos", default="gmsh/mfp.pos", help="Output POS file for Gmsh")
    parser.add_argument("--multiply-factor", type=float, default=1.0, help="Scale POS values")
    parser.add_argument("--mfp-column", default="mean free path", help="Column name to extract")
    parser.add_argument("--results-root", default="", help="(Optional) results root")
    parser.add_argument("--field-pattern", default="", help="(Optional) field pattern")

    # New universal extraction args
    parser.add_argument("--extraction-mode", default="direct",
                        choices=["direct", "gradient"],
                        help="Extraction mode: 'direct' extracts existing field, "
                             "'gradient' computes gradient then sizing field")
    parser.add_argument("--gradient-field", default=None,
                        help="Scalar field to compute gradient of (e.g., rho, p). "
                             "Required when --extraction-mode=gradient")
    parser.add_argument("--sizing-min", type=float, default=0.001,
                        help="Minimum cell size in sizing formula (default: 0.001)")
    parser.add_argument("--sizing-max", type=float, default=0.015,
                        help="Maximum cell size in sizing formula (default: 0.015)")
    parser.add_argument("--sizing-scale", type=float, default=100.0,
                        help="Scaling factor in sizing formula (default: 100.0)")

    args = parser.parse_args()

    # Auto-set mfp_column for gradient mode if user didn't override
    if args.extraction_mode == "gradient" and args.mfp_column == "mean free path":
        if args.gradient_field:
            args.mfp_column = f"{args.gradient_field}_sizing"

    for path in (args.raw_csv, args.filtered_csv, args.pos):
        parent = Path(path).expanduser().resolve().parent
        parent.mkdir(parents=True, exist_ok=True)

    export_all_point_data(
        args.pvd, args.raw_csv,
        extraction_mode=args.extraction_mode,
        gradient_field=args.gradient_field,
        sizing_min=args.sizing_min,
        sizing_max=args.sizing_max,
        sizing_scale=args.sizing_scale,
    )
    extract_coords_and_field(args.raw_csv, args.filtered_csv,
                             field_column=args.mfp_column)

    # Use sizing_max as fallback for NaN/Inf in gradient mode
    fallback = args.sizing_max if args.extraction_mode == "gradient" else 0.015
    convert_csv_to_pos(args.filtered_csv, args.pos,
                       multiply_factor=args.multiply_factor,
                       fallback_value=fallback)


if __name__ == "__main__":
    main()
