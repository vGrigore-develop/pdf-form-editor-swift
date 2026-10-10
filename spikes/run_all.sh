#!/bin/sh
# Rebuild fixtures and run every automatable spike. Exits non-zero on the first failure.
# s9_fill.py needs the local Node deps: (cd node && npm ci)
set -e
cd "$(dirname "$0")"
PY=../.venv/bin/python
$PY make_fixtures.py
$PY make_svg_fixtures.py
$PY s1_fields.py
$PY s5_cut.py
$PY s7_svg.py
$PY s3_preservation.py
$PY s9_fill.py
echo "all spikes passed"
