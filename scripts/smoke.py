#!/usr/bin/env python3
"""Run the interactive smoke in a controlling terminal (optionally GUI)."""
import argparse
import fcntl
import json
import os
import pathlib
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--emacs', default='emacs')
parser.add_argument('--gui', action='store_true')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]


def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


with tempfile.TemporaryDirectory(prefix='regit-smoke-') as temp:
    result = pathlib.Path(temp) / 'result.json'
    env = dict(os.environ, REGIT_SMOKE_RESULT=str(result), TERM='xterm-256color')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    process = None
    output = bytearray()
    try:
        process = subprocess.Popen(
            [args.emacs, '-Q', *([] if args.gui else ['-nw']), '-L', str(root),
             '-l', str(root / 'test/regit-gutter-interactive-smoke.el')],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            preexec_fn=controlling_terminal)
        os.close(slave)
        slave = None
        deadline = time.monotonic() + 45
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.05)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        process.wait(timeout=max(0.1, deadline - time.monotonic()))
        if process.returncode or not result.exists():
            raise RuntimeError(output.decode(errors='replace'))
        report = json.loads(result.read_text())
        if not report.get('passed') or report.get('graphic') != args.gui:
            raise RuntimeError(report)
        print(json.dumps(report))
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        if slave is not None:
            os.close(slave)
