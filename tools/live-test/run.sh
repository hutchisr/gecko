#!/bin/sh
# Live two-account check; see live_test.py. Needs uv, the booted Simulator with
# a current Gecko build installed and signed in as USERNAME, and USERNAME2/
# PASSWORD2 in credentials.local.txt. Test-only: nothing here ships in the app.
set -e
cd "$(dirname "$0")"
exec uv run --quiet --python 3.12 --with-requirements requirements.txt python live_test.py "$@"
