"""Package an already built CPython runtime (default 3.12) without rebuilding native code."""

from __future__ import annotations

import argparse
from pathlib import Path

from wheel.wheelfile import WheelFile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", type=Path)
    parser.add_argument("name")
    parser.add_argument("version")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--requires", action="append", default=[])
    parser.add_argument("--python-minor", type=int, default=12, help="CPython 3.N the stage was built for")
    args = parser.parse_args()
    tag = f"cp3{args.python_minor}"
    name = args.name.replace("-", "_")
    metadata_dir = f"{name}-{args.version}.dist-info"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    wheel_path = args.output_dir / f"{name}-{args.version}-{tag}-{tag}-linux_x86_64.whl"
    metadata = (
        "Metadata-Version: 2.1\n"
        f"Name: {args.name}\n"
        f"Version: {args.version}\n"
        f"Requires-Python: >=3.{args.python_minor},<3.{args.python_minor + 1}\n"
        + "".join(f"Requires-Dist: {requirement}\n" for requirement in args.requires)
        + "\n"
    )
    with WheelFile(wheel_path, "w") as archive:
        for path in sorted(args.stage.rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts:
                archive.write(path, str(path.relative_to(args.stage)))
        archive.writestr(f"{metadata_dir}/METADATA", metadata)
        archive.writestr(
            f"{metadata_dir}/WHEEL",
            f"Wheel-Version: 1.0\nGenerator: local-cmake-build\nRoot-Is-Purelib: false\nTag: {tag}-{tag}-linux_x86_64\n",
        )
    print(wheel_path)


if __name__ == "__main__":
    main()
