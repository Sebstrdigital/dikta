"""
py2app build configuration for Dikta menu bar app.

Prerequisites:
    pip install py2app

Build commands:
    Development (alias build, fast):
        python setup.py py2app -A

    Production (standalone):
        python setup.py py2app

The built app will be in dist/Dikta.app
"""

from setuptools import setup

APP = ['dua_talk.py']

OPTIONS = {
    'argv_emulation': False,
    'iconfile': 'icon.icns',
    'plist': {
        'CFBundleName': 'Dikta',
        'CFBundleDisplayName': 'Dikta',
        'CFBundleIconFile': 'icon',
        'CFBundleIdentifier': 'com.local.dua-talk',
        'CFBundleVersion': '0.2.0',
        'CFBundleShortVersionString': '0.2.0',
        'LSUIElement': True,  # Menu bar only, no Dock icon
        'NSMicrophoneUsageDescription': 'Dikta needs microphone access for speech-to-text.',
        'NSAppleEventsUsageDescription': 'Dikta needs accessibility access for global hotkeys.',
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
    name='Dikta',
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
)
