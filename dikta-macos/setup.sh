#!/bin/bash
# Dikta Setup Script
# Sets up Kokoro TTS for text-to-speech functionality
set -e

DIKTA_DIR="$HOME/.dikta"
VENV_DIR="$DIKTA_DIR/venv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Dikta Setup ==="
echo ""

# 1. Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add to PATH for this session
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi

# 2. Check for Python 3.11
PYTHON_PATH=""
if command -v /opt/homebrew/bin/python3.11 &> /dev/null; then
    PYTHON_PATH="/opt/homebrew/bin/python3.11"
elif command -v /usr/local/bin/python3.11 &> /dev/null; then
    PYTHON_PATH="/usr/local/bin/python3.11"
elif command -v python3.11 &> /dev/null; then
    PYTHON_PATH="$(which python3.11)"
fi

if [ -z "$PYTHON_PATH" ]; then
    echo "Python 3.11 not found. Installing via Homebrew..."
    brew install python@3.11
    PYTHON_PATH="/opt/homebrew/bin/python3.11"
fi

echo "Using Python: $PYTHON_PATH"

# 3. Create dikta directory
echo "Creating ~/.dikta directory..."
mkdir -p "$DIKTA_DIR"

# 4. Create virtual environment if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    "$PYTHON_PATH" -m venv "$VENV_DIR"
fi

# 5. Install dependencies
echo "Installing Kokoro TTS (this may take a minute)..."
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install kokoro soundfile numpy --quiet

# 6. Copy server script
echo "Copying server script..."
cp "$SCRIPT_DIR/kokoro_server.py" "$DIKTA_DIR/"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Build the app:  swift build"
echo "  2. Run the app:    .build/debug/Dikta"
echo ""
echo "The Whisper model (~150MB) will download automatically on first dictation."
echo ""
