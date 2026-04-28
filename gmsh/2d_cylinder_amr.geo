// 2D cylinder — AMR (refined) mesh.
//
// This file is the geometry input for iterations 2..N of the AMR pipeline.
// It is the same geometry as 2d_cylinder.geo, but instead of using a fixed
// characteristic-length range, it reads the per-point sizing field from
// mfp.pos (written by final.py at the end of the previous iteration) and
// uses that as a Gmsh "Background Field".
//
// On iteration 1 this file is NOT used — the orchestrator runs
// 2d_cylinder.geo first, since mfp.pos does not exist yet. Starting from
// iteration 2 the orchestrator runs this file each loop, after final.py
// has produced a fresh mfp.pos.

SetFactory("OpenCASCADE");

// Same geometry as 2d_cylinder.geo. If you change the domain or the
// cylinder there, change it here too — the two files MUST agree.
Rectangle(1) = {0, 0, 0, 1, 0.8};
Disk(2)      = {0.5, 0.4, 0, 0.1};
BooleanDifference(3) = { Surface{1}; Delete; }{ Surface{2}; Delete; };

// Load the AMR sizing field that final.py wrote at the end of the
// previous iteration. The file lives in the same directory as this .geo.
Merge "mfp.pos";
Field[1] = PostView;
Field[1].ViewTag = 1;

// Disable Gmsh's other sizing heuristics so they don't fight the
// background field. Without these three lines, Gmsh will mix curvature-
// based sizing with the .pos field and produce weird artefacts.
Mesh.MeshSizeFromPoints      = 0;
Mesh.MeshSizeFromCurvature   = 0;
Mesh.MeshSizeExtendFromBoundary = 0;

// Hard caps on the sizing field. Cells will not be smaller than min or
// larger than max regardless of what mfp.pos says. Set these consistent
// with sizing_min / sizing_max in amr_pipeline.input.
Mesh.CharacteristicLengthMin = 0.002;
Mesh.CharacteristicLengthMax = 0.015;

// Use the loaded PostView as the source of truth for cell size.
Background Field = 1;

Mesh 2;

// Same z-extrusion and patch tagging as the coarse mesh.
out[] = Extrude {0, 0, 0.01} { Surface{3}; Layers{1}; Recombine; };

Physical Surface("inlet")        = {5};
Physical Surface("outlet")       = {4, 6, 7};
Physical Surface("wall")         = {8};
Physical Surface("frontAndBack") = {3, 9};
Physical Volume("internalMesh")  = {out[1]};

// Force Gmsh v2.2 .msh format for OpenFOAM compatibility.
Mesh.MshFileVersion = 2.2;
