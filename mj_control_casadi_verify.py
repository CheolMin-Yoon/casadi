"""Check the mj_control codegen environment: CasADi CUDA codegen, Pinocchio CasADi binding, nvcc compile."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

import casadi as ca
import numpy as np
import pinocchio as pin
import pinocchio.casadi as cpin


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--nvcc", type=Path, required=True)
    parser.add_argument("--cuda-arch", default="120")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    print(f"casadi {ca.__version__}, pinocchio {pin.__version__}")

    # Symbolic Pinocchio: SE(3) exp/log round trip against the numeric binding
    lam = ca.SX.sym("lam", 6)
    log_exp = ca.Function("log_exp", [lam], [cpin.log6(cpin.exp6(lam)).vector])
    sample = np.array([0.1, -0.2, 0.3, 0.4, -0.5, 0.6])
    error = np.abs(np.asarray(log_exp(sample)).ravel() - sample).max()
    print(f"cpin log6(exp6(lam)) round-trip error {error:.2e}")
    assert error < 1e-12

    # Symbolic model: Pinocchio's built-in sample manipulator keeps the check asset-free
    model = pin.buildSampleModelManipulator()
    cmodel = cpin.Model(model)
    cdata = cmodel.createData()
    q = ca.SX.sym("q", model.nq)
    mass_matrix = ca.Function("mass_matrix", [q], [cpin.crba(cmodel, cdata, q)])
    q0 = pin.neutral(model)
    reference = pin.crba(model, model.createData(), q0)
    reference = np.triu(reference) + np.triu(reference, 1).T
    error = np.abs(np.triu(np.asarray(mass_matrix(q0))) - np.triu(reference)).max()
    print(f"cpin crba vs pinocchio crba error {error:.2e}")
    assert error < 1e-10

    # CUDA codegen with a batched kernel, compiled by nvcc
    generator = ca.CodeGenerator(
        "mass_matrix_cuda",
        {"cuda": True, "with_header": True, "casadi_real": "float", "cuda_kernels": {"mass_matrix": {"batch_inputs": [0]}}},
    )
    generator.add(mass_matrix)
    source = Path(generator.generate(str(args.output_dir) + "/"))
    print(f"generated {source.name}, {'__global__' in source.read_text()=}")
    assert "__global__" in source.read_text()
    subprocess.run(
        [str(args.nvcc), "-c", f"-arch=sm_{args.cuda_arch}", str(source), "-o", str(source.with_suffix(".o"))],
        check=True,
    )
    print(f"nvcc compiled {source.with_suffix('.o').name}")


if __name__ == "__main__":
    main()
