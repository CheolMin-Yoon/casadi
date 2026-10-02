"""Package an already built CPython 3.12 runtime without rebuilding native code."""

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
    args = parser.parse_args()
    name = args.name.replace("-", "_")
    metadata_dir = f"{name}-{args.version}.dist-info"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    wheel_path = args.output_dir / f"{name}-{args.version}-cp312-cp312-linux_x86_64.whl"
    metadata = (
        "Metadata-Version: 2.1\n"
        f"Name: {args.name}\n"
        f"Version: {args.version}\n"
        "Requires-Python: >=3.12,<3.13\n"
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
            "Wheel-Version: 1.0\nGenerator: local-cmake-build\nRoot-Is-Purelib: false\nTag: cp312-cp312-linux_x86_64\n",
        )
    print(wheel_path)


if __name__ == "__main__":
    main()
