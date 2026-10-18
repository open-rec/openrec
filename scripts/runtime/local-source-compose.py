#!/usr/bin/env python3
"""Compose overlay: reuse dependencies from images and run current workspace code."""
import json
from pathlib import Path
import sys
import zipfile


def generate(workspace, state, mode):
    build = state / "build"

    def mount(source, target):
        return {"type": "bind", "source": str(source), "target": target, "read_only": True,
                "bind": {"create_host_path": False}}

    services = {
        "rec-server": {"volumes": [
            mount(build / "rec-server/server/target/rec-server-0.1.0.jar", "/opt/openrec/rec-server.jar"),
            mount(build / "rec-server/contrib/target/rec-contrib-0.1.0.jar", "/opt/openrec/plugins/rec-contrib.jar"),
        ]},
        "rec-console": {"volumes": [
            mount(build / "rec-console/rec_console", "/opt/rec-console/rec_console"),
        ]},
    }
    if mode == "cluster":
        algorithm = build / "rec-algorithm"
        archive = algorithm / "rec-algorithm.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
            for path in sorted(algorithm.rglob("*")):
                if path.is_file() and path != archive:
                    output.write(path, path.relative_to(algorithm))
        services["rec-algorithm-runner"] = {"volumes": [mount(algorithm, "/opt/openrec")]}
        services["rank-engine"] = {
            "entrypoint": ["bash", "./start.sh"],
            "environment": {"PYTHONPATH": "/openrec-algorithm"},
            "volumes": [mount(workspace / "rank-engine", "/opt/openrec/rank-engine"),
                        mount(algorithm, "/openrec-algorithm")],
        }
    return {"services": services}


if __name__ == "__main__":
    workspace, state = map(lambda value: Path(value).resolve(), sys.argv[1:3])
    (state / "local-source.json").write_text(json.dumps(generate(workspace, state, sys.argv[3]), indent=2) + "\n")
