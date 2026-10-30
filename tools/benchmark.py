#!/usr/bin/env python3
"""Warm process-start measurements; no compositor access or source-tree writes."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', type=Path, required=True)
parser.add_argument('--samples', type=int, default=30)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
if not 3 <= args.samples <= 1000:
    parser.error('--samples must be between 3 and 1000')
commands = {
    'native_help': [str(args.helper.resolve()), '--help'],
}
results = {}
for name, command in commands.items():
    samples = []
    for i in range(args.samples + 1):
        start = time.perf_counter_ns()
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        elapsed = (time.perf_counter_ns() - start) / 1e6
        if i:
            samples.append(elapsed)
    ordered = sorted(samples)
    results[name] = {'median_ms': round(statistics.median(samples), 3),
                     'p90_ms': round(ordered[int(.9 * (len(samples)-1))], 3),
                     'samples': len(samples)}
report = {'method': 'Warm process startup through --help, including dynamic loading, argument parsing and exit. No network, catalogue work, compositor IPC or GPU work. One initial run excluded.',
          'results': results}
output = json.dumps(report, indent=2) + '\n'
print(output, end='')
if args.output:
    args.output.write_text(output)
