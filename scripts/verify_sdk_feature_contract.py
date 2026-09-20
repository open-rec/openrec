#!/usr/bin/env python3
"""Check SDK item/event JSON fields against the distribution's Java protocol."""

import re
import sys
from dataclasses import fields
from pathlib import Path


WORKSPACE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(WORKSPACE / "sdk/python-client"))

from openrec import models


def main():
    go_source = (WORKSPACE / "sdk/go-client/types.go").read_text()
    for name in ("Item", "Event"):
        java_source = (
            WORKSPACE / "rec-server/proto/src/main/java/com/openrec/proto/model"
            / (name + ".java")
        ).read_text()
        expected = set(re.findall(r"private\s+\S+\s+(\w+)\s*;", java_source))
        assert expected, "Java protocol fields were not found: " + name
        python_fields = {
            models._JSON_NAMES.get(field.name, field.name)
            for field in fields(getattr(models, name))
        }
        go_struct = re.search(r"type " + name + r" struct \{(.*?)\n\}", go_source, re.S)
        assert go_struct, "Go model was not found: " + name
        go_fields = set(re.findall(r'json:"([^",]+)', go_struct.group(1)))
        for language, actual in (("Python", python_fields), ("Go", go_fields)):
            assert actual == expected, (
                f"{language} {name}: missing={sorted(expected - actual)}, "
                f"extra={sorted(actual - expected)}"
            )
    print("PASS: Python/Go Item and Event fields match rec-proto")


if __name__ == "__main__":
    main()
