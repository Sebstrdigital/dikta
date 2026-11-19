QT += core gui network qml quick quickcontrols2 widgets svg multimedia
CONFIG += c++17
TEMPLATE = app
TARGET = dikta

HEADERS += src/backend.h src/theme.h src/hotkey.h src/audiofeedback.h
SOURCES += src/main.cpp src/backend.cpp src/theme.cpp src/hotkey.cpp src/audiofeedback.cpp
RESOURCES += src/resources.qrc
