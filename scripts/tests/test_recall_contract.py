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
    def test_airflow_publish_tasks_use_serving_graph_table_names(self):
        for target, dag_name in [('item', 'openrec_daily_recall.py'),
                                 ('user', 'openrec_daily_user_recall.py')]:
            path = DAGS / dag_name
            values = constants(path)
            tree = ast.parse(path.read_text())
            function = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                            and node.name == 'publish_task_id')
            exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), 'exec'), values)
            graph = json.loads((WORKSPACE / f'rec-server/server/src/main/resources/{target}_graph.json').read_text())
            tables = {node['content']['recallType']: node['content']['tableName']
                      for node in graph['nodes'] if (node.get('content') or {}).get('tableName')}
            for algorithm, channel in values['RECALL_TYPES'].items():
                self.assertEqual(values['publish_task_id'](algorithm), 'publish-' + tables[channel])
            self.assertEqual(values['publish_task_id']('text_search'), f'publish-{target}-search')

    def test_files_dags_publishers_and_graphs_agree(self):
        if not (WORKSPACE / 'rec-server').is_dir():
            self.skipTest('requires sibling source repositories')
        manifest_path = WORKSPACE / 'model/default.manifest.json'
        manifest = json.loads(manifest_path.read_text()) if manifest_path.is_file() else None
        publisher = constants(WORKSPACE / 'rec-algorithm/jobs/spark/recall_job.py')['SERVING_TABLES']
        tree = ast.parse((WORKSPACE / 'rec-algorithm/publisher/spark.py').read_text())
        publish = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                       and node.name == 'publish_embedding')
        defaults = dict(zip((arg.arg for arg in publish.args.args[-len(publish.args.defaults):]),
                            map(ast.literal_eval, publish.args.defaults)))
        self.assertEqual(defaults['index_suffix'], 'item-seq-emb-index')
        initializer = (WORKSPACE / 'example/init/src/main/java/com/openrec/example/InitStandalone.java').read_text()
        self.assertIn('"%s-item-seq-emb-index"', initializer)

        for target, dag_name in (('item', 'openrec_daily_recall.py'),
                                 ('user', 'openrec_daily_user_recall.py')):
            dag = constants(DAGS / dag_name)
            graph = json.loads((WORKSPACE / f'rec-server/server/src/main/resources/{target}_graph.json').read_text())
            for node in graph['nodes']:
                content = node.get('content') or {}
                if 'tableName' in content:
                    self.assertRegex(content['tableName'], r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$')
                if 'recallType' in content:
                    self.assertRegex(content['recallType'], r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$')
            if target in ('item', 'user'):
                search = next(node for node in graph['nodes'] if node['name'] == f'{target}_search')
                self.assertEqual(search['clazz'], f'com.openrec.graph.node.{target}.SearchNode')
                self.assertEqual(search['configClazz'], 'com.openrec.graph.config.SearchConfig')
                self.assertEqual(search['content']['recallType'], f'{target}_search')
                self.assertEqual(search['content']['queryParam'], 'query')
                self.assertEqual(search['content']['textField'], 'text')
            channels = {node['content']['recallType']: node['content']['tableName']
                        for node in graph['nodes'] if node.get('content') and 'tableName' in node['content']}
            self.assertEqual(set(channels), set(dag['RECALL_TYPES'].values()))
            defaults = set(dag['DEFAULT_CONFIG']['algorithms'])
            self.assertNotIn('query_title_emb', defaults)
            self.assertEqual(defaults, set(dag['RECALL_TYPES']) - {'query_title_emb'})
            for algorithm in dag['DEFAULT_CONFIG']['algorithms']:
                with self.subTest(target=target, algorithm=algorithm):
                    artifact = "item_title_emb" if algorithm == "query_title_emb" else algorithm
                    path = WORKSPACE / f'model/recall/{target}/{artifact}.csv'
                    if manifest is not None and (algorithm != 'query_title_emb' or
                            f'recall/{target}/{artifact}.csv' in manifest['outputs']):
                        self.assertTrue(path.is_file(), path)
                    channel = dag['RECALL_TYPES'][algorithm]
                    if algorithm == 'item_seq_emb':
                        self.assertEqual(channels[channel], 'item-seq-emb')
                        self.assertEqual(channels['query_title_emb'], 'query-title-emb')
                        self.assertNotEqual(channels['query_title_emb'], channels[channel])
                    else:
                        table = f'{target}-search' if algorithm == 'text_search' else publisher[algorithm]
                        self.assertEqual(dag['SERVING_TABLES'][algorithm], table)
                        self.assertEqual(channels[channel], table)
                    if target == 'user' and path.is_file():
                        with path.open() as stream:
                            self.assertEqual(next(csv.reader(stream)),
                                             ['scene', 'user', 'text'] if algorithm == 'text_search' else
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
            return {'data': {'recallDiagnostics': [{'channel': channel, 'status': 'SUCCESS', 'candidateCount': 5}
                                         for channel in values['RECALL_TYPES'].values()]}}
        values['_request'] = request
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), 'exec'), values)
        values['verify_aliases_and_online_recall']('2026-10-17', 'r001',
                                                   values['DEFAULT_CONFIG']['algorithms'])

    def test_language_vector_tables_match_bundle_and_entity_ids(self):
        import hashlib
        import math

        root = WORKSPACE / 'model/recall/item'
        manifest_path = WORKSPACE / 'model/default.manifest.json'
        if not manifest_path.is_file():
            self.skipTest('optional precomputed model bundle is not checked out')
        manifest = json.loads(manifest_path.read_text())
        if 'recall/item/item_title_emb.csv' not in manifest['outputs']:
            self.skipTest('CPU bootstrap bundle has no optional language vectors')
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
