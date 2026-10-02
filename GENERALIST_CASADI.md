# Separate Generalist + CasADi environment

The files at this fork's root record the 2026-10-02 build and provide the same
build procedure with configurable paths. They target Linux x86_64, CPython 3.12,
GCC 13, CUDA Toolkit 13.4 and an RTX 5080 (`sm_120`). All build products and the
environment live outside the CasADi, Generalist and skills checkouts.

## Recorded build

| Component | Validated version / source |
| --- | --- |
| Python | 3.12.14 |
| CasADi | 3.8.1.post0+cuda.7217fce9a, upstream `e4e57a094` plus the CUDA patch |
| Pinocchio | 4.1.0, source `2ae77666e894a39127b283dcce3e2399ec19242d` |
| Pinocchio CasADi binding | Source-built `pinocchio_pywrap_casadi` supplement to the official `pin` wheel |
| casadi-on-gpu | `6c4481abca4e58522d7f3d0c1c4c1a62b307b8bb`, G1-specific generated registry |
| Generalist | MJLab 1.6.0, PyTorch 2.14.0+cu130, RSL-RL 5.5.1 |

`generalist-casadi.pyproject.toml` and `generalist-casadi.uv.lock` are exact
snapshots of the installed environment project. Their absolute editable paths
and local wheel paths describe the original machine. The build script relocates
these paths and refreshes the local wheel entries for the commit being built.
`generalist-casadi-build-record.json` records the original versions, wheel hashes
and verification outcomes. Its `7217fce9a` revision identifies the compiled build
before the root build files were added to the same downstream commit; adding
these files does not change the compiled CasADi runtime source.

Validated: 15 focused tests and 481 subtests, native-to-CasADi G1 model conversion,
Generalist CLI import, and a four-lane G1 CoM CUDA probe with maximum CPU/GPU
absolute error `3.0223506711224424e-08`. The complete 19-output G1 CUDA module was
generated, compiled and imported. Its numerical GPU check remains unverified:
`cudaDeviceSetLimit(cudaLimitStackSize)` returned out-of-memory while an existing
Generalist training process occupied most of the GPU memory.

The existing Generalist environment and skills runtime/generated sources were
preserved. No MuJoCo-to-Pinocchio integration was added. Generalist's existing
environment-level RSL-RL 5.5.1 override is carried over; MJLab declares 5.4.2, so
`uv pip check` reports that intentional mismatch.

## Use the installed environment

```bash
source /home/frlab/.venvs/generalist-casadi/bin/activate
cd /home/frlab/Generalist-mjlab
python scripts/train.py --help
```

The separate project's `pyproject.toml` and `uv.lock` are stored under
`/home/frlab/.local/share/generalist-casadi/environment`. Synchronize that project
to retain the source-built packages:

```bash
UV_PROJECT_ENVIRONMENT=/home/frlab/.venvs/generalist-casadi \
  uv sync --locked --all-groups \
  --project /home/frlab/.local/share/generalist-casadi/environment
```

## Reproduce the build

Required host tools: `git`, `uv`, CMake 3.28 or newer, GCC/G++ 13 and CUDA Toolkit
13.4. The Generalist and skills repositories must be available locally. The
bootstrap command creates a fresh environment from Generalist's locked base;
the build command adds the three source-built wheels and writes the separate
project lock. For an existing environment, start with `build`.

```bash
bash generalist_casadi_build.sh bootstrap
bash generalist_casadi_build.sh build
bash generalist_casadi_build.sh verify
bash generalist_casadi_build.sh verify-com
```

Run the full CUDA comparison once GPU memory is available:

```bash
bash generalist_casadi_build.sh verify-gpu
```

| Variable | Default |
| --- | --- |
| `GENERALIST_ROOT` | `/home/frlab/Generalist-mjlab` |
| `SKILLS_ROOT` | `/home/frlab/skills` |
| `CASADI_ENV` | `/home/frlab/.venvs/generalist-casadi` |
| `CASADI_ARTIFACT_ROOT` | `/home/frlab/.local/share/generalist-casadi` |
| `COG_SOURCE` | `/home/frlab/reference/casadi-on-gpu` |
| `CUDA_ROOT` | `/usr/local/cuda-13.4` |
| `CUDA_ARCH` | `120` |
| `CASADI_BUILD_JOBS` | `2` |

Use absolute paths when overriding the path variables.

The build uses `nice -n 10` and two jobs by default. CasADi is built with its
Python interface and self-contained install. A local annotated version tag
allows upstream's `git describe` logic to report the correct CUDA build version;
the script does not push tags or create branches.

Pinocchio uses `BUILD_WITH_CASADI_SUPPORT=ON`, collision and URDF support,
`ENABLE_TEMPLATE_INSTANTIATION=OFF`, and the `pinocchio_pywrap_casadi` target.
Only its CasADi extension and `casadi/__init__.py` are packaged. The extension's
RUNPATH is set to `$ORIGIN/../../..:$ORIGIN/../../../../../casadi`, and its parser
dependency is changed from `libpinocchio_parsers.so.4.1.0` to the official wheel's
`libpinocchio_parsers.so`. Native Pinocchio, Boost and EigenPy remain the locked
official wheel dependencies.

G1 CUDA code is freshly emitted from the skills repository's frozen serialized
function, without modifying that graph or its generated files. Registry workspace
sizes are taken from emitted CUDA header macros, because CUDA's workspace may
differ from the serialized CPU function. The CoM probe is built separately and
does not replace the installed 19-output registry. The helpers extend the local
`package_artifact.py`, `normalize_cog_registry.py` and `verify_cuda_runtime.py`
used during the original build by accepting paths as arguments.

The snapshot lock includes hashes for the original wheels; rebuilt wheels have
new hashes, so `generalist_casadi_environment.py` regenerates their lock entries.
Wheel files, generated native sources, CMake caches and build logs remain under
`CASADI_ARTIFACT_ROOT`, outside Git. The original verification record is retained
and subsequent checks write `builds/recipe-*-verification.json`.

## Preserved history

The removed branches are backed up on the original machine in
`/home/frlab/.local/share/generalist-casadi/backups/`:

- `casadi-pre-sync-2026-10-02.bundle`
- `casadi-before-branch-cleanup-2026-10-02.bundle`
- `cuda-codegen-3.8.0.patch`

The second bundle contains the complete pre-cleanup local branch history. The
remote and local working repository retain only `main`.
