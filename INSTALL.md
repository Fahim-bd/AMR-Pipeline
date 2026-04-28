# Installation

This page walks through everything I had to set up to run the pipeline on a
fresh Linux machine. It is the procedure I followed on CentOS Stream 9 with
GCC 11.5; I have noted where Ubuntu/Debian commands differ.

The pipeline itself is just a handful of bash and Python scripts and has no
build step. Almost all of the work below is installing the three external
tools it talks to: Gmsh, ParaView, and OpenFOAM.

If you already have these installed and on your `$PATH`, skip ahead to
[Verifying the install](#verifying-the-install).

---

## What you need

| Tool         | Version I tested | Why we need it                    |
|--------------|------------------|-----------------------------------|
| Linux        | CentOS Stream 9 / Ubuntu 22.04 | Host OS                |
| GCC + g++    | 11.5             | Building OpenFOAM (skip if using a prebuilt OpenFOAM) |
| Bash         | 4.4+             | The orchestrator                  |
| Python       | 3.9+             | A tiny boundary-fix script        |
| Gmsh         | 4.11.1           | Mesh generation                   |
| ParaView     | 5.13.2 (MPI build) | `pvpython` for field extraction |
| OpenFOAM     | v2406            | One of the demonstrated solvers   |

All four of Gmsh, ParaView, OpenFOAM and the pipeline expect a 64-bit Linux
host. macOS may work for the pipeline scripts in isolation but I have not
tested any of the tools on it.

---

## 1. System packages

### CentOS Stream / RHEL 9

```bash
sudo dnf install -y \
    git make cmake gcc gcc-c++ gcc-gfortran \
    flex bison \
    boost-devel \
    fftw-devel \
    readline-devel ncurses-devel \
    zlib-devel libxml2-devel \
    openmpi openmpi-devel \
    python3 python3-pip
```

Then enable OpenMPI on your shell:

```bash
module load mpi/openmpi-x86_64
# or, if you don't use modules:
export PATH=/usr/lib64/openmpi/bin:$PATH
export LD_LIBRARY_PATH=/usr/lib64/openmpi/lib:$LD_LIBRARY_PATH
```

### Ubuntu 22.04 / Debian 12

```bash
sudo apt-get update
sudo apt-get install -y \
    git make cmake build-essential gfortran \
    flex bison \
    libboost-system-dev libboost-thread-dev \
    libfftw3-dev \
    libreadline-dev libncurses-dev \
    zlib1g-dev libxml2-dev \
    libopenmpi-dev openmpi-bin \
    python3 python3-pip
```

OpenMPI is on the path by default after `apt-get install openmpi-bin`.

---

## 2. Gmsh (binary download)

Gmsh ships precompiled. There is no reason to build from source.

```bash
mkdir -p ~/gmsh && cd ~/gmsh
wget https://gmsh.info/bin/Linux/gmsh-4.11.1-Linux64.tgz
tar -xzf gmsh-4.11.1-Linux64.tgz
```

Add it to your shell:

```bash
echo 'export PATH=$HOME/gmsh/gmsh-4.11.1-Linux64/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

Sanity check:

```bash
gmsh --version
# expected: 4.11.1
```

---

## 3. ParaView (binary download — **MPI build required**)

The pipeline calls `pvpython` from ParaView. **You need the MPI build**, not
the OSMesa/EGL one — `pvpython` from the OSMesa build is missing some of the
filters `final.py` uses.

```bash
mkdir -p ~/paraview && cd ~/paraview
wget "https://www.paraview.org/files/v5.13/ParaView-5.13.2-MPI-Linux-Python3.10-x86_64.tar.gz"
tar -xzf ParaView-5.13.2-MPI-Linux-Python3.10-x86_64.tar.gz
```

Add `pvpython` to your shell:

```bash
echo 'export PATH=$HOME/paraview/ParaView-5.13.2-MPI-Linux-Python3.10-x86_64/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

Sanity check:

```bash
pvpython --version
# expected: 5.13.2
pvpython -c "from paraview.simple import *; print('ok')"
# expected: ok
```

If the `from paraview.simple import` line fails with a missing-symbol error,
you most likely picked up the OSMesa build. Re-download the MPI variant.

---

## 4. OpenFOAM v2406 (build from source)

This is the slow part. Plan on roughly 60 minutes on 8 cores.

A precompiled OpenFOAM is available for some distributions, but I built from
source because the prebuilt rpm I tried was missing a few finite-area
libraries. The instructions below match what I actually did.

### 4.1 Download

```bash
mkdir -p ~/OpenFOAM && cd ~/OpenFOAM

# Source code
wget "https://dl.openfoam.com/source/v2406/OpenFOAM-v2406.tgz"
tar -xzf OpenFOAM-v2406.tgz

# Third-party (CGAL, ADIOS2, etc.)
wget "https://dl.openfoam.com/source/v2406/ThirdParty-v2406.tgz"
tar -xzf ThirdParty-v2406.tgz
```

After extraction you will have:

```
~/OpenFOAM/OpenFOAM-v2406/
~/OpenFOAM/ThirdParty-v2406/
```

### 4.2 Source the OpenFOAM environment

```bash
source ~/OpenFOAM/OpenFOAM-v2406/etc/bashrc
```

This sets `WM_PROJECT_DIR`, `FOAM_RUN`, and a long list of other OpenFOAM
variables. If it complains that `WM_COMPILER` is not set, your distribution's
default GCC is probably too old; explicitly set:

```bash
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
source ~/OpenFOAM/OpenFOAM-v2406/etc/bashrc
```

### 4.3 Build

```bash
cd ~/OpenFOAM/OpenFOAM-v2406
foamSystemCheck                # verifies prerequisites; fix anything it flags
./Allwmake -j 8 -s -q          # build, 8 cores, silent + quiet
```

The build takes about an hour on a modern desktop. Expect a few warnings;
they are normal. What matters at the end is that this works:

```bash
which rhoCentralFoam
# expected: /home/$USER/OpenFOAM/OpenFOAM-v2406/platforms/linux64GccDPInt32Opt/bin/rhoCentralFoam
```

### 4.4 Make the environment permanent

```bash
echo 'source $HOME/OpenFOAM/OpenFOAM-v2406/etc/bashrc' >> ~/.bashrc
source ~/.bashrc
```

You should now be able to type `which gmshToFoam`, `which foamToVTK`, and
`which rhoCentralFoam` in any new shell and get a real path back.

---

## 5. Python dependencies for the pipeline

The pipeline scripts use only Python's standard library. The boundary-fix
inline script in `run_openfoam.sh` and `run_openfoam_amr.sh` uses `re` and
`sys`, both stdlib. Nothing to `pip install`.

`pvpython` ships with its own Python (3.10 in the build I tested). The
pipeline does not import any extra packages into `pvpython`.

---

## Verifying the install

After everything is installed, run this short check from any directory:

```bash
echo "Bash: $(bash --version | head -1)"
echo "Python: $(python3 --version)"
echo "Gmsh:  $(gmsh --version 2>&1 | head -1)"
echo "pvpython: $(pvpython --version 2>&1 | head -1)"
echo "OpenFOAM solver: $(which rhoCentralFoam || echo 'NOT FOUND')"
echo "OpenFOAM utility: $(which gmshToFoam || echo 'NOT FOUND')"
```

Expected output (versions may differ):

```
Bash: GNU bash, version 5.1.8
Python: Python 3.9.18
Gmsh:  4.11.1
pvpython: paraview version 5.13.2
OpenFOAM solver: /home/fahim/OpenFOAM/OpenFOAM-v2406/platforms/linux64GccDPInt32Opt/bin/rhoCentralFoam
OpenFOAM utility: /home/fahim/OpenFOAM/OpenFOAM-v2406/platforms/linux64GccDPInt32Opt/bin/gmshToFoam
```

If any of those say "NOT FOUND", the corresponding tool is not on your
`$PATH` and the pipeline will fail with an explicit error in step 1 of
`all_run.sh`. Fix the path before continuing.

---

## Cloning the pipeline

```bash
cd ~
git clone https://github.com/Fahim-bd/AMR-Pipeline.git
cd AMR-Pipeline
```

Then open `amr_pipeline.input` and update the two binary paths to match your
machine:

```ini
gmsh_bin     = /home/YOUR_USER/gmsh/gmsh-4.11.1-Linux64/bin/gmsh
pvpython     = /home/YOUR_USER/paraview/ParaView-5.13.2-MPI-Linux-Python3.10-x86_64/bin/pvpython
foam_source  = /home/YOUR_USER/OpenFOAM/OpenFOAM-v2406/etc/bashrc
```

That is the only file you should need to edit.

To confirm everything wires up, run the pipeline with `--help`:

```bash
./all_run.sh --help
```

You should see a long usage summary. If instead you see `ERROR: gmsh binary
not executable`, fix the `gmsh_bin` path. If you see `pvpython not found`,
fix `pvpython`.

---

## Common install pitfalls

The full troubleshooting list lives in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
Three that come up most often during install:

1. **`paraview/simple.py` not found** — you have ParaView server but not the
   Python bindings, or you grabbed the OSMesa tarball. Re-download the MPI
   variant.
2. **`mpicc: command not found`** during OpenFOAM build — the OpenMPI module
   is not loaded. `module load mpi/openmpi-x86_64` (CentOS) or just install
   `openmpi-bin` (Ubuntu) and re-source the OpenFOAM bashrc.
3. **`WM_PROJECT_DIR is not set`** when sourcing the OpenFOAM bashrc — your
   shell's `BASH_SOURCE` is unset because you ran the file from `sh` instead
   of `bash`. Use `bash` explicitly.

Once `./all_run.sh --help` works, move on to the [tutorial](TUTORIAL.md).
