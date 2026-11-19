#pragma once

#include <QAudioDevice>
#include <QAudioFormat>
#include <QBuffer>
#include <QByteArray>
#include <memory>

class QAudioSink;

class AudioFeedback
{
public:
    AudioFeedback();
    ~AudioFeedback();
    void recordingStarted();
    void recordingStopped();

private:
    void play(bool start);
    void configure(const QAudioDevice &device);
    static QByteArray makeCue(const QAudioFormat &format, double start, double end,
                              double duration, double attack);

    QAudioDevice m_device;
    QBuffer m_buffer;
    QByteArray m_startCue;
    QByteArray m_stopCue;
    std::unique_ptr<QAudioSink> m_sink;
};
