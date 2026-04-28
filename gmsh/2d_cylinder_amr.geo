SetFactory("OpenCASCADE");
Rectangle(1) = {0, 0, 0, 1, 0.8};
Disk(2) = {0.5, 0.4, 0, 0.1};
BooleanDifference(3) = { Surface{1}; Delete; }{ Surface{2}; Delete; };

Merge "mfp.pos";
Field[1] = PostView;
Field[1].ViewTag = 1;
Mesh.MeshSizeFromPoints = 0;
Mesh.MeshSizeFromCurvature = 0;
Mesh.MeshSizeExtendFromBoundary = 0;
Mesh.CharacteristicLengthMin = 0.002;
Mesh.CharacteristicLengthMax = 0.015;
Background Field = 1;
Mesh 2;

out[] = Extrude {0, 0, 0.01} { Surface{3}; Layers{1}; Recombine; };

Physical Surface("inlet")        = {5};
Physical Surface("outlet")       = {4, 6, 7};
Physical Surface("wall")         = {8};
Physical Surface("frontAndBack") = {3, 9};
Physical Volume("internalMesh")  = {out[1]};

Mesh.MshFileVersion = 2.2;
