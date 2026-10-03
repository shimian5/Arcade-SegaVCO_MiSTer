#!/usr/bin/env python3
"""Verify that edits to Verilog/SystemVerilog files changed only comments and whitespace.

usage: check_comment_only.py <git-ref> <file> [<file> ...]
Compares each file's working copy with its version at <git-ref>, after removing // and
/* */ comments (string literals are respected) and collapsing whitespace.
"""
import re
import subprocess
import sys

TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)


def strip(text):
    text = TOKEN.sub(lambda m: m.group(0) if m.group(0).startswith('"') else ' ', text)
    return re.sub(r'\s+', ' ', text).strip()


def main():
    ref, files = sys.argv[1], sys.argv[2:]
    bad = 0
    for f in files:
        old = subprocess.run(['git', 'show', f'{ref}:{f}'], capture_output=True, text=True, encoding='utf-8').stdout
        new = open(f, encoding='utf-8').read()
        ok = strip(old) == strip(new)
        n_old = len(re.findall(r'//|/\*', old))
        n_new = len(re.findall(r'//|/\*', new))
        print(f'{"OK " if ok else "CODE CHANGED"} {f} comment markers {n_old} -> {n_new}')
        bad += not ok
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
