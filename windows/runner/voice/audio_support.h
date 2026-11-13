#ifndef RUNNER_VOICE_AUDIO_SUPPORT_H_
#define RUNNER_VOICE_AUDIO_SUPPORT_H_

#include <cstddef>
#include <cstdint>

namespace pp_friend {
namespace voice {

/// RMS → dBFS。静默返回 -120，和 Android/macOS 的约定一致。
double RmsDb(const int16_t* samples, size_t count);
double RmsDb(const float* samples, size_t count);

/// int16 样本转 dBFS，避免每帧都构造 vector。
double RmsDb(const int16_t* samples, size_t count, double gain);

}  // namespace voice
}  // namespace pp_friend

#endif  // RUNNER_VOICE_AUDIO_SUPPORT_H_
