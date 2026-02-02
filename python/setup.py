"""
py2app build configuration for Dua Talk menu bar app.

Prerequisites:
    pip install py2app

Build commands:
    Development (alias build, fast):
        python setup.py py2app -A

    Production (standalone):
        python setup.py py2app

The built app will be in dist/Dua Talk.app
"""

from setuptools import setup

APP = ['dua_talk.py']

OPTIONS = {
    'argv_emulation': False,
    'iconfile': 'icon.icns',
    'plist': {
        'CFBundleName': 'Dua Talk',
        'CFBundleDisplayName': 'Dua Talk',
        'CFBundleIconFile': 'icon',
        'CFBundleIdentifier': 'com.local.dua-talk',
        'CFBundleVersion': '0.2.0',
        'CFBundleShortVersionString': '0.2.0',
        'LSUIElement': True,  # Menu bar only, no Dock icon
        'NSMicrophoneUsageDescription': 'Dua Talk needs microphone access for speech-to-text.',
        'NSAppleEventsUsageDescription': 'Dua Talk needs accessibility access for global hotkeys.',
    },
    'packages': [
        'whisper',
        'torch',
        'numpy',
        'sounddevice',
        'rumps',
        'pynput',
        'ollama',
    ],
    'includes': [
        'tiktoken',
        'tiktoken_ext',
        'tiktoken_ext.openai_public',
    ],
    'excludes': [
        'matplotlib',
        'tkinter',
        'PIL',
    ],
}

DATA_FILES = [
    ('', ['menubar_icon.png']),  # Menu bar icon
]

setup(
    name='Dua Talk',
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
)
