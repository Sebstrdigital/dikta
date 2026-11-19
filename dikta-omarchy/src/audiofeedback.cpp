#include "audiofeedback.h"

#include <QAudioSink>
#include <QDebug>
#include <QMediaDevices>
#include <QtGlobal>
#include <cmath>
#include <cstring>

AudioFeedback::AudioFeedback() = default;
AudioFeedback::~AudioFeedback() = default;

void AudioFeedback::recordingStarted() { play(true); }
void AudioFeedback::recordingStopped() { play(false); }

QByteArray AudioFeedback::makeCue(const QAudioFormat &format, double start, double end,
                                  double duration, double attack)
{
    const int rate = format.sampleRate();
    const int channels = format.channelCount();
    const int frames = int(rate * duration);
    const int attackFrames = int(rate * attack);
    const int bytes = format.bytesPerSample();
    if (rate <= 0 || channels <= 0 || bytes <= 0 || attackFrames <= 0 || frames <= attackFrames)
        return {};

    QByteArray output(frames * channels * bytes, Qt::Uninitialized);
    char *cursor = output.data();
    double phase = 0;
    constexpr double tau = 6.2831853071795864769;
    for (int i = 0; i < frames; ++i) {
        const double progress = double(i) / frames;
        const double envelope = i < attackFrames ? double(i) / attackFrames
            : 1.0 - double(i - attackFrames) / (frames - attackFrames);
        const double value = std::sin(phase) * 0.25 * envelope * envelope;
        for (int channel = 0; channel < channels; ++channel) {
            switch (format.sampleFormat()) {
            case QAudioFormat::UInt8: {
                const quint8 sample = quint8(qBound(0, int(std::lround(128.0 + value * 127.0)), 255));
                std::memcpy(cursor, &sample, sizeof(sample));
                break;
            }
            case QAudioFormat::Int16: {
                const qint16 sample = qint16(std::lround(value * 32767.0));
                std::memcpy(cursor, &sample, sizeof(sample));
                break;
            }
            case QAudioFormat::Int32: {
                const qint32 sample = qint32(std::llround(value * 2147483647.0));
                std::memcpy(cursor, &sample, sizeof(sample));
                break;
            }
            case QAudioFormat::Float: {
                const float sample = float(value);
                std::memcpy(cursor, &sample, sizeof(sample));
                break;
            }
            default:
                return {};
            }
            cursor += bytes;
        }
        phase += tau * start * std::pow(end / start, progress) / rate;
        if (phase > tau)
            phase -= tau;
    }
    return output;
}

void AudioFeedback::configure(const QAudioDevice &device)
{
    m_sink.reset();
    m_buffer.close();
    m_device = device;
    m_startCue.clear();
    m_stopCue.clear();
    if (device.isNull()) {
        qWarning() << "Dikta: no audio output device for feedback";
        return;
    }
    const QAudioFormat format = device.preferredFormat();
    m_startCue = makeCue(format, 280, 580, 0.15, 0.02);
    m_stopCue = makeCue(format, 520, 320, 0.12, 0.015);
    if (m_startCue.isEmpty() || m_stopCue.isEmpty()) {
        qWarning() << "Dikta: unsupported audio feedback format" << format;
        return;
    }
    m_sink = std::make_unique<QAudioSink>(device, format);
}

void AudioFeedback::play(bool start)
{
    const QAudioDevice device = QMediaDevices::defaultAudioOutput();
    if (!m_sink || device != m_device)
        configure(device);
    if (!m_sink)
        return;
    m_sink->stop();
    m_buffer.close();
    m_buffer.setData(start ? m_startCue : m_stopCue);
    if (!m_buffer.open(QIODevice::ReadOnly)) {
        qWarning() << "Dikta: cannot open audio feedback buffer";
        return;
    }
    m_sink->start(&m_buffer);
}
