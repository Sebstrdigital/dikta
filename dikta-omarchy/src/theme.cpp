#include "theme.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>

Theme::Theme(QObject *parent) : QObject(parent)
{
    m_debounce.setSingleShot(true);
    m_debounce.setInterval(80);
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this] { m_debounce.start(); });
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] { m_debounce.start(); });
    connect(&m_debounce, &QTimer::timeout, this, &Theme::reload);
    reload();
}

void Theme::reload()
{
    const QString current = QDir::homePath() + "/.local/state/omarchy/current";
    const QString colors = current + "/theme/colors.toml";
    const QStringList oldPaths = m_watcher.files() + m_watcher.directories();
    if (!oldPaths.isEmpty())
        m_watcher.removePaths(oldPaths);
    QString ancestor = current;
    while (!QFileInfo::exists(ancestor) && ancestor != "/")
        ancestor = QFileInfo(ancestor).absolutePath();
    QStringList paths{ancestor, QFileInfo(ancestor).absolutePath(), current, current + "/theme", colors};
    paths.removeDuplicates();
    for (const QString &path : paths)
        if (QFileInfo::exists(path))
            m_watcher.addPath(path);

    QString accent = "#FFD60A";
    QString foreground = "#eeeeee";
    QFile file(colors);
    if (file.open(QIODevice::ReadOnly)) {
        static const QRegularExpression pattern(
            R"re(^\s*accent\s*=\s*["'](#[0-9a-fA-F]{6})["'])re",
            QRegularExpression::MultilineOption);
        const QString text = QString::fromUtf8(file.readAll());
        const auto match = pattern.match(text);
        if (match.hasMatch())
            accent = match.captured(1);
        static const QRegularExpression foregroundPattern(
            R"re(^\s*foreground\s*=\s*["'](#[0-9a-fA-F]{6})["'])re",
            QRegularExpression::MultilineOption);
        const auto foregroundMatch = foregroundPattern.match(text);
        if (foregroundMatch.hasMatch())
            foreground = foregroundMatch.captured(1);
    }
    if (accent != m_accent || foreground != m_foreground) {
        m_accent = accent;
        m_foreground = foreground;
        emit changed();
    }
}
