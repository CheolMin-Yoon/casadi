#!/usr/bin/env bash
# Reproduce the separate Generalist/CasADi/Pinocchio build documented alongside this file.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GENERALIST_ROOT="${GENERALIST_ROOT:-/home/frlab/Generalist-mjlab}"
SKILLS_ROOT="${SKILLS_ROOT:-/home/frlab/skills}"
CASADI_ENV="${CASADI_ENV:-/home/frlab/.venvs/generalist-casadi}"
CASADI_ARTIFACT_ROOT="${CASADI_ARTIFACT_ROOT:-/home/frlab/.local/share/generalist-casadi}"
COG_SOURCE="${COG_SOURCE:-/home/frlab/reference/casadi-on-gpu}"
CUDA_ROOT="${CUDA_ROOT:-/usr/local/cuda-13.4}"
CUDA_ARCH="${CUDA_ARCH:-120}"
CASADI_BUILD_JOBS="${CASADI_BUILD_JOBS:-2}"
pin_revision=2ae77666e894a39127b283dcce3e2399ec19242d
cog_revision=6c4481abca4e58522d7f3d0c1c4c1a62b307b8bb
revision="$(git -C "$repo_dir" rev-parse HEAD)"
short_revision="${revision:0:9}"
casadi_version="3.8.1.post0+cuda.$short_revision"
pin_version="4.1.0+ca$short_revision"
cog_version="0.1.0+g1.ca$short_revision"
builds="$CASADI_ARTIFACT_ROOT/builds"
wheels="$CASADI_ARTIFACT_ROOT/wheels"
python="$CASADI_ENV/bin/python"
export UV_PROJECT_ENVIRONMENT="$CASADI_ENV"
export PYTHONDONTWRITEBYTECODE=1

usage() {
    cat <<'TEXT'
Usage: bash generalist_casadi_build.sh COMMAND
  bootstrap   Create a NEW separate environment from the Generalist lock and install build tools.
  build       Build this CasADi commit, Pinocchio CasADi bindings and the G1 CUDA runtime; lock/install them.
  lock        Refresh the separate environment project for already built wheels.
  verify      Check imports, native/symbolic physical terms and the Generalist CLI without CUDA allocation.
  verify-com  Build/run the small G1 CoM CUDA probe against its CPU graph.
  verify-gpu  Run all 19 G1 CUDA outputs against their CPU graph (requires free GPU memory).
Paths, CUDA architecture and build parallelism can be overridden with the variables documented in GENERALIST_CASADI.md.
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
        printf 'Missing environment: %s. Run bootstrap first.\n' "$CASADI_ENV" >&2
        exit 1
    fi
    export PATH="$CASADI_ENV/bin:$PATH"
    mkdir -p "$builds" "$wheels"
    "$python" -c 'import sys; assert sys.version_info[:2] == (3, 12), sys.version'
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
    # CasADi reads annotated git-describe tags when generating runtime metadata.
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
    if [[ ! -e "$COG_SOURCE" ]]; then
        git clone --filter=blob:none https://github.com/edxmorgan/casadi-on-gpu.git "$COG_SOURCE"
        git -C "$COG_SOURCE" checkout --detach "$cog_revision"
    fi
    [[ "$(git -C "$COG_SOURCE" rev-parse HEAD)" == "$cog_revision" ]]
}

configure_cog() {
    local kind="$1"
    local stage="$builds/$kind-cog-stage"
    mkdir -p "$stage"
    run_logged "$kind-cog-configure" cmake -S "$builds/$kind-cog-source" -B "$builds/$kind-cog-build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_MAKE_PROGRAM="$CASADI_ENV/bin/ninja" \
        -DPython3_EXECUTABLE="$python" -Dpybind11_DIR="$("$python" -m pybind11 --cmakedir)" \
        -DCMAKE_CUDA_COMPILER="$CUDA_ROOT/bin/nvcc" -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
        -DCMAKE_INSTALL_PREFIX="$stage" -DPYTHON_INSTALL_DIR="$stage"
    run_logged "$kind-cog-build" cmake --build "$builds/$kind-cog-build" --parallel "$CASADI_BUILD_JOBS"
}

lock_environment() {
    "$python" "$repo_dir/generalist_casadi_environment.py" \
        --skills-root "$SKILLS_ROOT" --artifact-root "$CASADI_ARTIFACT_ROOT" --revision "$revision"
}

case "${1:-help}" in
    help|--help|-h) usage; exit 0 ;;
    bootstrap)
        # This command is for a new environment: it must not prune an existing one.
        if [[ -e "$CASADI_ENV" ]]; then
            printf 'Environment already exists: %s. Use build/verify, or choose another CASADI_ENV.\n' "$CASADI_ENV" >&2
            exit 1
        fi
        uv venv --python 3.12 "$CASADI_ENV"
        uv sync --locked --group dev --project "$GENERALIST_ROOT"
        uv pip install --python "$python" --constraint "$repo_dir/generalist-casadi-base-constraints.txt" \
            pin==4.1.0 libpinocchio==4.1.0 eigenpy==3.13.0 cmeel-boost==1.90.0 \
            coal==3.0.3 libcoal==3.0.3 cmeel-urdfdom==6.0.0 cmeel-tinyxml2==11.0.0 \
            cmeel-eigen==3.4.1 cmeel-urdfdom-headers==3.0.0 jrl-cmakemodules==2.1.0 \
            swig==4.5.0 ninja==1.13.2 pybind11==3.1.0 wheel==0.48.0 scikit-build-core==1.1.0 \
            patchelf==0.19.1.0 pyright==1.1.414
        uv pip install --python "$python" --no-deps --editable "$SKILLS_ROOT/casadi_skills"
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
        run_logged casadi-build cmake --build "$builds/casadi-build" --parallel "$CASADI_BUILD_JOBS"
        run_logged casadi-install cmake --install "$builds/casadi-build"
        "$python" "$repo_dir/generalist_casadi_package.py" "$builds/casadi-stage" casadi "$casadi_version" \
            --output-dir "$wheels" --requires numpy
        uv pip install --python "$python" --no-deps --reinstall "$wheels/casadi-$casadi_version-cp312-cp312-linux_x86_64.whl"

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
            --target pinocchio_pywrap_casadi --parallel "$CASADI_BUILD_JOBS"
        pin_stage="$builds/cpin-stage/cmeel.prefix/lib/python3.12/site-packages/pinocchio"
        mkdir -p "$pin_stage/casadi"
        cp "$builds/pinocchio-source/bindings/python/pinocchio/casadi/__init__.py" "$pin_stage/casadi/"
        pin_module=pinocchio_pywrap_casadi.cpython-312-x86_64-linux-gnu.so
        cp "$builds/pinocchio-build/bindings/python/pinocchio/$pin_module" "$pin_stage/$pin_module"
        patchelf --set-rpath '$ORIGIN/../../..:$ORIGIN/../../../../../casadi' "$pin_stage/$pin_module"
        patchelf --replace-needed libpinocchio_parsers.so.4.1.0 libpinocchio_parsers.so "$pin_stage/$pin_module"
        "$python" "$repo_dir/generalist_casadi_package.py" "$builds/cpin-stage" pinocchio-casadi "$pin_version" \
            --output-dir "$wheels" --requires pin==4.1.0 --requires "casadi==$casadi_version" \
            --requires eigenpy==3.13.0 --requires cmeel-boost==1.90.0
        uv pip install --python "$python" --no-deps --reinstall \
            "$wheels/pinocchio_casadi-$pin_version-cp312-cp312-linux_x86_64.whl"

        "$python" "$repo_dir/generalist_casadi_codegen.py" --cog-source "$COG_SOURCE" \
            --skills-root "$SKILLS_ROOT" --output "$builds/g1-cog-source"
        configure_cog g1
        run_logged g1-cog-install cmake --install "$builds/g1-cog-build"
        "$python" "$repo_dir/generalist_casadi_package.py" "$builds/g1-cog-stage" casadi-on-gpu "$cog_version" \
            --output-dir "$wheels" --requires torch==2.14.0+cu130
        uv pip install --python "$python" --no-deps --reinstall \
            "$wheels/casadi_on_gpu-$cog_version-cp312-cp312-linux_x86_64.whl"
        lock_environment
        ;;
    lock) require_environment; lock_environment ;;
    verify)
        require_environment
        "$python" "$repo_dir/generalist_casadi_verify.py" --mode cpu \
            --skills-root "$SKILLS_ROOT" --artifact-root "$CASADI_ARTIFACT_ROOT"
        (
            cd "$SKILLS_ROOT/casadi_skills"
            nice -n 10 "$python" -m pytest -q -p no:cacheprovider tests/test_g1_model_profile.py \
                tests/test_whole_body_native_pinocchio_oracle.py tests/test_robot_whole_body.py tests/test_evaluator_runtime.py
        )
        (cd "$GENERALIST_ROOT"; "$python" scripts/train.py --help > "$builds/generalist-help.log")
        ;;
    verify-com)
        require_environment
        "$python" "$repo_dir/generalist_casadi_codegen.py" --cog-source "$COG_SOURCE" \
            --skills-root "$SKILLS_ROOT" --output "$builds/com-cog-source" --com-only
        configure_cog com
        PYTHONPATH="$builds/com-cog-build${PYTHONPATH:+:$PYTHONPATH}" \
            "$python" "$repo_dir/generalist_casadi_verify.py" --mode com \
            --skills-root "$SKILLS_ROOT" --artifact-root "$CASADI_ARTIFACT_ROOT"
        ;;
    verify-gpu)
        require_environment
        "$python" "$repo_dir/generalist_casadi_verify.py" --mode g1 \
            --skills-root "$SKILLS_ROOT" --artifact-root "$CASADI_ARTIFACT_ROOT"
        ;;
    *) usage >&2; exit 2 ;;
esac
