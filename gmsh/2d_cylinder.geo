// 2D cylinder in a rectangular domain — coarse (initial) mesh.
//
// This file is the geometry input for iteration 1 of the AMR pipeline.
// It produces a baseline mesh with characteristic length 0.005..0.02 m,
// no AMR sizing field, no PostView.
//
// The same geometry must be repeated in 2d_cylinder_amr.geo (for iterations
// 2..N) — the only difference there is that the AMR file reads mfp.pos as
// a Background Field and uses it to drive Gmsh's sizing.
//
// Domain:   1.0 m wide, 0.8 m tall rectangle
// Cylinder: r = 0.1 m centered at (0.5, 0.4)
// Extruded one cell in z (OpenFOAM "2D" requires a 3D mesh with empty
// front/back patches).

SetFactory("OpenCASCADE");

// Build the geometry: rectangle minus a disk.
Rectangle(1) = {0, 0, 0, 1, 0.8};         // x0, y0, z0, dx, dy
Disk(2)      = {0.5, 0.4, 0, 0.1};        // x_c, y_c, z_c, radius
BooleanDifference(3) = { Surface{1}; Delete; }{ Surface{2}; Delete; };

// Extrude one layer in z to make a 3D mesh that OpenFOAM can read.
// The single layer + Recombine gives prism cells aligned with z.
out[] = Extrude {0, 0, 0.01} { Surface{3}; Layers{1}; Recombine; };

// Patch tagging. Surface IDs verified by BoundingBox after extrusion:
//   3 = front face (z = 0)
//   9 = back face  (z = 0.01)
//   4 = bottom     (y = 0)
//   5 = left       (x = 0)
//   6 = right      (x = 1)
//   7 = top        (y = 0.8)
//   8 = cylinder
Physical Surface("inlet")        = {5};        // free-stream inflow on the left
Physical Surface("outlet")       = {4, 6, 7};  // open boundaries on bottom, right, top
Physical Surface("wall")         = {8};        // cylinder surface
Physical Surface("frontAndBack") = {3, 9};     // front and back (will be tagged "empty" in OpenFOAM)
Physical Volume("internalMesh")  = {out[1]};

// Mesh sizing for the coarse iteration. AMR replaces this on later loops
// via the .pos background field defined in 2d_cylinder_amr.geo.
Mesh.CharacteristicLengthMin = 0.005;
Mesh.CharacteristicLengthMax = 0.02;

// OpenFOAM's gmshToFoam (as of v2406) does not handle Gmsh v4 .msh files
// reliably. Force the v2.2 ASCII format.
Mesh.MshFileVersion = 2.2;

Mesh 3;
