#!/bin/sh
# Manual launcher for the controller -> UDP bridge daemon.
exec python3 "$(dirname "$0")/controllerd.py" "$@"
