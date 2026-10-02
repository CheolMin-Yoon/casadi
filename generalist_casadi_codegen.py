"""Generate local G1 CUDA sources and normalize the emitted workspace registry."""

from __future__ import annotations

import argparse
import json
import os
import re
import runpy
import shutil
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cog-source", type=Path, required=True)
    parser.add_argument("--skills-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--com-only", action="store_true")
    args = parser.parse_args()
    source = args.cog_source.resolve()
    output = args.output.resolve()
    generated = output / "src/generated"
    generated.mkdir(parents=True, exist_ok=True)
    (output / "src/python").mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "CMakeLists.txt", output / "CMakeLists.txt")
    for path in (source / "src/python").iterdir():
        if path.is_file():
            shutil.copy2(path, output / "src/python" / path.name)

    robot_root = args.skills_root.resolve() / "casadi_skills/casadi_skills/robots/g1"
    config = json.loads((robot_root / "config/codegen.json").read_text())
    function_path = robot_root / config["function_file"]
    cuda = config["cuda"]
    if args.com_only:
        import casadi as ca

        original = ca.Function.load(str(function_path))
        q = ca.SX.sym("configuration", original.size1_in(0))
        zero = ca.SX.zeros(original.size1_in(1))
        outputs = original(configuration=q, generalized_velocity=zero, generalized_acceleration=zero)
        probe = ca.Function("g1_com_probe", [q], [outputs["CoM"]], ["configuration"], ["CoM"])
        function_path = output / "g1_com_probe.casadi"
        probe.save(str(function_path))
        entry = f"{function_path}:g1_com_probe_cuda:0:g1_com_probe_kernel:device_g1_com_probe_eval"
    else:
        batch = ",".join(map(str, cuda["batch_inputs"]))
        entry = f"{function_path}:{cuda['unit_name']}:{batch}:{cuda['kernel_name']}:{cuda['device_name']}"

    generator_path = source / "tools/generate_manifest_and_registry.py"
    os.chdir(output)
    sys.argv = [
        str(generator_path), "--entry", entry, "--casadi-real", "float",
        "--generated-dir", str(generated),
        "--manifest-out", str(generated / "kernels_manifest.json"),
        "--registry-out", str(output / "src/python/casadi_on_gpu_kernel_registry.cu"),
    ]
    runpy.run_path(str(generator_path), run_name="__main__")

    # The CUDA emitter can eliminate CPU workspace. Use CUDA macros, not the
    # serialized function's CPU sz_w, when estimating runtime stack allocation.
    manifest_path = generated / "kernels_manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for kernel in manifest["kernels"]:
        header = (generated / kernel["header"]).read_text()
        fields = dict(re.findall(
            rf"^#define\s+{re.escape(kernel['function_name'])}_SZ_(ARG|RES|IW|W)\s+(\d+)\s*$",
            header, re.MULTILINE,
        ))
        if set(fields) != {"ARG", "RES", "IW", "W"}:
            raise RuntimeError("Incomplete generated CUDA workspace macros")
        kernel["work"] = {f"sz_{key.lower()}": int(value) for key, value in fields.items()}
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    generator = runpy.run_path(str(generator_path), run_name="_cog_registry")
    registry = generator["_generate_registry_source"](manifest, "")
    (output / "src/python/casadi_on_gpu_kernel_registry.cu").write_text(registry)


if __name__ == "__main__":
    main()
