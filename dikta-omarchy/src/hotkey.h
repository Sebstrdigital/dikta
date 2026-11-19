#pragma once

#include <QObject>
#include <QString>

class Hotkey : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString current READ current NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)

public:
    explicit Hotkey(QObject *parent = nullptr);
    QString current() const { return m_current; }
    QString error() const { return m_error; }
    Q_INVOKABLE bool setShortcut(int key, int modifiers);
    Q_INVOKABLE bool ensureDefault();

signals:
    void changed();

private:
    bool fail(const QString &message);
    QString m_current;
    QString m_error;
};
