#!/usr/bin/env python3
"""Verify the inference service against the candidate vectors before enabling query recall."""
import argparse
import csv
import json
import math
import os
from pathlib import Path
import urllib.request
import urllib.parse


def cosine(left, right):
    if len(left) != len(right) or not left or not all(math.isfinite(x) for x in left + right):
        raise ValueError("invalid embedding dimensions or values")
    norm = math.sqrt(sum(x*x for x in left) * sum(x*x for x in right))
    if norm == 0:
        raise ValueError("zero embedding")
    return sum(x*y for x, y in zip(left, right)) / norm


def verify(item_file, vector_file, endpoint, model, samples=8, minimum=0.999):
    with open(item_file) as stream:
        titles = {(row['scene'], row['id']): row['title'] for row in csv.DictReader(stream)}
    rows = []
    with open(vector_file) as stream:
        for row in csv.DictReader(stream):
            rows.append(row)
            if len(rows) >= samples:
                break
    if not rows:
        raise ValueError("empty candidate vector file")
    inputs = [titles[(row['scene'], row['item'])] for row in rows]
    headers = {'Content-Type': 'application/json'}
    if os.getenv('EMBEDDING_API_KEY'):
        headers['Authorization'] = 'Bearer ' + os.environ['EMBEDDING_API_KEY']
    payload = {'model': model, 'input': inputs, 'encoding_format': 'float'}
    request = urllib.request.Request(endpoint, data=json.dumps(payload).encode(), headers=headers)
    # The host-side smoke endpoint must not be routed through a corporate HTTP proxy.
    local = urllib.parse.urlparse(endpoint).hostname in ('localhost', '127.0.0.1', '::1')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({})) if local else urllib.request.build_opener()
    with opener.open(request, timeout=60) as response:
        data = json.load(response)['data']
    vectors = {entry['index']: entry['embedding'] for entry in data}
    if len(data) != len(rows) or set(vectors) != set(range(len(rows))):
        raise ValueError('embedding response indexes do not match inputs')
    scores = [cosine(vectors[i], json.loads(row['vector'])) for i, row in enumerate(rows)]
    if min(scores) < minimum:
        raise ValueError('online/offline embeddings differ: min cosine %.8f < %.8f; regenerate '
                         'candidate vectors or correct the model/pooling/tokenization configuration'
                         % (min(scores), minimum))
    print('Embedding compatibility passed: %d samples, min cosine %.8f' % (len(rows), min(scores)))
    return scores


if __name__ == '__main__':
    workspace = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--items', default=str(workspace / 'openrec/data/test/item.csv'))
    parser.add_argument('--vectors', default=str(workspace / 'model/recall/item/item_title_emb.csv'))
    parser.add_argument('--endpoint', default=os.getenv('EMBEDDING_VERIFY_ENDPOINT',
                        'http://127.0.0.1:%s/v1/embeddings' % os.getenv('VLLM_PORT', '8000')))
    parser.add_argument('--model', default=os.getenv('EMBEDDING_MODEL', 'Qwen/Qwen3-Embedding-0.6B'))
    parser.add_argument('--samples', type=int, default=8)
    parser.add_argument('--minimum-cosine', type=float, default=0.999)
    args = parser.parse_args()
    if args.samples < 1 or not 0 < args.minimum_cosine <= 1:
        parser.error('samples must be positive and minimum-cosine in (0, 1]')
    verify(args.items, args.vectors, args.endpoint, args.model, args.samples, args.minimum_cosine)
