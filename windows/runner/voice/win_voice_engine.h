#ifndef RUNNER_VOICE_WIN_VOICE_ENGINE_H_
#define RUNNER_VOICE_WIN_VOICE_ENGINE_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "ogg_opus_codec.h"

namespace pp_friend {
namespace voice {

struct AudioFormatInfo {
  int sample_rate = 16000;
  int channels = 1;
  int frames_per_chunk = 320;
};

/// Windows 原生语音引擎。
///
/// 语义和 Android `NativeVoiceEngine` / macOS `MacVoiceEngine` 对齐：
/// 20ms 一帧、epoch 过滤、flush 后播放头归零、backlog 含设备缓冲、电平 ~30Hz。
///
/// 音频 I/O 走 miniaudio 的 duplex 设备（WASAPI shared mode），统一为
/// 16kHz / mono / int16。回声消除优先用 Windows 自带的 Voice Capture DSP
/// (`CLSID_CWMAudioAEC`) filter mode：把麦克风和“我们自己正在播放的 PCM”
/// 两路喂进去。DMO 初始化失败时自动退回半双工（播放时门控麦克风）。
class WinVoiceEngine {
 public:
  using MicCallback =
      std::function<void(const uint8_t* pcm16le, size_t size)>;
  using LevelsCallback = std::function<void(double mic_db, double playback_db)>;
  using EventCallback =
      std::function<void(const std::string& type, const std::string& detail)>;

  static WinVoiceEngine& Instance();

  WinVoiceEngine(const WinVoiceEngine&) = delete;
  WinVoiceEngine& operator=(const WinVoiceEngine&) = delete;

  void SetCallbacks(MicCallback mic, LevelsCallback levels,
                    EventCallback event);
  void ClearCallbacks();

  /// 打开采集/播放和 AEC。失败返回 false 并填 error。
  bool Start(std::string* error);
  void Stop();
  bool IsRunning() const;
  bool AecActive() const;

  AudioFormatInfo Format() const;

  void PushPlayback(const uint8_t* pcm16le, size_t size, int64_t epoch);
  int FlushPlayback(int64_t new_epoch);
  int PlaybackBacklogFrames() const;
  int PlaybackHeadMs() const;
  int DroppedMicFrames() const;

  bool OpusEncoderAvailable() const;
  bool EncodeOpus(const uint8_t* pcm16le, size_t size, int sample_rate,
                  int channels, std::vector<uint8_t>* out,
                  std::string* error);
  bool DecodeAudio(const uint8_t* bytes, size_t size, DecodedPcm* out,
                   std::string* error);
  bool FeedOggStream(const uint8_t* bytes, size_t size, DecodedPcm* out,
                     std::string* error);
  bool FinishOggStream(DecodedPcm* out, std::string* error);
  void ResetOggStream();

  void SetVolumeKeyClearsQueue(bool enabled);
  bool VolumeKeyClearsQueue() const;

 private:
  WinVoiceEngine();
  ~WinVoiceEngine();

  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace voice
}  // namespace pp_friend

#endif  // RUNNER_VOICE_WIN_VOICE_ENGINE_H_
