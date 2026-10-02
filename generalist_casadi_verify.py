"""Check native/symbolic G1 models or compare a selected CUDA graph with CPU."""

from __future__ import annotations

import argparse
import json
from importlib import metadata
from pathlib import Path

import numpy as np
import pinocchio as pin
import pinocchio.casadi as cpin
from casadi_skills.robots.g1.model import build_pinocchio_model

import casadi as ca


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("cpu", "com", "g1"), default="cpu")
    parser.add_argument("--skills-root", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.skills_root / "casadi_skills/casadi_skills/robots/g1"
    config = json.loads((root / "config/codegen.json").read_text())
    function = ca.Function.load(str(root / config["function_file"]))
    model = build_pinocchio_model()
    symbolic_model = cpin.Model(model)
    assert (symbolic_model.nq, symbolic_model.nv) == (36, 35)
    rng = np.random.default_rng(20261002)
    q = np.stack([pin.integrate(model, pin.neutral(model), rng.uniform(-0.12, 0.12, model.nv)) for _ in range(4)])
    v = rng.uniform(-0.5, 0.5, (4, model.nv))
    a = rng.uniform(-1.0, 1.0, (4, model.nv))
    versions = {name: metadata.version(name) for name in (
        "casadi", "pin", "pinocchio-casadi", "casadi-on-gpu", "torch", "mjlab", "rsl-rl-lib",
    )}
    result = {
        "status": "pass", "mode": args.mode, "versions": versions,
        "casadi_revision": ca.CasadiMeta.git_revision(), "model_nq_nv": [model.nq, model.nv],
    }
    if args.mode == "cpu":
        data = model.createData()
        for lane in range(4):
            native = pin.centerOfMass(model, data, q[lane])
            expected = function(configuration=q[lane], generalized_velocity=v[lane], generalized_acceleration=a[lane])
            np.testing.assert_allclose(native, np.asarray(expected["CoM"]).ravel(), atol=1e-10, rtol=1e-10)
    else:
        import casadi_on_gpu as cog
        import torch

        q, v, a = (value.astype(np.float32) for value in (q, v, a))
        if args.mode == "com":
            probe = ca.Function.load(str(args.artifact_root / "builds/com-cog-source/g1_com_probe.casadi"))
            inputs = torch.as_tensor(q, device="cuda").contiguous()
            output = torch.empty((len(q), 3), dtype=torch.float32, device="cuda")
            cog.launch("g1_com_probe", [inputs.data_ptr()], [output.data_ptr()], len(q),
                       stream_ptr=torch.cuda.current_stream().cuda_stream, sync=True)
            actual = output.cpu().numpy()
            expected = np.stack([np.asarray(probe(configuration=lane)["CoM"]).ravel() for lane in q])
            np.testing.assert_allclose(actual, expected, atol=1e-5, rtol=1e-6)
            result["maximum_absolute_error"] = float(np.max(np.abs(actual - expected)))
        else:
            from casadi_skills.robots.g1.cuda_runtime import G1WholeBodyCudaEvaluator

            evaluator = G1WholeBodyCudaEvaluator(cog)
            outputs = evaluator.evaluate(*(torch.as_tensor(value, device="cuda") for value in (q, v, a)), sync=True)
            errors = {}
            for name, _, _ in evaluator.output_specs:
                actual = evaluator.matrix_view(outputs, name).cpu().numpy()
                expected = np.stack([np.asarray(function(
                    configuration=q[i], generalized_velocity=v[i], generalized_acceleration=a[i],
                )[name]) for i in range(len(q))])
                np.testing.assert_allclose(actual, expected, atol=config["tolerances"]["cuda_absolute_by_output"][name],
                                           rtol=config["tolerances"]["cuda_relative"])
                errors[name] = float(np.max(np.abs(actual - expected)))
            result["maximum_absolute_error_by_output"] = errors
        result["gpu"] = torch.cuda.get_device_name()
        result["batch_size"] = len(q)
    output_path = args.artifact_root / "builds" / f"recipe-{args.mode}-verification.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
