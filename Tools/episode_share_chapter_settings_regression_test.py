#!/usr/bin/env python3
"""Validate the declared universal-link route for shared episodes."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
aasa = json.loads((ROOT / 'Server/well-known/apple-app-site-association').read_text())
assert any(c['/'] == '/share/episode' for c in aasa['applinks']['details'][0]['components'])
print('Episode share universal-link route checks passed')
