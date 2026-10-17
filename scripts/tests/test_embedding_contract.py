"""Validate optional embedding wiring and compatibility checks without Docker/GPU."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('verify_embedding', ROOT / 'example/scripts/verify_embedding.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class EmbeddingContractTest(unittest.TestCase):
    def test_compatibility_rejects_wrong_or_invalid_vectors(self):
        self.assertAlmostEqual(verify.cosine([0.6, 0.8], [3, 4]), 1)
        self.assertAlmostEqual(verify.cosine([1, 0], [0, 1]), 0)
        for left, right in [([1], [1, 0]), ([0, 0], [1, 0]), ([float('nan')], [1])]:
            with self.assertRaises(ValueError):
                verify.cosine(left, right)

    def test_profiles_forward_optional_embedding_configuration(self):
        for mode in ('standalone', 'cluster'):
            profile = (ROOT / f'rec-server/server/src/main/resources/application-{mode}.properties').read_text()
            self.assertIn('embedding.enabled=${EMBEDDING_ENABLED:false}', profile)
            compose = (ROOT / f'rec-server/docker-compose.{mode}.yml').read_text()
            self.assertIn('EMBEDDING_ENABLED: ${EMBEDDING_ENABLED:-false}', compose)
            self.assertIn('http://vllm:8000/v1/embeddings', compose)
            startup = (ROOT / f'example/example_{mode}/start.sh').read_text()
            self.assertIn('scripts/verify_embedding.py', startup)
            self.assertLess(startup.index('scripts/verify_embedding.py'),
                            startup.index('com.openrec.example.InitStandalone'))

    def test_query_graph_and_language_initializer_agree(self):
        graph = json.loads((ROOT / 'rec-server/server/src/main/resources/item_graph.json').read_text())
        node = next(node for node in graph['nodes'] if node['name'] == 'query_title_emb')
        self.assertEqual(node['content']['tableName'], 'query-title-emb')
        edges = {(edge['from'], edge['to']) for edge in graph['edges']}
        for channel in ('query_title_emb', 'user_cf_u2i', 'item_search'):
            self.assertIn(('user_trigger', channel), edges)
            self.assertIn((channel, 'combine'), edges)
        initializer = (ROOT / 'example/init/src/main/java/com/openrec/example/InitStandalone.java').read_text()
        self.assertIn('/item_title_emb.csv', initializer)
        self.assertIn('"query-title-emb-index"', initializer)
        self.assertIn('"similarity", "cosine"', initializer)
        platform = (ROOT / 'bigdata-platform/platform.sh').read_text()
        for line in platform.splitlines():
            if line.startswith(('readonly STANDALONE_COMPONENTS=', 'readonly CLUSTER_COMPONENTS=')):
                self.assertNotIn('vllm', line)
