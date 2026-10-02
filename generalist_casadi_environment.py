"""Relocate the validated environment snapshot and lock newly built wheels."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skills-root", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent
    project = args.artifact_root.resolve() / "environment"
    project.mkdir(parents=True, exist_ok=True)
    text = (repo / "generalist-casadi.pyproject.toml").read_text()
    text = text.replace("/home/frlab/skills", str(args.skills_root.resolve()))
    text = text.replace("7217fce9a", args.revision[:9])
    # The archived lock records the original wheel bytes. Relocation/rebuild
    # changes wheel hashes, so let uv refresh their local artifact entries.
    archived = (repo / "generalist-casadi.uv.lock").read_text()
    archived = archived.replace("/home/frlab/skills", str(args.skills_root.resolve()))
    archived = archived.replace("7217fce9a", args.revision[:9])
    record = json.loads((repo / "generalist-casadi-build-record.json").read_text())
    for filename, info in record["wheels"].items():
        relocated = filename.replace("7217fce9a", args.revision[:9])
        digest = hashlib.sha256((args.artifact_root / "wheels" / relocated).read_bytes()).hexdigest()
        archived = archived.replace(info["sha256"], digest)
    (project / "pyproject.toml").write_text(text)
    (project / "uv.lock").write_text(archived)
    subprocess.run(["uv", "lock", "--project", str(project)], check=True)
    subprocess.run(["uv", "sync", "--locked", "--all-groups", "--project", str(project)], check=True)
    shutil.copy2(repo / "generalist-casadi-build-record.json", project / "original-build-record.json")
    print(project)


if __name__ == "__main__":
    main()
