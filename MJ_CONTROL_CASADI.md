# mj_control CasADi codegen environment

`mj_control_casadi_build.sh` builds this fork's CUDA CodeGenerator and the Pinocchio CasADi binding
(`pinocchio.casadi`) into the existing `mj_control` uv environment. That environment is the
code-generation environment: it emits `.cu`/`.cuh` kernels and does not launch them, so
`casadi-on-gpu` and Generalist are not part of this recipe (see [GENERALIST_CASADI.md](GENERALIST_CASADI.md)
for the CPython 3.12 runtime recipe that does include them).

| Component | Source |
| --- | --- |
| Python | CPython 3.14 (`/home/frlab/.venvs/mj_control`) |
| CasADi | this fork's `HEAD`, packaged as `<upstream version>.post0+cuda.<short rev>` |
| Pinocchio CasADi binding | Pinocchio `2ae77666e894a39127b283dcce3e2399ec19242d` (4.1.0), target `pinocchio_pywrap_casadi`, added on top of the official `pin==4.1.0` wheel |
| CUDA | Toolkit 13.4, `sm_120` (RTX 5080) |

## Build

Required host tools: `git`, `uv`, CMake 3.28 or newer, GCC/G++ 13 and the CUDA toolkit. The
environment must already exist (`uv sync --active` in `mj_control`).

```bash
bash mj_control_casadi_build.sh tools    # swig, ninja, wheel, patchelf, Eigen/urdfdom headers, jrl-cmakemodules
bash mj_control_casadi_build.sh build    # CasADi wheel, then the Pinocchio CasADi wheel
bash mj_control_casadi_build.sh verify   # cpin round trip, cpin crba vs pin crba, CUDA kernel compiled by nvcc
```

| Variable | Default |
| --- | --- |
| `MJ_CONTROL_ROOT` | `/home/frlab/mj_control` |
| `CASADI_ENV` | `/home/frlab/.venvs/mj_control` |
| `CASADI_ARTIFACT_ROOT` | `/home/frlab/.local/share/mj-control-casadi` |
| `CUDA_ROOT` | `/usr/local/cuda-13.4` |
| `CUDA_ARCH` | `120` |
| `CASADI_JOBS` | `8` |
| `PINOCCHIO_JOBS` | `4` (the CasADi binding is memory heavy) |

Sources, build trees, logs and wheels live under `CASADI_ARTIFACT_ROOT`, outside Git. The
Pinocchio extension's RUNPATH points at the official wheel's `cmeel.prefix/lib` and the CasADi
package, and its parser dependency is renamed to the official `libpinocchio_parsers.so`, as in the
Generalist recipe. A local annotated tag `<version>` lets CasADi's `git describe` report the
build version; the script never pushes tags.

## Keep the wheels in the uv lock

`uv sync` removes packages that `mj_control/pyproject.toml` does not declare. The built wheels
are therefore declared there as path sources of the `codegen` dependency group; after a rebuild
at a new fork revision, update those two paths and run `uv lock`.
