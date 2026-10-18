"""Exercise custom bootstrap inputs and artifact validity without live services."""
import csv
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

EXAMPLE = Path(__file__).resolve().parents[2]
WORKSPACE = EXAMPLE.parent
spec = importlib.util.spec_from_file_location("init_input", EXAMPLE / "init/tools/init-input.py")
inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inputs)


def write_inputs(root):
    rows = {
        "user": {"id": "reader ' $(false)", "name": "读者", "age": "25"},
        "item": {"id": "book-1", "scene": "books", "title": "文学 小说"},
        "event": {"id": "click-1", "user_id": "reader ' $(false)", "item_id": "book-1",
                  "scene": "books", "type": "click"},
    }
    for entity, values in rows.items():
        with (root / f"{entity}.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=inputs.COLUMNS[entity].split())
            writer.writeheader()
            writer.writerow(values)


class InitPipelineTest(unittest.TestCase):
    def test_custom_ids_scenes_and_shell_characters_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            write_inputs(Path(directory))
            result = subprocess.run(["python3", str(EXAMPLE / "init/tools/init-input.py"),
                                     "--data", directory], capture_output=True, text=True, check=True)
            result = subprocess.run(["bash", "-eu", "-c", result.stdout +
                                     '\nprintf "%s\\n" "$smoke_user" "$smoke_scene" "$smoke_item_query"'],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), ["reader ' $(false)", "books", "文学 小说"])

    def test_missing_columns_empty_data_and_unknown_entities_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_inputs(root)
            (root / "user.csv").write_text("id\nreader\n")
            with self.assertRaisesRegex(ValueError, "missing columns"):
                inputs.inspect(root)
            write_inputs(root)
            event = root / "event.csv"
            event.write_text(event.read_text().replace("book-1", "unknown"))
            with self.assertRaisesRegex(ValueError, "unknown user or item"):
                inputs.inspect(root)
            write_inputs(root)
            event.write_text(event.read_text().splitlines()[0] + "\n")
            with self.assertRaisesRegex(ValueError, "no data rows"):
                inputs.inspect(root)

    def test_import_rechecks_bundle_before_invoking_java(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, WORKSPACE=str(WORKSPACE), OPENREC_DATA_DIR=directory,
                       OPENREC_MODEL_ROOT=directory, JAVA="SHOULD_NOT_BE_CALLED", BUILD_DIR=directory)
            result = subprocess.run(["bash", "-eu", "-c", '''
source "$WORKSPACE/openrec/init/tools/init.sh"
die() { echo "$*" >&2; return 1; }
note() { :; }
openrec_import_data standalone
'''], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("changed since preparation", result.stderr)
            self.assertNotIn("SHOULD_NOT_BE_CALLED", result.stderr)

    def test_java_launcher_forwards_mode_and_paths_as_separate_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            java = root / "java"
            java.write_text('#!/bin/bash\nprintf "%s\\0" "$@" > "$CAPTURE"\n')
            java.chmod(0o755)
            capture = root / "args"
            for mode in ("standalone", "cluster"):
                env = dict(os.environ, WORKSPACE=str(WORKSPACE), JAVA=str(java),
                           OPENREC_DATA_DIR=str(root / "raw data"),
                           OPENREC_MODEL_ROOT=str(root / "model data"),
                           BUILD_DIR=str(root / "build"), CAPTURE=str(capture), MODE=mode)
                result = subprocess.run(["bash", "-eu", "-c", '''
source "$WORKSPACE/openrec/init/tools/init.sh"
python3() { return 0; }  # Artifact checker is tested separately.
note() { :; }
openrec_import_data "$MODE"
'''], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = capture.read_bytes().decode().rstrip("\0").split("\0")
                self.assertEqual(args[2:4], ["com.openrec.example.InitServingData", mode])
                self.assertEqual(args[-2:], [env["OPENREC_DATA_DIR"], env["OPENREC_MODEL_ROOT"]])

    def test_reuse_requires_version_inputs_and_intact_outputs(self):
        code = '''
import json, sys
from pathlib import Path
from tool.check_default_artifacts import valid, REQUIRED, sha256, SCHEMA_VERSION, BUILD_VERSION
from algorithm.feature.feature_catalog import FeatureCatalog
root = Path(sys.argv[1]); data = root / "data"; model = root / "model"
data.mkdir(); model.mkdir()
for name in ("user.csv", "item.csv", "event.csv"):
    (data / name).write_text("original")
assert not valid(data, model)
for name in REQUIRED:
    path = model / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text("artifact")
catalog = FeatureCatalog.load()
manifest = {"schema_version": SCHEMA_VERSION, "build_version": BUILD_VERSION,
            "catalog_version": catalog.version, "catalog_sha256": catalog.sha256,
            "inputs": {name: sha256(data / name) for name in ("user.csv", "item.csv", "event.csv")},
            "outputs": {name: sha256(model / name) for name in REQUIRED}}
path = model / "default.manifest.json"
path.write_text(json.dumps(manifest)); assert valid(data, model)
manifest["build_version"] -= 1
path.write_text(json.dumps(manifest)); assert not valid(data, model)
manifest["build_version"] = BUILD_VERSION
path.write_text(json.dumps(manifest))
(data / "event.csv").write_text("changed"); assert not valid(data, model)
(data / "event.csv").write_text("original")
(model / REQUIRED[0]).write_text("corrupt"); assert not valid(data, model)
(model / REQUIRED[0]).unlink(); assert not valid(data, model)
'''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["python3", "-c", code, directory],
                                    env=dict(os.environ, PYTHONPATH=str(WORKSPACE / "rec-algorithm")),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


class CustomRecommendationTest(unittest.TestCase):
    def run_check(self, mode, results):
        import io
        import json
        from unittest.mock import Mock, patch
        spec = importlib.util.spec_from_file_location(
            "verify_init", EXAMPLE / "scripts/runtime/verify-init-recommendation.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        opener = Mock()
        payload = json.dumps({"code": 200, "status": True, "data": {"results": results}}).encode()
        opener.open.side_effect = lambda *args, **kwargs: io.BytesIO(payload)
        with patch("sys.argv", ["verify", "--mode", mode, "--user", "reader", "--scene", "books",
                                "--item-query", "novel", "--user-query", "reader"]), \
                patch.object(module.urllib.request, "build_opener", return_value=opener):
            module.main()
        self.assertEqual(opener.open.call_count, 2)
        for call in opener.open.call_args_list:
            body = json.loads(call.args[0].data)["body"]
            self.assertEqual(body["scene"], "books")
            self.assertEqual(body["userId"], "reader")

    def test_both_routes_use_custom_sample(self):
        self.run_check("standalone", [{"id": "candidate"}])
        self.run_check("cluster", [{"id": "candidate", "rankScore": 0.2}])

    def test_empty_results_fail(self):
        with self.assertRaisesRegex(RuntimeError, "recommendation failed"):
            self.run_check("standalone", [])

    def test_wrong_mode_ranking_fails(self):
        for mode, results in (("standalone", [{"rankScore": 0.2}]), ("cluster", [{"id": "candidate"}])):
            with self.subTest(mode=mode), self.assertRaisesRegex(RuntimeError, "ranking behavior"):
                self.run_check(mode, results)
