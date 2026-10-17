"""Check deployed recall naming without importing Airflow or Spark."""
import ast
import csv
import json
from pathlib import Path
import unittest

WORKSPACE = Path(__file__).resolve().parents[3]
DAGS = WORKSPACE / 'example/example_cluster/airflow/dags'


def constants(path):
    result = {}
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.Assign):
            try:
                value = ast.literal_eval(node.value)
            except (ValueError, TypeError):
                continue
            for target in node.targets:
                if isinstance(target, ast.Name):
                    result[target.id] = value
    return result


class RecallContractTest(unittest.TestCase):
    def test_files_dags_publishers_and_graphs_agree(self):
        if not (WORKSPACE / 'rec-server').is_dir() or not (WORKSPACE / 'model').is_dir():
            self.skipTest('requires sibling source repositories and model bundle')
        publisher = constants(WORKSPACE / 'rec-algorithm/jobs/spark/recall_job.py')['SERVING_TABLES']
        tree = ast.parse((WORKSPACE / 'rec-algorithm/publisher/spark.py').read_text())
        publish = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                       and node.name == 'publish_embedding')
        defaults = dict(zip((arg.arg for arg in publish.args.args[-len(publish.args.defaults):]),
                            map(ast.literal_eval, publish.args.defaults)))
        self.assertEqual(defaults['index_suffix'], 'item_seq_emb-index')
        initializer = (WORKSPACE / 'example/init/src/main/java/com/openrec/example/InitStandalone.java').read_text()
        self.assertIn('"%s-item_seq_emb-index"', initializer)

        for target, dag_name in (('item', 'openrec_daily_recall.py'),
                                 ('user', 'openrec_daily_user_recall.py')):
            dag = constants(DAGS / dag_name)
            graph = json.loads((WORKSPACE / f'rec-server/server/src/main/resources/{target}_graph.json').read_text())
            channels = {node['content']['recallType']: node['content']['tableName']
                        for node in graph['nodes'] if node.get('content') and 'tableName' in node['content']}
            for algorithm in dag['DEFAULT_CONFIG']['algorithms']:
                with self.subTest(target=target, algorithm=algorithm):
                    artifact = 'text_search' if algorithm == 'sparse' else algorithm
                    path = WORKSPACE / f'model/recall/{target}/{artifact}.csv'
                    self.assertTrue(path.is_file(), path)
                    channel = dag['RECALL_TYPES'][algorithm]
                    if algorithm == 'item_seq_emb':
                        self.assertEqual(channels[channel], 'item_seq_emb')
                        self.assertEqual(channels['query_qwen_emb'], 'query_qwen_emb')
                        self.assertNotEqual(channels['query_qwen_emb'], channels[channel])
                    else:
                        self.assertEqual(dag['SERVING_TABLES'][algorithm], publisher[algorithm])
                        self.assertEqual(channels[channel], publisher[algorithm])
                    if target == 'user':
                        with path.open() as stream:
                            self.assertEqual(next(csv.reader(stream)),
                                             ['scene', 'left_user', 'right_user', 'score'])

    def test_user_dag_validation_translates_algorithm_to_channel(self):
        path = DAGS / 'openrec_daily_user_recall.py'
        tree = ast.parse(path.read_text())
        function = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                        and node.name == 'verify_aliases_and_online_recall')
        function.decorator_list = []
        values = constants(path)
        def request(url, **kwargs):
            if '/api/recall/releases/' in url:
                table = url.rsplit('/', 1)[-1]
                return {'active_indexes': [f'openrec-recall-{table}-20261017-r001']}
            return {'data': {'results': [{'recallFrom': channel}
                                         for channel in values['RECALL_TYPES'].values()]}}
        values['_request'] = request
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), 'exec'), values)
        values['verify_aliases_and_online_recall']('2026-10-17', 'r001',
                                                   values['DEFAULT_CONFIG']['algorithms'])

    def test_language_vector_tables_match_bundle_and_entity_ids(self):
        import hashlib
        import math

        root = WORKSPACE / 'model/recall/item'
        manifest = json.loads((WORKSPACE / 'model/default.manifest.json').read_text())
        identities = []
        for name in ('item_title_emb.csv',):
            path = root / name
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), manifest['outputs']['recall/item/' + name])
            with path.open() as stream:
                rows = list(csv.DictReader(stream))
            identities.append([(row['scene'], row['item']) for row in rows])
            self.assertTrue(rows)
            for row in rows:
                vector = json.loads(row['vector'])
                self.assertEqual(len(vector), 1024)
                self.assertAlmostEqual(math.sqrt(sum(value * value for value in vector)), 1., places=5)
        with (WORKSPACE / 'example/data/test/item.csv').open() as stream:
            expected = [(row['scene'], row['id']) for row in csv.DictReader(stream)]
        self.assertEqual(identities[0], expected)
        self.assertFalse((root / 'item_content_emb.csv').exists())
        self.assertFalse((root / 'query_embedding.csv').exists())
