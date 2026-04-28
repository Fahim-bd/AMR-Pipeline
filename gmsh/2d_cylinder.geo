SetFactory("OpenCASCADE");
Rectangle(1) = {0, 0, 0, 1, 0.8};
Disk(2) = {0.5, 0.4, 0, 0.1};
BooleanDifference(3) = { Surface{1}; Delete; }{ Surface{2}; Delete; };

out[] = Extrude {0, 0, 0.01} { Surface{3}; Layers{1}; Recombine; };

// Surface mapping (verified by BoundingBox):
// 3=front(z=0), 9=back(z=0.01), 4=bottom(y=0), 5=left(x=0), 6=right(x=1), 7=top(y=0.8), 8=cylinder
Physical Surface("inlet")        = {5};        // left wall
Physical Surface("outlet")       = {4, 6, 7};  // bottom, right, top
Physical Surface("wall")         = {8};        // cylinder
Physical Surface("frontAndBack") = {3, 9};     // front and back
Physical Volume("internalMesh")  = {out[1]};

Mesh.CharacteristicLengthMin = 0.005;
Mesh.CharacteristicLengthMax = 0.02;
Mesh.MshFileVersion = 2.2;
Mesh 3;
