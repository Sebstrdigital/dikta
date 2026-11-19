#include "backend.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>
#include <QSettings>
#include <QTemporaryDir>
#include <QTimer>

Backend::Backend(QObject *parent) : QObject(parent)
{
    QSettings settings(QSettings::IniFormat, QSettings::UserScope, QStringLiteral("dikta"), QStringLiteral("dikta"));
    m_notificationsEnabled = settings.value(QStringLiteral("notificationsEnabled"), false).toBool();
    connect(&m_process, &QProcess::started, this, &Backend::processStarted);
    connect(&m_process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished),
            this, &Backend::processFinished);
    connect(&m_process, &QProcess::errorOccurred, this, &Backend::processError);

    QFile file(dataDirectory() + QStringLiteral("/history.json"));
    if (file.open(QIODevice::ReadOnly)) {
        const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
        if (document.isArray()) {
            for (const QJsonValue &value : document.array()) {
                if (value.isString() && !value.toString().trimmed().isEmpty())
                    m_history.append(value.toString());
                if (m_history.size() == 5)
                    break;
            }
        }
    }
}

Backend::~Backend()
{
    disconnect(&m_process, nullptr, this, nullptr);
    if (m_process.state() != QProcess::NotRunning) {
        m_process.kill();
        m_process.waitForFinished(1000);
    }
}

QString Backend::dataDirectory() const
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
        + QStringLiteral("/dikta");
}

void Backend::setNotificationsEnabled(bool enabled)
{
    if (m_notificationsEnabled == enabled)
        return;
    QSettings settings(QSettings::IniFormat, QSettings::UserScope, QStringLiteral("dikta"), QStringLiteral("dikta"));
    settings.setValue(QStringLiteral("notificationsEnabled"), enabled);
    settings.sync();
    if (settings.status() != QSettings::NoError) {
        m_status = QStringLiteral("Could not save notification setting.");
        emit changed();
        return;
    }
    m_notificationsEnabled = enabled;
    emit changed();
}

void Backend::notify(const QString &message)
{
    if (!m_notificationsEnabled)
        return;
    QProcess::startDetached(QStringLiteral("notify-send"),
                            {QStringLiteral("Dikta"), message});
}

void Backend::toggle()
{
    if (m_recording) {
        stopCapture();
    } else if (!m_busy) {
        startCapture();
    }
}

void Backend::startCapture()
{
    ++m_generation;
    m_temporaryDir = std::make_unique<QTemporaryDir>();
    if (!m_temporaryDir->isValid()) {
        finish(QStringLiteral("Could not create a temporary directory for recording."));
        return;
    }
    m_audioPath = m_temporaryDir->filePath(QStringLiteral("recording.wav"));
    m_targetWindow.clear();
    m_warning.clear();
    m_stopRequested = false;
    m_recording = true;
    m_busy = false;
    m_status = QStringLiteral("Starting recording…");
    m_phase = Phase::InspectStart;
    emit changed();
    startProcess(QStringLiteral("hyprctl"), {QStringLiteral("-j"), QStringLiteral("activewindow")});
}

void Backend::beginCapture()
{
    m_phase = Phase::Capture;
    startProcess(QStringLiteral("ffmpeg"), {
        QStringLiteral("-hide_banner"), QStringLiteral("-loglevel"), QStringLiteral("error"),
        QStringLiteral("-f"), QStringLiteral("pulse"), QStringLiteral("-i"), QStringLiteral("default"),
        QStringLiteral("-ac"), QStringLiteral("1"), QStringLiteral("-ar"), QStringLiteral("16000"),
        QStringLiteral("-c:a"), QStringLiteral("pcm_s16le"), QStringLiteral("-y"), m_audioPath
    });
}

void Backend::stopCapture()
{
    m_recording = false;
    m_busy = true;
    m_stopRequested = true;
    m_status = QStringLiteral("Stopping recording…");
    emit changed();
    notify(m_status);
    const quint64 generation = m_generation;
    QTimer::singleShot(5000, this, [this, generation] {
        if (m_generation == generation && (m_phase == Phase::InspectStart || m_phase == Phase::Capture)
            && m_stopRequested && m_process.state() != QProcess::NotRunning) {
            m_phase = Phase::Idle;
            m_process.kill();
            m_process.waitForFinished(1000);
            finish(QStringLiteral("Could not stop microphone recording: ffmpeg timed out."));
        }
    });
    if (m_phase == Phase::Capture && m_process.state() == QProcess::Running) {
        if (m_process.write("q\n") < 0) {
            m_phase = Phase::Idle;
            m_process.kill();
            m_process.waitForFinished(1000);
            finish(QStringLiteral("Could not stop the microphone recording."));
            return;
        }
        m_process.closeWriteChannel();
    }
}

void Backend::startProcess(const QString &program, const QStringList &arguments)
{
    m_process.setProgram(program);
    m_process.setArguments(arguments);
    m_process.start();
}

void Backend::processStarted()
{
    if (m_phase == Phase::Capture) {
        if (m_stopRequested) {
            if (m_process.write("q\n") < 0) {
                m_phase = Phase::Idle;
                m_process.kill();
                m_process.waitForFinished(1000);
                finish(QStringLiteral("Could not stop the microphone recording."));
                return;
            }
            m_process.closeWriteChannel();
        } else {
            m_audioFeedback.recordingStarted();
            m_status = QStringLiteral("Recording…");
            emit changed();
            notify(m_status);
        }
    } else if (m_phase == Phase::Copy) {
        if (m_process.write(m_clipboardText) < 0) {
            m_phase = Phase::Idle;
            m_process.kill();
            m_process.waitForFinished(1000);
            finish(QStringLiteral("Could not write to the Wayland clipboard."));
            return;
        }
        m_process.closeWriteChannel();
    }
}

QString Backend::activeWindowAddress()
{
    const QJsonDocument document = QJsonDocument::fromJson(m_process.readAllStandardOutput());
    m_terminal = false;
    for (const QJsonValue &tag : document.object().value(QStringLiteral("tags")).toArray()) {
        if (tag.toString() == QStringLiteral("terminal") || tag.toString() == QStringLiteral("terminal*"))
            m_terminal = true;
    }
    const QString address = document.object().value(QStringLiteral("address")).toString();
    return address == QStringLiteral("0x0") ? QString() : address;
}

QString Backend::processFailure(const QString &action)
{
    const QString details = QString::fromUtf8(m_process.readAllStandardError()).trimmed();
    return details.isEmpty() ? action : action + QStringLiteral(": ") + details.right(1000);
}

void Backend::processFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    const bool success = exitStatus == QProcess::NormalExit && exitCode == 0;
    switch (m_phase) {
    case Phase::InspectStart:
        if (success)
            m_targetWindow = activeWindowAddress();
        beginCapture();
        break;
    case Phase::Capture:
        if (!success) {
            finish(processFailure(m_stopRequested ? QStringLiteral("Could not stop microphone recording")
                                                  : QStringLiteral("Microphone recording failed")));
        } else if (!m_stopRequested) {
            finish(QStringLiteral("Microphone recording stopped unexpectedly."));
        } else {
            m_audioFeedback.recordingStopped();
            m_phase = Phase::Transcribe;
            m_status = QStringLiteral("Transcribing…");
            emit changed();
            startProcess(QStringLiteral("dikta-transcribe"), {m_audioPath});
        }
        break;
    case Phase::Transcribe: {
        if (!success) {
            finish(processFailure(QStringLiteral("Transcription failed")));
            break;
        }
        const QString text = QString::fromUtf8(m_process.readAllStandardOutput()).trimmed();
        if (text.isEmpty()) {
            finish(QStringLiteral("No speech was transcribed."));
            break;
        }
        m_history.prepend(text);
        while (m_history.size() > 5)
            m_history.removeLast();
        if (!saveHistory())
            m_warning = QStringLiteral("Could not save transcript history. ");
        emit changed();
        copyText(text, true);
        break;
    }
    case Phase::Copy:
        if (!success) {
            finish(m_warning + processFailure(QStringLiteral("Could not copy to the Wayland clipboard")));
        } else if (!m_pasteAfterCopy) {
            finish(QStringLiteral("Copied to clipboard."));
        } else if (m_targetWindow.isEmpty()) {
            finish(m_warning + QStringLiteral("Copied to clipboard; original focused window could not be identified, so nothing was pasted."));
        } else {
            m_phase = Phase::InspectPaste;
            startProcess(QStringLiteral("hyprctl"), {QStringLiteral("-j"), QStringLiteral("activewindow")});
        }
        break;
    case Phase::InspectPaste:
        if (!success || activeWindowAddress() != m_targetWindow) {
            finish(m_warning + QStringLiteral("Copied to clipboard; focus changed or could not be verified, so nothing was pasted."));
        } else {
            m_phase = Phase::Paste;
            QStringList keys = {QStringLiteral("-M"), QStringLiteral("ctrl")};
            if (m_terminal)
                keys << QStringLiteral("-M") << QStringLiteral("shift");
            keys << QStringLiteral("v");
            if (m_terminal)
                keys << QStringLiteral("-m") << QStringLiteral("shift");
            keys << QStringLiteral("-m") << QStringLiteral("ctrl");
            startProcess(QStringLiteral("wtype"), keys);
        }
        break;
    case Phase::Paste:
        finish(success ? m_warning + QStringLiteral("Transcribed and pasted.")
                       : m_warning + processFailure(QStringLiteral("Copied to clipboard, but paste failed")));
        break;
    case Phase::Idle:
        break;
    }
}

void Backend::processError(QProcess::ProcessError error)
{
    if (error != QProcess::FailedToStart)
        return;
    if (m_phase == Phase::InspectStart) {
        beginCapture();
    } else if (m_phase == Phase::InspectPaste) {
        finish(m_warning + QStringLiteral("Copied to clipboard; focus could not be verified, so nothing was pasted."));
    } else {
        const QString program = m_process.program();
        finish(m_warning + QStringLiteral("Could not start %1: %2").arg(program, m_process.errorString()));
    }
}

void Backend::finish(const QString &status)
{
    m_phase = Phase::Idle;
    m_recording = false;
    m_busy = false;
    m_stopRequested = false;
    m_clipboardText.clear();
    m_temporaryDir.reset();
    m_status = status;
    emit changed();
    notify(status);
}

void Backend::copyText(const QString &text, bool paste)
{
    m_clipboardText = text.toUtf8();
    m_pasteAfterCopy = paste;
    m_busy = true;
    m_phase = Phase::Copy;
    m_status = QStringLiteral("Copying to clipboard…");
    emit changed();
    startProcess(QStringLiteral("wl-copy"), {QStringLiteral("--type"), QStringLiteral("text/plain;charset=utf-8")});
}

void Backend::copyHistory(int index)
{
    if (m_busy || m_recording || index < 0 || index >= m_history.size())
        return;
    m_warning.clear();
    copyText(m_history.at(index), false);
}

bool Backend::saveHistory()
{
    if (!QDir().mkpath(dataDirectory()))
        return false;
    QJsonArray array;
    for (const QString &text : m_history)
        array.append(text);
    QSaveFile file(dataDirectory() + QStringLiteral("/history.json"));
    if (!file.open(QIODevice::WriteOnly))
        return false;
    const QByteArray json = QJsonDocument(array).toJson();
    return file.write(json) == json.size() && file.commit();
}
