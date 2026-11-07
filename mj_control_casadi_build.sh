#!/usr/bin/env bash
# Build this CasADi fork (CUDA codegen) and the Pinocchio CasADi binding for the mj_control codegen environment.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MJ_CONTROL_ROOT="${MJ_CONTROL_ROOT:-/home/frlab/mj_control}"
CASADI_ENV="${CASADI_ENV:-/home/frlab/.venvs/mj_control}"
CASADI_ARTIFACT_ROOT="${CASADI_ARTIFACT_ROOT:-/home/frlab/.local/share/mj-control-casadi}"
CUDA_ROOT="${CUDA_ROOT:-/usr/local/cuda-13.4}"
CUDA_ARCH="${CUDA_ARCH:-120}"
CASADI_JOBS="${CASADI_JOBS:-8}"
PINOCCHIO_JOBS="${PINOCCHIO_JOBS:-4}"
PYTHON_MINOR=14
pin_revision=2ae77666e894a39127b283dcce3e2399ec19242d
revision="$(git -C "$repo_dir" rev-parse HEAD)"
short_revision="${revision:0:9}"
casadi_base="$(sed -nE 's/^set\(CASADI_(MAJOR|MINOR|PATCH)_VERSION ([0-9]+)\)/\2/p' "$repo_dir/CMakeLists.txt" | paste -sd.)"
casadi_version="$casadi_base.post0+cuda.$short_revision"
pin_version="4.1.0+ca$short_revision"
builds="$CASADI_ARTIFACT_ROOT/builds"
wheels="$CASADI_ARTIFACT_ROOT/wheels"
python="$CASADI_ENV/bin/python"
export PYTHONDONTWRITEBYTECODE=1

usage() {
    cat <<'TEXT'
Usage: bash mj_control_casadi_build.sh COMMAND
  tools    Install build tools into the existing mj_control environment.
  build    Build this CasADi commit and the Pinocchio CasADi binding as CPython 3.14 wheels.
  verify   Import pinocchio.casadi and compile a generated CUDA kernel with nvcc.
Paths, CUDA settings and job counts are documented in MJ_CONTROL_CASADI.md.
TEXT
}

run_logged() {
    local log_name="$1"
    shift
    if ! nice -n 10 "$@" > "$builds/$log_name.log" 2>&1; then
        tail -n 60 "$builds/$log_name.log" >&2
        return 1
    fi
}

require_environment() {
    if [[ ! -x "$python" ]]; then
        printf 'Missing environment: %s. Create it with uv sync in %s first.\n' "$CASADI_ENV" "$MJ_CONTROL_ROOT" >&2
        exit 1
    fi
    export PATH="$CASADI_ENV/bin:$PATH"
    mkdir -p "$builds" "$wheels"
    "$python" -c "import sys; assert sys.version_info[:2] == (3, $PYTHON_MINOR), sys.version"
}

prepare_sources() {
    local source="$builds/casadi-source"
    if [[ ! -e "$source" ]]; then
        git -C "$repo_dir" worktree add --detach "$source" "$revision"
    elif [[ "$(git -C "$source" rev-parse HEAD)" != "$revision" ]]; then
        if [[ -n "$(git -C "$source" status --porcelain)" ]]; then
            printf 'Preserve changes in %s before rebuilding.\n' "$source" >&2
            exit 1
        fi
        git -C "$source" checkout --detach "$revision"
    fi
    # CasADi reads annotated git-describe tags for its runtime version string; the tag stays local.
    if git -C "$repo_dir" rev-parse --verify "refs/tags/$casadi_version" >/dev/null 2>&1; then
        [[ "$(git -C "$repo_dir" rev-list -n 1 "$casadi_version")" == "$revision" ]]
    else
        git -C "$repo_dir" tag -a "$casadi_version" "$revision" -m "Local CUDA build $revision"
    fi
    if [[ ! -e "$builds/pinocchio-source" ]]; then
        git clone --filter=blob:none https://github.com/stack-of-tasks/pinocchio.git "$builds/pinocchio-source"
        git -C "$builds/pinocchio-source" checkout --detach "$pin_revision"
    fi
    [[ "$(git -C "$builds/pinocchio-source" rev-parse HEAD)" == "$pin_revision" ]]
    git -C "$builds/pinocchio-source" submodule update --init --recursive -- cmake
}

case "${1:-help}" in
    help|--help|-h) usage; exit 0 ;;
    tools)
        require_environment
        uv pip install --python "$python" \
            cmeel-eigen==3.4.1 cmeel-urdfdom-headers==3.0.0 jrl-cmakemodules==2.1.0 \
            swig==4.5.0 ninja==1.13.2 wheel==0.48.0 patchelf==0.19.1.0
        ;;
    build)
        require_environment
        prepare_sources
        run_logged casadi-configure cmake -S "$builds/casadi-source" -B "$builds/casadi-build" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_MAKE_PROGRAM="$CASADI_ENV/bin/ninja" \
            -DPYTHON_EXECUTABLE="$python" -DSWIG_EXECUTABLE="$CASADI_ENV/bin/swig" \
            -DWITH_PYTHON=ON -DWITH_SELFCONTAINED=ON -DWITH_EXAMPLES=OFF \
            -DCASADI_PYTHON_PIP_METADATA_INSTALL=OFF -DPYTHON_PREFIX= \
            -DCMAKE_INSTALL_PREFIX="$builds/casadi-stage"
        run_logged casadi-build cmake --build "$builds/casadi-build" --parallel "$CASADI_JOBS"
        run_logged casadi-install cmake --install "$builds/casadi-build"
        "$python" "$repo_dir/generalist_casadi_package.py" "$builds/casadi-stage" casadi "$casadi_version" \
            --output-dir "$wheels" --requires numpy --python-minor "$PYTHON_MINOR"
        uv pip install --python "$python" --no-deps --reinstall \
            "$wheels/casadi-$casadi_version-cp3$PYTHON_MINOR-cp3$PYTHON_MINOR-linux_x86_64.whl"

        prefix="$("$python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
        run_logged pinocchio-configure cmake -S "$builds/pinocchio-source" -B "$builds/pinocchio-build" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_MAKE_PROGRAM="$CASADI_ENV/bin/ninja" \
            -DPYTHON_EXECUTABLE="$python" -DCMAKE_PREFIX_PATH="$prefix/cmeel.prefix;$prefix/casadi" \
            -DBUILD_WITH_CASADI_SUPPORT=ON -DBUILD_PYTHON_INTERFACE=ON \
            -DBUILD_WITH_URDF_SUPPORT=ON -DBUILD_WITH_COLLISION_SUPPORT=ON -DBUILD_WITH_OPENMP_SUPPORT=ON \
            -DENABLE_TEMPLATE_INSTANTIATION=OFF -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF \
            -DBUILD_BENCHMARK=OFF -DPINOCCHIO_BUILD_BINDING_WITH_PCH=ON \
            -DCMAKE_INSTALL_PREFIX="$builds/pinocchio-stage"
        run_logged pinocchio-build cmake --build "$builds/pinocchio-build" \
            --target pinocchio_pywrap_casadi --parallel "$PINOCCHIO_JOBS"
        pin_stage="$builds/cpin-stage/cmeel.prefix/lib/python3.$PYTHON_MINOR/site-packages/pinocchio"
        mkdir -p "$pin_stage/casadi"
        cp "$builds/pinocchio-source/bindings/python/pinocchio/casadi/__init__.py" "$pin_stage/casadi/"
        pin_module="pinocchio_pywrap_casadi.cpython-3$PYTHON_MINOR-x86_64-linux-gnu.so"
        cp "$builds/pinocchio-build/bindings/python/pinocchio/$pin_module" "$pin_stage/$pin_module"
        patchelf --set-rpath '$ORIGIN/../../..:$ORIGIN/../../../../../casadi' "$pin_stage/$pin_module"
        patchelf --replace-needed libpinocchio_parsers.so.4.1.0 libpinocchio_parsers.so "$pin_stage/$pin_module"
        "$python" "$repo_dir/generalist_casadi_package.py" "$builds/cpin-stage" pinocchio-casadi "$pin_version" \
            --output-dir "$wheels" --requires pin==4.1.0 --requires "casadi==$casadi_version" \
            --requires eigenpy==3.13.0 --requires cmeel-boost==1.90.0 --python-minor "$PYTHON_MINOR"
        uv pip install --python "$python" --no-deps --reinstall \
            "$wheels/pinocchio_casadi-$pin_version-cp3$PYTHON_MINOR-cp3$PYTHON_MINOR-linux_x86_64.whl"
        printf '%s\n%s\n' "$wheels/casadi-$casadi_version-cp3$PYTHON_MINOR-cp3$PYTHON_MINOR-linux_x86_64.whl" \
            "$wheels/pinocchio_casadi-$pin_version-cp3$PYTHON_MINOR-cp3$PYTHON_MINOR-linux_x86_64.whl"
        ;;
    verify)
        require_environment
        "$python" "$repo_dir/mj_control_casadi_verify.py" --output-dir "$builds/verify" \
            --nvcc "$CUDA_ROOT/bin/nvcc" --cuda-arch "$CUDA_ARCH"
        ;;
    *) usage >&2; exit 2 ;;
esac
