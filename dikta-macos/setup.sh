#!/bin/bash
# Alternative Kokoro installer; uses the same location and Python as About.
set -euo pipefail

DIKTA_DIR="$HOME/Library/Application Support/Dikta"
VENV_DIR="$DIKTA_DIR/venv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_PATH=""
for candidate in /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11 \
    /Library/Frameworks/Python.framework/Versions/3.11/bin/python3; do
    if [ -x "$candidate" ] && [ "$("$candidate" -c 'import sys; print("%d.%d" % sys.version_info[:2])')" = "3.11" ]; then
        PYTHON_PATH="$candidate"
        break
    fi
done
if [ -z "$PYTHON_PATH" ]; then
    echo "Python 3.11 is required for Kokoro. Install it from python.org or Homebrew, then retry." >&2
    exit 1
fi

echo "Using Python: $PYTHON_PATH"
mkdir -p "$DIKTA_DIR"
if [ -e "$VENV_DIR" ]; then
    BACKUP="$VENV_DIR.backup-$(uuidgen)"
    mv "$VENV_DIR" "$BACKUP"
    echo "Preserved existing environment: $BACKUP"
fi

# Bound each installer child; diagnostics remain visible rather than hidden.
"$PYTHON_PATH" - "$VENV_DIR" <<'PY'
import subprocess
import sys

venv = sys.argv[1]
commands = [
    ([sys.executable, '-m', 'venv', venv], 60),
    ([venv + '/bin/python3', '-m', 'pip', 'install', '--upgrade', 'pip', '--timeout', '30', '--retries', '2'], 600),
    ([venv + '/bin/python3', '-m', 'pip', 'install', '--timeout', '30', '--retries', '2', 'kokoro', 'soundfile', 'numpy'], 600),
    ([venv + '/bin/python3', '-c', 'import kokoro, soundfile, numpy'], 60),
]
for command, timeout in commands:
    try:
        subprocess.run(command, check=True, timeout=timeout)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        sys.exit('Kokoro setup failed: ' + str(error))
PY
cp "$SCRIPT_DIR/kokoro_server.py" "$DIKTA_DIR/kokoro_server.py"
echo "Setup complete. Open Dikta and check About for voice engine readiness."
