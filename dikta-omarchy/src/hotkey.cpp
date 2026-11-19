#include "hotkey.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QProcess>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStringList>

namespace {
const QString description = QStringLiteral("Toggle Dikta dictation");
const QByteArray prefix = "-- Managed by Dikta. Do not edit.\no.bind(\"";
const QByteArray suffix = "\", \"Toggle Dikta dictation\", \"dikta --toggle\")\n";

QString configPath()
{
    return QDir::homePath() + QStringLiteral("/.config/dikta/shortcuts.lua");
}

bool readConfig(QByteArray &data, bool &exists, QString &error)
{
    const QFileInfo info(configPath());
    if (info.isSymLink()) {
        error = QObject::tr("The Dikta shortcut file is a symbolic link; refusing to replace it.");
        return false;
    }
    exists = info.exists();
    if (!exists)
        return true;
    QFile file(configPath());
    if (!file.open(QIODevice::ReadOnly)) {
        error = QObject::tr("Cannot read the Dikta shortcut file: %1").arg(file.errorString());
        return false;
    }
    data = file.readAll();
    if (file.error() != QFileDevice::NoError) {
        error = QObject::tr("Cannot read the Dikta shortcut file: %1").arg(file.errorString());
        return false;
    }
    // Only replace files in the exact format written by this application.
    static const QRegularExpression format(QStringLiteral(
        "^-- Managed by Dikta\\. Do not edit\\.\\no\\.bind\\(\"((?:(?:CTRL|ALT|SHIFT|SUPER) \\+ )+[A-Z0-9_]+)\", \"Toggle Dikta dictation\", \"dikta --toggle\"\\)\\n$"));
    if (!format.match(QString::fromUtf8(data)).hasMatch()) {
        error = QObject::tr("The Dikta shortcut file is not a recognized managed file; it was left unchanged.");
        return false;
    }
    return true;
}

QString shortcutFromData(const QByteArray &data)
{
    return QString::fromUtf8(data.mid(prefix.size(), data.size() - prefix.size() - suffix.size()));
}

bool saveConfig(const QByteArray &data, QString &error)
{
    QSaveFile file(configPath());
    if (!file.open(QIODevice::WriteOnly) || file.write(data) != data.size() || !file.commit()) {
        error = QObject::tr("Cannot save the Dikta shortcut file: %1").arg(file.errorString());
        return false;
    }
    return true;
}

bool runHyprctl(const QStringList &args, QByteArray &output, QString &error)
{
    QProcess process;
    process.start(QStringLiteral("hyprctl"), args);
    if (!process.waitForStarted(3000) || !process.waitForFinished(5000)) {
        process.kill();
        process.waitForFinished();
        error = QObject::tr("Could not run hyprctl %1: %2").arg(args.join(' '), process.errorString());
        return false;
    }
    output = process.readAllStandardOutput();
    const QString detail = QString::fromUtf8(process.readAllStandardError()).trimmed();
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        error = QObject::tr("hyprctl %1 failed: %2").arg(args.join(' '), detail.isEmpty() ? QString::fromUtf8(output).trimmed() : detail);
        return false;
    }
    return true;
}

bool bindings(QJsonArray &result, QString &error)
{
    QByteArray output;
    if (!runHyprctl({QStringLiteral("-j"), QStringLiteral("binds")}, output, error))
        return false;
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(output, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isArray()) {
        error = QObject::tr("Cannot interpret the Hyprland binding list.");
        return false;
    }
    result = doc.array();
    return true;
}

bool reload(QString &error)
{
    QByteArray output;
    if (!runHyprctl({QStringLiteral("reload")}, output, error))
        return false;
    if (output.trimmed() != "ok") {
        error = QObject::tr("Hyprland rejected the reload: %1").arg(QString::fromUtf8(output).trimmed());
        return false;
    }
    if (!runHyprctl({QStringLiteral("configerrors")}, output, error))
        return false;
    if (!output.trimmed().isEmpty()) {
        error = QObject::tr("Hyprland configuration errors: %1").arg(QString::fromUtf8(output).trimmed());
        return false;
    }
    return true;
}

QString keyName(int key)
{
    if ((key >= Qt::Key_A && key <= Qt::Key_Z) || (key >= Qt::Key_0 && key <= Qt::Key_9))
        return QString(QChar(key));
    if (key >= Qt::Key_F1 && key <= Qt::Key_F35)
        return QStringLiteral("F%1").arg(key - Qt::Key_F1 + 1);
    switch (key) {
    case Qt::Key_Space: return QStringLiteral("SPACE");
    case Qt::Key_Tab: return QStringLiteral("TAB");
    case Qt::Key_Backspace: return QStringLiteral("BACKSPACE");
    case Qt::Key_Return: return QStringLiteral("RETURN");
    case Qt::Key_Insert: return QStringLiteral("INSERT");
    case Qt::Key_Delete: return QStringLiteral("DELETE");
    case Qt::Key_Home: return QStringLiteral("HOME");
    case Qt::Key_End: return QStringLiteral("END");
    case Qt::Key_PageUp: return QStringLiteral("PRIOR");
    case Qt::Key_PageDown: return QStringLiteral("NEXT");
    case Qt::Key_Left: return QStringLiteral("LEFT");
    case Qt::Key_Right: return QStringLiteral("RIGHT");
    case Qt::Key_Up: return QStringLiteral("UP");
    case Qt::Key_Down: return QStringLiteral("DOWN");
    case Qt::Key_Minus: return QStringLiteral("MINUS");
    case Qt::Key_Equal: return QStringLiteral("EQUAL");
    case Qt::Key_Comma: return QStringLiteral("COMMA");
    case Qt::Key_Period: return QStringLiteral("PERIOD");
    case Qt::Key_Slash: return QStringLiteral("SLASH");
    case Qt::Key_Semicolon: return QStringLiteral("SEMICOLON");
    case Qt::Key_Apostrophe: return QStringLiteral("APOSTROPHE");
    case Qt::Key_BracketLeft: return QStringLiteral("BRACKETLEFT");
    case Qt::Key_BracketRight: return QStringLiteral("BRACKETRIGHT");
    case Qt::Key_Backslash: return QStringLiteral("BACKSLASH");
    case Qt::Key_QuoteLeft: return QStringLiteral("GRAVE");
    default: return {};
    }
}
}

Hotkey::Hotkey(QObject *parent) : QObject(parent)
{
    QByteArray data;
    bool exists = false;
    if (readConfig(data, exists, m_error) && exists)
        m_current = shortcutFromData(data);
}

bool Hotkey::fail(const QString &message)
{
    m_error = message;
    emit changed();
    return false;
}

bool Hotkey::ensureDefault()
{
    QByteArray data;
    bool exists = false;
    QString error;
    if (!readConfig(data, exists, error))
        return fail(error);
    if (exists) {
        m_current = shortcutFromData(data);
        m_error.clear();
        emit changed();
        return true;
    }
    return setShortcut(Qt::Key_Space, Qt::AltModifier);
}

bool Hotkey::setShortcut(int key, int modifiers)
{
    const int allowed = Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier | Qt::MetaModifier;
    const QString name = keyName(key);
    if (name.isEmpty() || !(modifiers & allowed) || (modifiers & ~allowed))
        return fail(tr("Choose a supported key with Ctrl, Alt, Shift, or Super. Escape cancels."));

    QStringList parts;
    int mask = 0;
    if (modifiers & Qt::ControlModifier) { parts << QStringLiteral("CTRL"); mask |= 4; }
    if (modifiers & Qt::AltModifier) { parts << QStringLiteral("ALT"); mask |= 8; }
    if (modifiers & Qt::ShiftModifier) { parts << QStringLiteral("SHIFT"); mask |= 1; }
    if (modifiers & Qt::MetaModifier) { parts << QStringLiteral("SUPER"); mask |= 64; }
    parts << name;
    const QString shortcut = parts.join(QStringLiteral(" + "));

    if (!QDir().mkpath(QFileInfo(configPath()).absolutePath()))
        return fail(tr("Cannot create the Dikta configuration directory."));
    QLockFile lock(configPath() + QStringLiteral(".lock"));
    if (!lock.tryLock(1000))
        return fail(tr("Another process is changing the Dikta shortcut."));

    QByteArray previous;
    bool existed = false;
    QString error;
    if (!readConfig(previous, existed, error))
        return fail(error);
    QJsonArray currentBindings;
    if (!bindings(currentBindings, error))
        return fail(error);
    for (const QJsonValue &value : currentBindings) {
        const QJsonObject binding = value.toObject();
        if (binding.value(QStringLiteral("modmask")).toInt(-1) != mask
            || binding.value(QStringLiteral("description")).toString() == description)
            continue;
        const QString boundKey = binding.value(QStringLiteral("key")).toString();
        if (boundKey.compare(name, Qt::CaseInsensitive) == 0
            || binding.value(QStringLiteral("catch_all")).toBool()
            || binding.value(QStringLiteral("keycode")).toInt() != 0) {
            const QString label = binding.value(QStringLiteral("description")).toString();
            return fail(tr("This shortcut conflicts with an existing Hyprland binding%1.")
                        .arg(label.isEmpty() ? QString() : QStringLiteral(": ") + label));
        }
    }

    const QByteArray replacement = prefix + shortcut.toUtf8() + suffix;
    if (!saveConfig(replacement, error))
        return fail(error);
    bool applied = reload(error);
    if (applied) {
        QJsonArray updated;
        applied = bindings(updated, error);
        bool found = false;
        for (const QJsonValue &value : updated) {
            const QJsonObject binding = value.toObject();
            if (binding.value(QStringLiteral("description")).toString() == description
                && binding.value(QStringLiteral("modmask")).toInt(-1) == mask
                && binding.value(QStringLiteral("key")).toString().compare(name, Qt::CaseInsensitive) == 0) {
                found = true;
                break;
            }
        }
        if (applied && !found) {
            applied = false;
            error = tr("Hyprland did not load the Dikta shortcut. Check that bindings.lua loads ~/.config/dikta/shortcuts.lua.");
        }
    }
    if (!applied) {
        QString rollbackError;
        const bool restored = existed ? saveConfig(previous, rollbackError) : QFile::remove(configPath());
        if (!restored && rollbackError.isEmpty())
            rollbackError = tr("Could not remove the new shortcut file.");
        if (restored) {
            QString reloadError;
            if (!reload(reloadError))
                rollbackError = tr("The old file was restored, but Hyprland could not reload it: %1").arg(reloadError);
        }
        if (!rollbackError.isEmpty())
            error += QStringLiteral("\n") + rollbackError;
        return fail(error);
    }
    m_current = shortcut;
    m_error.clear();
    emit changed();
    return true;
}
