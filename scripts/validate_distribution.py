#!/usr/bin/env python3
"""Validate the OpenRec distribution manifest and local documentation."""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "release" / "openrec.json"
VERSION = ROOT / "VERSION"
COMPONENT_NAME = re.compile(r"^[a-z][a-z0-9-]+$")
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
MARKDOWN_LINK = re.compile(r"(?<!!)\[[^]]*]\(([^)]+)\)")


def fail(message):
    print("error: %s" % message, file=sys.stderr)
    return 1


def validate_manifest(require_immutable):
    errors = 0
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return fail("cannot read %s: %s" % (MANIFEST.relative_to(ROOT), error))

    version = VERSION.read_text(encoding="utf-8").strip()
    if not SEMVER.match(version):
        errors += fail("VERSION is not semantic versioning: %s" % version)
    if manifest.get("schema_version") != 1:
        errors += fail("unsupported release manifest schema_version")
    if manifest.get("distribution") != "openrec":
        errors += fail("release manifest distribution must be openrec")
    if manifest.get("version") != version:
        errors += fail("VERSION and release manifest version differ")

    components = manifest.get("components")
    if not isinstance(components, dict) or not components:
        return errors + fail("release manifest components must be a non-empty object")
    required = {"bigdata-platform", "data-processor", "rank-engine", "rec-algorithm",
                "rec-console", "rec-server", "sdk"}
    missing = required.difference(components)
    if missing:
        errors += fail("release manifest is missing: %s" % ", ".join(sorted(missing)))

    for name, component in sorted(components.items()):
        if not COMPONENT_NAME.match(name):
            errors += fail("invalid component name: %s" % name)
            continue
        repository = component.get("repository", "")
        expected = "https://github.com/open-rec/%s.git" % name
        if repository != expected:
            errors += fail("%s repository must be %s" % (name, expected))
        ref = component.get("ref", "")
        if not isinstance(ref, str) or not ref.strip():
            errors += fail("%s has no component ref" % name)
        if require_immutable and not (FULL_SHA.match(ref) or ref == "v" + version):
            errors += fail("%s ref is not immutable for release: %s" % (name, ref))
        modes = component.get("required_for")
        if not isinstance(modes, list) or not modes or set(modes).difference({"standalone", "cluster"}):
            errors += fail("%s required_for must contain standalone and/or cluster" % name)
    return errors


def validate_links():
    errors = 0
    for document in sorted(ROOT.rglob("*.md")):
        if any(part in {".git", ".runtime", "target"} for part in document.parts):
            continue
        content = document.read_text(encoding="utf-8")
        for raw_target in MARKDOWN_LINK.findall(content):
            target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
            if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                continue
            path_text = unquote(target.split("#", 1)[0])
            candidate = (document.parent / path_text).resolve()
            try:
                candidate.relative_to(ROOT)
            except ValueError:
                errors += fail("%s links outside the repository: %s" %
                               (document.relative_to(ROOT), target))
                continue
            if not candidate.exists():
                errors += fail("broken link in %s: %s" %
                               (document.relative_to(ROOT), target))
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-immutable", action="store_true",
                        help="reject branches and other floating component refs")
    args = parser.parse_args()
    errors = validate_manifest(args.require_immutable) + validate_links()
    if errors:
        print("distribution validation failed with %d error(s)" % errors, file=sys.stderr)
        return 1
    print("distribution manifest and documentation are valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
