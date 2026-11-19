#pragma once

#include "audiofeedback.h"

#include <QByteArray>
#include <QObject>
#include <QProcess>
#include <QStringList>
#include <memory>

class QTemporaryDir;

class Backend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(QStringList history READ history NOTIFY changed)
    Q_PROPERTY(bool recording READ recording NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool notificationsEnabled READ notificationsEnabled WRITE setNotificationsEnabled NOTIFY changed)

public:
    explicit Backend(QObject *parent = nullptr);
    ~Backend() override;

    QString status() const { return m_status; }
    QStringList history() const { return m_history; }
    bool recording() const { return m_recording; }
    bool busy() const { return m_busy; }
    bool notificationsEnabled() const { return m_notificationsEnabled; }
    void setNotificationsEnabled(bool enabled);

    Q_INVOKABLE void toggle();
    Q_INVOKABLE void copyHistory(int index);

signals:
    void changed();

private:
    enum class Phase { Idle, InspectStart, Capture, Transcribe, Copy, InspectPaste, Paste };

    void startCapture();
    void beginCapture();
    void stopCapture();
    void startProcess(const QString &program, const QStringList &arguments);
    void processStarted();
    void processFinished(int exitCode, QProcess::ExitStatus exitStatus);
    void processError(QProcess::ProcessError error);
    void finish(const QString &status);
    void copyText(const QString &text, bool paste);
    bool saveHistory();
    QString processFailure(const QString &action);
    void notify(const QString &message);
    QString activeWindowAddress();
    QString dataDirectory() const;

    QProcess m_process;
    AudioFeedback m_audioFeedback;
    std::unique_ptr<QTemporaryDir> m_temporaryDir;
    QStringList m_history;
    QString m_status = QStringLiteral("Ready");
    QString m_audioPath;
    QString m_targetWindow;
    QByteArray m_clipboardText;
    QString m_warning;
    Phase m_phase = Phase::Idle;
    quint64 m_generation = 0;
    bool m_recording = false;
    bool m_busy = false;
    bool m_stopRequested = false;
    bool m_pasteAfterCopy = false;
    bool m_terminal = false;
    bool m_notificationsEnabled = false;
};
