import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'runtime/local-source-compose.py'
spec = importlib.util.spec_from_file_location('local_source_compose', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LocalSourceComposeTest(unittest.TestCase):
    def test_both_modes_mount_current_code_without_nested_readonly_mounts(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            for mode in ('standalone', 'cluster'):
                state = workspace / mode
                algorithm = state / 'build/rec-algorithm'
                (algorithm / 'algorithm').mkdir(parents=True)
                (algorithm / 'algorithm/__init__.py').write_text('VERSION = "current"\n')
                services = module.generate(workspace, state, mode)['services']
                self.assertEqual('rank-engine' in services, mode == 'cluster')
                for service in services.values():
                    targets = [Path(volume['target']) for volume in service['volumes']]
                    for target in targets:
                        self.assertFalse(any(parent in targets for parent in target.parents))
                    for volume in service['volumes']:
                        self.assertTrue(volume['read_only'])
                        self.assertFalse(volume['bind']['create_host_path'])
                if mode == 'cluster':
                    with zipfile.ZipFile(algorithm / 'rec-algorithm.zip') as archive:
                        self.assertEqual(archive.namelist(), ['algorithm/__init__.py'])
                        self.assertIn(b'current', archive.read('algorithm/__init__.py'))


if __name__ == '__main__':
    unittest.main()
