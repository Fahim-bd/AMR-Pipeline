# Examples

Three pre-configured cases that exercise different parts of the pipeline.
Each subdirectory contains everything needed to reproduce that case: an
`amr_pipeline.input`, the `.geo` files, the OpenFOAM `0.orig`/`system`/
`constant` directories where applicable, and a short `README.md` explaining
what the case demonstrates.

| Case | Solver | Extraction mode | What it shows |
|------|--------|-----------------|---------------|
| `mach3_cylinder/` | OpenFOAM rhoCentralFoam | gradient (p) | Strong shock, supersonic external flow. The bundled tutorial case. |
| `subsonic_cylinder/` | OpenFOAM rhoCentralFoam | gradient (rho) | Mach 0.5 case, weaker gradients, demonstrates that gradient AMR works at modest compressibility. Useful as a sanity check. |
| `comet_dsmc_psi/` | COMET DSMC | direct (mean free path) | Plume-surface interaction problem at high Knudsen number. Requires the in-house COMET solver. |

To run any of them, copy its contents up into the repository root, edit the
binary paths in `amr_pipeline.input`, and run `./all_run.sh`.

```bash
# example: run the subsonic cylinder
cp -r examples/subsonic_cylinder/* .
$EDITOR amr_pipeline.input
./all_run.sh
```

The `mach3_cylinder/` files are identical to what is at the repository root
by default — that is, the tutorial case is already loaded.
