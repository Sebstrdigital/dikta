#include "backend.h"

#include <QDateTime>
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
#include <fcntl.h>
#include <unistd.h>

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
    startWorker();
}

Backend::~Backend()
{
    disconnect(&m_process, nullptr, this, nullptr);
    disconnect(&m_worker, nullptr, this, nullptr);
    if (m_worker.state() != QProcess::NotRunning) {
        m_worker.kill();
        m_worker.waitForFinished(1000);
    }
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
    m_timingClock.start();
    m_timing = QJsonObject();
    m_captureStartedAt = m_stoppedAt = m_copyStartedAt = m_pasteStartedAt = -1;
    m_dictationTiming = true;
    ++m_generation;
    m_temporaryDir = std::make_unique<QTemporaryDir>();
    if (!m_temporaryDir->isValid()) {
        finish(QStringLiteral("Could not create a temporary directory for recording."),
               QStringLiteral("failed"), QStringLiteral("setup"));
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
    m_stoppedAt = m_timingClock.elapsed();
    if (m_captureStartedAt >= 0)
        m_timing.insert(QStringLiteral("recording_ms"), double(m_stoppedAt - m_captureStartedAt));
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
            finish(QStringLiteral("Could not stop microphone recording: ffmpeg timed out."),
                   QStringLiteral("failed"), QStringLiteral("capture"));
        }
    });
    if (m_phase == Phase::Capture && m_process.state() == QProcess::Running) {
        if (m_process.write("q\n") < 0) {
            m_phase = Phase::Idle;
            m_process.kill();
            m_process.waitForFinished(1000);
            finish(QStringLiteral("Could not stop the microphone recording."),
                   QStringLiteral("failed"), QStringLiteral("capture"));
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
        m_captureStartedAt = m_timingClock.elapsed();
        if (m_stoppedAt >= 0)
            m_timing.insert(QStringLiteral("recording_ms"), 0);
        if (m_stopRequested) {
            if (m_process.write("q\n") < 0) {
                m_phase = Phase::Idle;
                m_process.kill();
                m_process.waitForFinished(1000);
                finish(QStringLiteral("Could not stop the microphone recording."),
                       QStringLiteral("failed"), QStringLiteral("capture"));
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
            finish(QStringLiteral("Could not write to the Wayland clipboard."),
                   QStringLiteral("failed"), QStringLiteral("copy"));
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
            if (m_stoppedAt >= 0)
                m_timing.insert(QStringLiteral("stop_to_audio_ready_ms"),
                                double(m_timingClock.elapsed() - m_stoppedAt));
            m_audioFeedback.recordingStopped();
            m_phase = Phase::Transcribe;
            m_status = QStringLiteral("Transcribing…");
            emit changed();
            if (m_workerState == WorkerState::Starting) {
                m_workerWait.start();
            } else if (m_workerState == WorkerState::Ready) {
                m_timing.insert(QStringLiteral("model_init_ms"), 0);
                sendTranscription();
            } else {
                finish(m_workerFailure, QStringLiteral("failed"), m_workerFailureStage);
            }
        }
        break;
    case Phase::Transcribe:
        break;
    case Phase::Copy:
        if (m_dictationTiming && m_copyStartedAt >= 0)
            m_timing.insert(QStringLiteral("copy_ms"), double(m_timingClock.elapsed() - m_copyStartedAt));
        if (!success) {
            finish(m_warning + processFailure(QStringLiteral("Could not copy to the Wayland clipboard")));
        } else if (!m_pasteAfterCopy) {
            finish(QStringLiteral("Copied to clipboard."));
        } else if (m_targetWindow.isEmpty()) {
            finish(m_warning + QStringLiteral("Copied to clipboard; original focused window could not be identified, so nothing was pasted."),
                   QStringLiteral("copied_no_paste"));
        } else {
            m_phase = Phase::InspectPaste;
            startProcess(QStringLiteral("hyprctl"), {QStringLiteral("-j"), QStringLiteral("activewindow")});
        }
        break;
    case Phase::InspectPaste:
        if (!success || activeWindowAddress() != m_targetWindow) {
            finish(m_warning + QStringLiteral("Copied to clipboard; focus changed or could not be verified, so nothing was pasted."),
                   QStringLiteral("copied_no_paste"));
        } else {
            m_phase = Phase::Paste;
            m_pasteStartedAt = m_timingClock.elapsed();
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
                       : m_warning + processFailure(QStringLiteral("Copied to clipboard, but paste failed")),
               success ? QStringLiteral("pasted") : QStringLiteral("failed"));
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
        finish(m_warning + QStringLiteral("Copied to clipboard; focus could not be verified, so nothing was pasted."),
               QStringLiteral("copied_no_paste"));
    } else {
        const QString program = m_process.program();
        finish(m_warning + QStringLiteral("Could not start %1: %2").arg(program, m_process.errorString()));
    }
}

void Backend::startWorker()
{
    connect(&m_worker, &QProcess::readyReadStandardOutput, this, &Backend::readWorkerOutput);
    connect(&m_worker, &QProcess::readyReadStandardError, this, [this] {
        m_workerErrors += m_worker.readAllStandardError();
        m_workerErrors = m_workerErrors.right(1000);
    });
    connect(&m_worker, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart || error == QProcess::Crashed
            || error == QProcess::WriteError || error == QProcess::ReadError) {
            workerFailed(QStringLiteral("Transcription worker failed: %1").arg(m_worker.errorString()),
                         m_workerState == WorkerState::Starting ? QStringLiteral("model_init")
                                                                : QStringLiteral("transcribe"));
        }
    });
    connect(&m_worker, qOverload<int, QProcess::ExitStatus>(&QProcess::finished),
            this, [this](int, QProcess::ExitStatus) {
        readWorkerOutput();
        const QString details = QString::fromUtf8(m_workerErrors).trimmed();
        workerFailed(details.isEmpty() ? QStringLiteral("Transcription worker exited unexpectedly.")
                                       : QStringLiteral("Transcription worker exited: %1").arg(details),
                     m_workerState == WorkerState::Starting ? QStringLiteral("model_init")
                                                            : QStringLiteral("transcribe"));
    });
    m_worker.start(QStringLiteral("dikta-transcribe"), {QStringLiteral("--worker")});
}

void Backend::workerFailed(const QString &message, const QString &stage)
{
    if (m_workerState == WorkerState::Failed)
        return;
    m_workerState = WorkerState::Failed;
    m_workerFailure = message;
    m_workerFailureStage = stage;
    m_workerRequestSent = false;
    if (m_worker.state() != QProcess::NotRunning)
        m_worker.kill();
    if (m_phase == Phase::Transcribe) {
        if (m_workerWait.isValid())
            m_timing.insert(QStringLiteral("model_init_ms"), double(m_workerWait.elapsed()));
        finish(message, QStringLiteral("failed"), stage);
    } else {
        if (m_phase == Phase::Idle) {
            m_status = message;
            emit changed();
        }
        notify(message);
    }
}

void Backend::sendTranscription()
{
    if (m_phase != Phase::Transcribe || m_workerState != WorkerState::Ready || m_workerRequestSent)
        return;
    QJsonObject request;
    request.insert(QStringLiteral("audio_path"), m_audioPath);
    const QByteArray line = QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n';
    m_workerRequestSent = true;
    if (m_worker.write(line) != line.size())
        workerFailed(QStringLiteral("Could not send audio to the transcription worker: %1")
                         .arg(m_worker.errorString()), QStringLiteral("transcribe"));
}

void Backend::readWorkerOutput()
{
    m_workerOutput += m_worker.readAllStandardOutput();
    while (m_workerState != WorkerState::Failed) {
        const qsizetype newline = m_workerOutput.indexOf('\n');
        if (newline < 0)
            return;
        const QByteArray line = m_workerOutput.left(newline);
        m_workerOutput.remove(0, newline + 1);
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(line, &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
            workerFailed(QStringLiteral("Invalid response from transcription worker."),
                         QStringLiteral("transcribe"));
            return;
        }
        const QJsonObject response = document.object();
        const QString type = response.value(QStringLiteral("type")).toString();
        if (m_workerState == WorkerState::Starting && type == QStringLiteral("ready")
            && response.value(QStringLiteral("model_init_ms")).isDouble()
            && response.value(QStringLiteral("model_init_ms")).toDouble() >= 0) {
            m_workerState = WorkerState::Ready;
            if (m_phase == Phase::Transcribe) {
                m_timing.insert(QStringLiteral("model_init_ms"), double(m_workerWait.elapsed()));
                m_workerWait.invalidate();
                sendTranscription();
            }
        } else if ((m_workerState == WorkerState::Starting && type == QStringLiteral("init_error"))
                   || (m_workerState == WorkerState::Ready && m_workerRequestSent
                       && type == QStringLiteral("error"))) {
            const QJsonValue error = response.value(QStringLiteral("error"));
            const QString stage = response.value(QStringLiteral("failure_stage")).toString();
            if (!error.isString() || stage.isEmpty()) {
                workerFailed(QStringLiteral("Invalid error from transcription worker."),
                             QStringLiteral("transcribe"));
                return;
            }
            const QString safeStage = (stage == QStringLiteral("model_files") || stage == QStringLiteral("audio")
                                       || stage == QStringLiteral("model_init") || stage == QStringLiteral("decode"))
                ? stage : QStringLiteral("transcribe");
            const QString message = QStringLiteral("Transcription failed: %1").arg(error.toString());
            if (type == QStringLiteral("init_error")) {
                workerFailed(message, safeStage);
            } else {
                m_workerRequestSent = false;
                finish(message, QStringLiteral("failed"), safeStage);
            }
        } else if (m_workerState == WorkerState::Ready && m_workerRequestSent
                   && type == QStringLiteral("result")
                   && response.value(QStringLiteral("text")).isString()
                   && response.value(QStringLiteral("decode_ms")).isDouble()
                   && response.value(QStringLiteral("decode_ms")).toDouble() >= 0) {
            m_workerRequestSent = false;
            m_timing.insert(QStringLiteral("decode_ms"), response.value(QStringLiteral("decode_ms")));
            completeTranscription(response.value(QStringLiteral("text")).toString().trimmed());
        } else {
            workerFailed(QStringLiteral("Unexpected response from transcription worker."),
                         QStringLiteral("transcribe"));
            return;
        }
    }
}

void Backend::completeTranscription(const QString &text)
{
    if (text.isEmpty()) {
        finish(QStringLiteral("No speech was transcribed."), QStringLiteral("no_speech"));
        return;
    }
    m_history.prepend(text);
    while (m_history.size() > 5)
        m_history.removeLast();
    if (!saveHistory())
        m_warning = QStringLiteral("Could not save transcript history. ");
    emit changed();
    copyText(text, true);
}

void Backend::writeTiming(const QString &outcome, const QString &failureStage)
{
    const qint64 now = m_timingClock.elapsed();
    if (m_captureStartedAt >= 0 && m_stoppedAt < 0)
        m_timing.insert(QStringLiteral("recording_ms"), double(now - m_captureStartedAt));
    if (m_copyStartedAt >= 0 && !m_timing.contains(QStringLiteral("copy_ms")))
        m_timing.insert(QStringLiteral("copy_ms"), double(now - m_copyStartedAt));
    if (m_pasteStartedAt >= 0)
        m_timing.insert(QStringLiteral("paste_ms"), double(now - m_pasteStartedAt));
    if (m_stoppedAt >= 0) {
        m_timing.insert(QStringLiteral("stop_to_finish_ms"), double(now - m_stoppedAt));
        if (outcome == QStringLiteral("pasted"))
            m_timing.insert(QStringLiteral("stop_to_paste_ms"), double(now - m_stoppedAt));
    }
    m_timing.insert(QStringLiteral("timestamp_utc"), QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    m_timing.insert(QStringLiteral("outcome"), outcome);
    if (outcome == QStringLiteral("failed")) {
        QString stage = failureStage;
        if (stage.isEmpty()) {
            switch (m_phase) {
            case Phase::InspectStart: case Phase::Capture: stage = QStringLiteral("capture"); break;
            case Phase::Transcribe:
                stage = m_timing.value(QStringLiteral("transcription_failure_stage")).toString();
                if (stage.isEmpty()) stage = QStringLiteral("transcribe");
                break;
            case Phase::Copy: stage = QStringLiteral("copy"); break;
            case Phase::InspectPaste: stage = QStringLiteral("inspect_paste"); break;
            case Phase::Paste: stage = QStringLiteral("paste"); break;
            case Phase::Idle: stage = QStringLiteral("setup"); break;
            }
        }
        m_timing.insert(QStringLiteral("failure_stage"), stage);
    }
    m_timing.remove(QStringLiteral("transcription_failure_stage"));
    m_dictationTiming = false;

    QString stateHome = qEnvironmentVariable("XDG_STATE_HOME");
    if (stateHome.isEmpty() || !QDir::isAbsolutePath(stateHome))
        stateHome = QDir::homePath() + QStringLiteral("/.local/state");
    const QString directory = stateHome + QStringLiteral("/dikta");
    if (!QDir().mkpath(directory))
        return;
    const QByteArray path = QFile::encodeName(directory + QStringLiteral("/timings.jsonl"));
    const int fd = ::open(path.constData(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0)
        return;
    const QByteArray line = QJsonDocument(m_timing).toJson(QJsonDocument::Compact) + '\n';
    (void)::write(fd, line.constData(), size_t(line.size()));
    ::close(fd);
}

void Backend::finish(const QString &status, const QString &outcome, const QString &failureStage)
{
    if (m_dictationTiming)
        writeTiming(outcome, failureStage);
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
    if (paste && m_dictationTiming)
        m_copyStartedAt = m_timingClock.elapsed();
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
