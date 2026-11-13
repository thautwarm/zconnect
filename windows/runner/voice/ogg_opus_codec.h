#ifndef RUNNER_VOICE_OGG_OPUS_CODEC_H_
#define RUNNER_VOICE_OGG_OPUS_CODEC_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include <ogg/ogg.h>
#include <opus.h>

namespace pp_friend {
namespace voice {

/// 解码出来的一块 PCM（16 位小端、交错）。
struct DecodedPcm {
  std::vector<uint8_t> pcm16le;
  int sample_rate = 0;
  int channels = 0;
};

/// 连续 Ogg Opus 流的增量解码器。
///
/// 和 macOS `OggOpusDecoder` / Android `StreamingOggDecoder` 同一套语义：
/// 允许包跨页、一页多包，第一次见到 OpusHead 才建解码器；reset 之后必须
/// 能从新的 OpusHead 重新开始。所有调用必须在同一个串行线程上（插件层负责）。
class OggOpusDecoder {
 public:
  OggOpusDecoder();
  ~OggOpusDecoder();

  OggOpusDecoder(const OggOpusDecoder&) = delete;
  OggOpusDecoder& operator=(const OggOpusDecoder&) = delete;

  /// 喂一块字节，解码出这次拿到的 PCM。
  /// 成功但没有完整包/没有可输出样本时返回 true，且 out 保持为空。
  bool Feed(const uint8_t* data, size_t size, DecodedPcm* out,
            std::string* error);

  /// 一条流结束：清理全部状态（下一条流重新从 OpusHead 开始）。
  /// 和 Swift 的 `finish()` 一样，没有剩余 PCM 可吐。
  bool Finish(DecodedPcm* out, std::string* error);

  /// 打断 / 切换回复：丢掉当前解码状态。
  void Reset();

 private:
  bool ProcessPage(ogg_page* page, std::vector<uint8_t>* output,
                   std::string* error);
  bool ParseHeaders(const ogg_packet& packet, int packet_index,
                    std::vector<uint8_t>* output, std::string* error);
  bool DecodePacket(const ogg_packet& packet, std::vector<uint8_t>* output,
                    std::string* error);

  ogg_sync_state sync_state_{};
  ogg_stream_state stream_state_{};
  bool stream_inited_ = false;
  int32_t serial_ = 0;
  OpusDecoder* decoder_ = nullptr;
  int channels_ = 1;
  int pre_skip_ = 0;
  int skipped_ = 0;
  int packet_index_ = 0;
  bool saw_headers_ = false;
};

/// 把 PCM16LE 编码成独立的 Ogg Opus 文件（上行用）。
class OggOpusEncoder {
 public:
  static bool Available();

  static bool Encode(const uint8_t* pcm16le, size_t size, int sample_rate,
                     int channels, std::vector<uint8_t>* out,
                     std::string* error);
};

}  // namespace voice
}  // namespace pp_friend

#endif  // RUNNER_VOICE_OGG_OPUS_CODEC_H_
