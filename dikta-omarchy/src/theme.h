#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QTimer>

class Theme : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString accent READ accent NOTIFY changed)
public:
    explicit Theme(QObject *parent = nullptr);
    QString accent() const { return m_accent; }
    QString foreground() const { return m_foreground; }
signals:
    void changed();
private:
    void reload();
    QString m_accent = "#FFD60A";
    QString m_foreground = "#eeeeee";
    QFileSystemWatcher m_watcher;
    QTimer m_debounce;
};
