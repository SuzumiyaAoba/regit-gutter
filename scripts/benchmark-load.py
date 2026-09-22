#!/usr/bin/env python3
"""Fresh-process require benchmark; optional Git Gutter comparison."""
import argparse
import json
import pathlib
import platform
import shutil
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--emacs', default='emacs')
parser.add_argument('--git-gutter-dir', type=pathlib.Path)
parser.add_argument('--runs', type=int, default=5)
args = parser.parse_args()
if args.runs < 1:
    parser.error('--runs must be positive')
root = pathlib.Path(__file__).resolve().parents[1]
packages = {'regit-gutter': root}
if args.git_gutter_dir:
    packages['git-gutter'] = args.git_gutter_dir.resolve()
results = {name: [] for name in packages}
for iteration in range(args.runs + 1):
    names = list(packages)
    if iteration % 2:
        names.reverse()
    for name in names:
        # Load reporting infrastructure before measuring, not the target.
        expression = f"""(progn
          (require 'json)
          (setq native-comp-jit-compilation nil)
          (garbage-collect)
          (let ((start (current-time)) (gcs gcs-done)
                (compiler-before (featurep 'comp)))
            (require '{name})
            (let ((elapsed (float-time (time-subtract (current-time) start))))
              (princ (json-encode
                `((seconds . ,elapsed) (gcs . ,(- gcs-done gcs))
                  (compiler_loaded . ,(if (and (not compiler-before)
                                               (featurep 'comp)) t :json-false))
                  (library . ,(locate-library "{name}"))
                  (emacs . ,emacs-version)))))))"""
        completed = subprocess.run(
            [args.emacs, '-Q', '--batch', '-L', str(packages[name]),
             '--eval', expression], check=True, text=True, capture_output=True,
            timeout=60)
        if iteration:
            results[name].append(json.loads(completed.stdout))
print(json.dumps({'platform': platform.platform(),
                  'emacs_executable': shutil.which(args.emacs),
                  'native_jit': False,
                  'warmups_per_package': 1, 'runs': results,
                  'median_seconds': {name: statistics.median(r['seconds'] for r in rows)
                                     for name, rows in results.items()}}, indent=2))
