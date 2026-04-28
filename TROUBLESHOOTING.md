# Troubleshooting

A catalog of errors I have actually seen running the pipeline, and what
fixed them. Organized by **the message you see** rather than by the
underlying cause, because that's how you'll be searching.

If you hit something not listed here, please open an issue. Include your
`amr_pipeline.input`, the last 100 lines of the relevant log
(`logs/output_amr*.txt` or `openfoam_case/log.rhoCentralFoam`), and your
Gmsh, ParaView, and OpenFOAM versions.

---

## Step 1 errors (config / paths)

### `ERROR: amr_pipeline.input not found`

The wrapper script could not find the input file. By default it looks in the
same directory as the script. Either run `./all_run.sh` from the repo root,
or pass `--input /path/to/amr_pipeline.input` explicitly.

### `ERROR: gmsh binary not executable: /home/.../gmsh`

The path in `gmsh_bin` either doesn't exist or doesn't have the executable
bit set. Check:

```bash
ls -l /path/to/gmsh
chmod +x /path/to/gmsh
```

If the path is right but you still get the error, it's the wrong
architecture (32-bit binary on a 64-bit system, or vice versa).

### `ERROR: pvpython 'pvpython' not found`

`pvpython` is not on `$PATH`, or `pvpython` in `amr_pipeline.input` points
nowhere. Use the absolute path to the MPI build of ParaView:

```ini
pvpython = /home/USER/paraview/ParaView-5.13.2-MPI-Linux-Python3.10-x86_64/bin/pvpython
```

### `ERROR: GEO not found: /home/.../gmsh/2d_cylinder.geo`

The `.geo` file resolved to a path that doesn't exist. Two common causes:

1. You changed `geo_file` in `amr_pipeline.input` but didn't put the file
   into `gmsh/`. Drop the file in `gmsh/` or use an absolute path.
2. You're running from a wrong working directory and `base_dir` auto-detect
   went sideways. `cd` into the repo root and try again.

### `ERROR: --loops must be a positive integer (got '...')`

Self-explanatory. The value of `loops` in `amr_pipeline.input` is not a
positive integer. Make sure no comment or trailing text leaked onto the
same line.

---

## Gmsh errors

### `Error : Unknown command line option '-3'`

You're not running Gmsh 4.x. Old Gmsh 2.x doesn't support the flags the
pipeline uses. Upgrade.

### `Error: PostView field 'mfp.pos': file not found`

Gmsh ran the AMR `.geo` file before `final.py` had written `mfp.pos`. This
shouldn't happen on iteration 1 because the orchestrator uses the
non-AMR `.geo` first. If it happens on iteration 2 or later, the previous
`final.py` run must have failed silently — check `logs/csv_2_pos_*.txt`.

### `Error: 1d mesh: bad orientation` or `Self-intersecting elements`

The AMR sizing field has produced cells that are too small in a region with
sharp geometry, and the resulting mesh has tangled triangles. Two fixes:

1. **Bump `sizing_min` up.** Going from `0.001` to `0.002` is often
   enough.
2. **Lower `sizing_scale`.** The default `100.0` can be too sharp for
   some geometries. Try `50.0`.

### `Mesh.MshFileVersion not set` (warning) or `gmshToFoam: invalid format`

Add `Mesh.MshFileVersion = 2.2;` to your `.geo` file. OpenFOAM v2406's
`gmshToFoam` does not handle Gmsh v4 mesh files reliably.

---

## OpenFOAM errors

### `gmshToFoam: parsing error at line ...`

Almost always the v4 / v2.2 mesh-format issue. See above: add
`Mesh.MshFileVersion = 2.2;` to the `.geo`.

### `Foam::error::printStack(...)` followed by floating-point exception

Open `openfoam_case/log.rhoCentralFoam` and look at the last 30 lines.
What usually went wrong:

* **NaN in pressure or temperature.** `foam_sigfpe = false` in the input
  file lets the run continue past these without crashing, which is what
  you want during AMR experiments.
* **Bad cell aspect ratio after AMR.** If you see
  `negative or zero specific volume`, the mesh has a cell with bad
  geometry. Increase `sizing_min`, decrease `sizing_scale`, or look at the
  mesh in ParaView and identify where the bad cells are.
* **Courant number explosion.** Set `maxCo` lower in `controlDict`
  (try `0.2` or `0.15`).

### `--> FOAM FATAL ERROR: Patch type 'patch' not allowed for empty boundary`

The `boundary_fix` rule didn't match. Check that the patch name in your
`.geo` `Physical Surface` definitions matches the name in `boundary_fix`.
Capitalization counts.

### Solver runs but produces no `VTK/` directory

`foamToVTK` failed silently. Common cause: the solver ran but `endTime`
arrived before any write step happened. Check
`openfoam_case/log.rhoCentralFoam` for write events. If the solver wrote
no time directories, lower `writeInterval` in `system/controlDict`.

---

## ParaView / final.py errors

### `ImportError: No module named paraview.simple`

You're running `final.py` with system Python instead of `pvpython`. The
orchestrator does this automatically; if you ran `final.py` directly,
prepend `pvpython`:

```bash
pvpython final.py --pvd ...
```

### `TypeError: Cannot find array 'p_sizing'`

The `mfp_column` value doesn't match what `final.py` actually wrote.
In gradient mode, `mfp_column` should be `<gradient_field>_sizing` (e.g.
`p_sizing` if `gradient_field = p`).

### `[INFO] Wrote 0 points to POS file`

`final.py` ran but produced an empty `.pos`. Causes:

* The PVD file pointed to a folder with no real VTU files.
* The chosen field name doesn't exist in the data
  (`gradient_field = pressure` instead of `p` for OpenFOAM, for example).
* The data has only NaN/Inf in the chosen field.

Check `gmsh/all_data.csv` first. If it's empty, the PVD-VTU chain failed.
If it has rows but `gmsh/filtered_mfp.csv` is empty, it's a column-name
mismatch.

### Pipeline runs but the AMR mesh looks like the coarse mesh

The `.pos` file exists but Gmsh ignored it. Double-check that
`2d_cylinder_amr.geo` contains all three of:

```gmsh
Merge "mfp.pos";
Field[1] = PostView;
Field[1].ViewTag = 1;
...
Background Field = 1;
```

If `Background Field` is missing, Gmsh runs but doesn't apply the sizing
field.

---

## Mach 3.5+ crashes

For the bundled test case, the upper stable Mach number on the
unstructured Gmsh mesh I ship is **roughly Mach 3.0**. Pushing to Mach
3.5 reliably produces, after iteration 2 or 3:

```
--> FOAM FATAL ERROR: cell internal energy is negative or zero
```

The cause is mesh quality: rhoCentralFoam with Minmod reconstruction is
sensitive to high-aspect-ratio cells, and AMR around a strong shock
inevitably produces some. Three options if you want to push higher Mach:

1. **Switch to a structured mesh.** `Recombine` + transfinite curves in
   `.geo` give a quad-only mesh that handles higher Mach. The pipeline
   doesn't change.
2. **Use a more robust limiter.** `vanLeer` or `vanAlbada` instead of
   `Minmod` in `fvSchemes` is sometimes enough.
3. **Use a different solver.** `sonicFoam` is more forgiving than
   `rhoCentralFoam` for high Mach, at the cost of being more diffusive.

This is a limitation of the **bundled test case**, not of the pipeline
itself. The pipeline drives whatever solver you point it at; the failure
is downstream.

---

## Disk space and cleanup

Each AMR loop adds roughly 200–400 MB of output to `comet_result/`. If
you're running many experiments, that adds up.

Safe to delete between experiments:

```bash
rm -rf comet_result/output_normal*_result
rm -rf comet_result/output_amr*_result
rm -rf comet_result/field
rm -rf logs/
rm -f gmsh/2d_cylinder*[0-9].msh   # iterations 1, 2, 3 backups
rm -f gmsh/all_data.csv gmsh/filtered_mfp.csv gmsh/mfp.pos
```

Do **not** delete:

* `gmsh/2d_cylinder.geo` and `gmsh/2d_cylinder_amr.geo` (the geometry).
* `gmsh/2d_cylinder.msh` and `gmsh/2d_cylinder_amr.msh` (the latest
  meshes).
* `openfoam_case/0.orig/`, `system/`, `constant/`.
* `amr_pipeline.input`.

The pipeline regenerates everything else from these on a fresh run.

---

## When to suspect the pipeline vs. the solver

If the pipeline produces a mesh you don't like:

* **Wrong region refined?** Check `gradient_field` and `mfp_column`. They
  must agree.
* **Refinement not sharp enough?** Increase `sizing_scale`.
* **Cells too small somewhere?** Increase `sizing_min`.

If the solver crashes during the AMR mesh:

* **At very low cell counts?** Probably a mesh-quality problem; bump
  `sizing_min`.
* **At very high cell counts?** Might be a solver Courant-number issue;
  reduce `maxCo` in `controlDict`.

If `final.py` fails:

* **Empty CSV?** PVD/VTU chain is broken — check what `foamToVTK` wrote.
* **Missing column?** Field-name mismatch in `gradient_field`.

If neither side seems wrong but results don't converge:

* You may be in a regime where the chosen scalar field is the wrong
  refinement criterion. Try `rho` instead of `p`, or vice versa.

---

## Getting help

If after going through this list you're still stuck:

1. Re-read [TUTORIAL.md](TUTORIAL.md) and verify your case is set up the
   same way as the Mach 3 example.
2. Run with the bundled example unmodified. If that works, your custom
   setup is the issue. If it doesn't, the install is the issue.
3. Open an issue at
   [github.com/Fahim-bd/AMR-Pipeline/issues](https://github.com/Fahim-bd/AMR-Pipeline/issues)
   with the full `amr_pipeline.input`, the last 100 lines of the relevant
   log, and the Gmsh / ParaView / OpenFOAM versions you're using.
