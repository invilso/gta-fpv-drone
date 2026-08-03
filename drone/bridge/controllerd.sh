#!/bin/sh
# Manual launcher for the controller -> UDP bridge daemon. Uses uv, which
# installs the daemon's one dependency (pysdl2, declared inline in
# controllerd.py) automatically on first run.
exec uv run "$(dirname "$0")/controllerd.py" "$@"
