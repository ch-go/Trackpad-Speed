#!/usr/bin/env python3
"""Read-only summary. Does not infer physical input or claim a measured speed multiplier."""
import argparse
import collections
import json
import math
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('path')
parser.add_argument('--operation')
args = parser.parse_args()
records = []
bad = 0
for line in Path(args.path).read_text(encoding='utf-8').splitlines():
    try:
        r = json.loads(line)
        if not isinstance(r, dict):
            raise ValueError('not an object')
        records.append(r)
    except (ValueError, TypeError):
        bad += 1
if args.operation:
    ids = {args.operation}
    for _ in records:
        children = {r.get('operationID') for r in records if r.get('parentOperationID') in ids}
        if children.issubset(ids):
            break
        ids.update(children)
    records = [r for r in records if r.get('operationID') in ids]
counts = collections.Counter(r.get('event', 'unknown') for r in records)
print(f'Records: {len(records)}; malformed lines: {bad}')
for name, n in sorted(counts.items()):
    print(f'{name}: {n}')
print('\nOperation timeline (uptime seconds):')
for r in records:
    if args.operation or r.get('event', '').startswith(('operation.', 'apply.', 'restore.', 'filter.', 'pointer.trace.', 'system.')):
        fields = {k: v for k, v in r.items() if k not in {'pid', 'unixTime', 'uptime', 'event', 'curves', 'inputCurves', 'outputCurves', 'originalCurves', 'value', 'pointerFilter'}}
        print(f'{r.get("uptime", 0):.3f} {r.get("event")} {json.dumps(fields, ensure_ascii=False)}')
moves = [r for r in records if r.get('event') == 'pointer.output']
if moves:
    distance = sum(math.hypot(r.get('deltaX', 0), r.get('deltaY', 0)) for r in moves)
    print(f'\nObserved movement events: {len(moves)}; sum of CGEvent delta magnitudes: {distance:.2f}')
print('These are session CGEvents; raw physical input and device attribution are unavailable.')
print('No precise physical speed multiplier can be concluded from this log alone.')
