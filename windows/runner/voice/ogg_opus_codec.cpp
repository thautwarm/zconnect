#include "ogg_opus_codec.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>
#include <random>
#include <utility>

namespace pp_friend {
namespace voice {

namespace {

constexpr int kOpusSampleRate = 48000;

// Opus 单包允许的最大帧长：120ms @ 48kHz。
constexpr int kMaxFrameSamples = 5760;

// 和 Swift 一样，每次往 ogg_sync_state 里搬 4096 字节再抽页。
constexpr size_t kSyncChunkSize = 4096;

// Opus 编码器的 lookahead：48kHz 下 312 个采样，写进 OpusHead 的 pre-skip。
constexpr uint16_t kEncoderPreSkip = 312;

// 单帧 Opus 包的上界（Swift 也用 4000 字节）。
constexpr size_t kEncodeBufferSize = 4000;

void SetError(std::string* error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

void ResetOutput(DecodedPcm* out) {
  if (out != nullptr) {
    out->pcm16le.clear();
    out->sample_rate = 0;
    out->channels = 0;
  }
}

void AppendUInt16Le(std::vector<uint8_t>* out, uint16_t value) {
  out->push_back(static_cast<uint8_t>(value & 0xFFu));
  out->push_back(static_cast<uint8_t>((value >> 8) & 0xFFu));
}

void AppendUInt32Le(std::vector<uint8_t>* out, uint32_t value) {
  out->push_back(static_cast<uint8_t>(value & 0xFFu));
  out->push_back(static_cast<uint8_t>((value >> 8) & 0xFFu));
  out->push_back(static_cast<uint8_t>((value >> 16) & 0xFFu));
  out->push_back(static_cast<uint8_t>((value >> 24) & 0xFFu));
}

// 把 ogg_stream_flush / ogg_stream_pageout 已经生成的完整页追加到输出。
void DrainPages(ogg_stream_state* stream, bool flush,
                std::vector<uint8_t>* output) {
  ogg_page page{};
  for (;;) {
    const int got =
        flush ? ogg_stream_flush(stream, &page)
              : ogg_stream_pageout(stream, &page);
    if (got == 0) {
      break;
    }
    if (page.header != nullptr && page.header_len > 0) {
      output->insert(output->end(), page.header,
                     page.header + page.header_len);
    }
    if (page.body != nullptr && page.body_len > 0) {
      output->insert(output->end(), page.body, page.body + page.body_len);
    }
  }
}

void PacketIn(ogg_stream_state* stream, const std::vector<uint8_t>& data,
              int64_t granule, bool bos, bool eos, int64_t number) {
  ogg_packet packet{};
  packet.packet = const_cast<unsigned char*>(data.data());
  packet.bytes = static_cast<long>(data.size());
  packet.b_o_s = bos ? 1 : 0;
  packet.e_o_s = eos ? 1 : 0;
  packet.granulepos = static_cast<ogg_int64_t>(granule);
  packet.packetno = static_cast<ogg_int64_t>(number);
  ogg_stream_packetin(stream, &packet);
}

struct StreamClear {
  ogg_stream_state* state;
  ~StreamClear() { ogg_stream_clear(state); }
};

int32_t RandomSerial() {
  static std::mt19937 rng{std::random_device{}()};
  std::uniform_int_distribution<int32_t> dist(
      1, std::numeric_limits<int32_t>::max() - 1);
  return dist(rng);
}

struct OpusEncoderDeleter {
  void operator()(OpusEncoder* encoder) const {
    opus_encoder_destroy(encoder);
  }
};

bool MuxOgg(const std::vector<std::vector<uint8_t>>& packets,
            int sample_rate, int channels, int samples_per_packet,
            std::vector<uint8_t>* out, std::string* error) {
  ogg_stream_state stream{};
  const int32_t serial = RandomSerial();
  if (ogg_stream_init(&stream, static_cast<int>(serial)) != 0) {
    SetError(error, "Ogg 错误：ogg_stream_init 失败");
    return false;
  }
  StreamClear stream_clear{&stream};

  std::vector<uint8_t> output;
  output.reserve(1024 + packets.size() * 128);

  // OpusHead：v1、声道数、pre-skip（48k 采样）、原始输入采样率、增益 0、
  // 映射族 0（单声道不需要 channel mapping table）。
  const char kOpusHeadMagic[] = "OpusHead";
  std::vector<uint8_t> head;
  head.reserve(19);
  head.insert(head.end(), kOpusHeadMagic, kOpusHeadMagic + 8);
  head.push_back(1);  // version
  head.push_back(static_cast<uint8_t>(channels));
  AppendUInt16Le(&head, kEncoderPreSkip);
  AppendUInt32Le(&head, static_cast<uint32_t>(sample_rate));
  AppendUInt16Le(&head, 0);  // output gain
  head.push_back(0);         // mapping family
  PacketIn(&stream, head, 0, true, false, 0);
  DrainPages(&stream, true, &output);

  // OpusTags：vendor 长度 + vendor 字符串 + comment 条数。
  // comment 条数不能省 —— 少了这 4 个字节，包尾就是截断的，
  // libopusfile 这类严格解析器会直接判定流损坏（服务端表现为 502）。
  const char kVendor[] = "pp_friend";
  const char kOpusTagsMagic[] = "OpusTags";
  std::vector<uint8_t> tags;
  tags.reserve(8 + 4 + sizeof(kVendor) - 1 + 4);
  tags.insert(tags.end(), kOpusTagsMagic, kOpusTagsMagic + 8);
  AppendUInt32Le(&tags, static_cast<uint32_t>(sizeof(kVendor) - 1));
  tags.insert(tags.end(), kVendor, kVendor + sizeof(kVendor) - 1);
  AppendUInt32Le(&tags, 0);  // comment count
  PacketIn(&stream, tags, 0, false, false, 1);
  DrainPages(&stream, true, &output);

  int64_t granule = static_cast<int64_t>(kEncoderPreSkip);
  const size_t packet_count = packets.size();
  for (size_t i = 0; i < packet_count; ++i) {
    // 每个 20ms 帧在 48k 下是 960 个采样。
    const int64_t samples_48k = static_cast<int64_t>(samples_per_packet) *
                                kOpusSampleRate /
                                static_cast<int64_t>(sample_rate);
    granule += samples_48k;
    PacketIn(&stream, packets[i], granule, false, i + 1 == packet_count,
             static_cast<int64_t>(i) + 2);
    // 第一包之后立刻刷一页，保证「第一个音频页不是最后一页」。
    // libsndfile（服务端转写常用的解码器）对只有单个数据页的文件会报
    // "First data page is also the last ... malformed"，短句直接被拒。
    if (i == 0 || i + 1 == packet_count) {
      DrainPages(&stream, true, &output);
    } else {
      DrainPages(&stream, false, &output);
    }
  }

  if (out != nullptr) {
    *out = std::move(output);
  }
  return true;
}

}  // namespace

OggOpusDecoder::OggOpusDecoder() = default;

OggOpusDecoder::~OggOpusDecoder() { Reset(); }

void OggOpusDecoder::Reset() {
  if (decoder_ != nullptr) {
    opus_decoder_destroy(decoder_);
    decoder_ = nullptr;
  }
  if (stream_inited_) {
    ogg_stream_clear(&stream_state_);
    stream_inited_ = false;
  }
  ogg_sync_clear(&sync_state_);
  sync_state_ = ogg_sync_state{};
  stream_state_ = ogg_stream_state{};
  serial_ = 0;
  channels_ = 1;
  pre_skip_ = 0;
  skipped_ = 0;
  packet_index_ = 0;
  saw_headers_ = false;
}

bool OggOpusDecoder::Feed(const uint8_t* data, size_t size, DecodedPcm* out,
                          std::string* error) {
  ResetOutput(out);
  if (error != nullptr) {
    error->clear();
  }
  if (size > 0 && data == nullptr) {
    SetError(error, "Ogg 错误：输入为空指针");
    return false;
  }

  std::vector<uint8_t> output;
  size_t offset = 0;
  while (offset < size) {
    const size_t chunk = std::min(kSyncChunkSize, size - offset);
    char* buffer = ogg_sync_buffer(&sync_state_, static_cast<long>(chunk));
    if (buffer == nullptr) {
      SetError(error, "Ogg 错误：ogg_sync_buffer 返回空");
      return false;
    }
    std::memcpy(buffer, data + offset, chunk);
    ogg_sync_wrote(&sync_state_, static_cast<long>(chunk));
    offset += chunk;

    for (;;) {
      ogg_page page{};
      const int got = ogg_sync_pageout(&sync_state_, &page);
      if (got == 0) {
        break;
      }
      if (got < 0) {
        continue;  // 坏页/hole：跳过，让后面的包继续
      }
      if (!ProcessPage(&page, &output, error)) {
        return false;
      }
    }
  }

  if (output.empty()) {
    return true;
  }
  if (out != nullptr) {
    out->pcm16le = std::move(output);
    out->sample_rate = kOpusSampleRate;
    out->channels = channels_;
  }
  return true;
}

bool OggOpusDecoder::Finish(DecodedPcm* out, std::string* error) {
  // 这条回复结束：下一条回复可能复用同一个 serial，也可能换一个。
  // 不清理的话，旧的 packet 序号/granule 会带进下一条流。
  Reset();
  ResetOutput(out);
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

bool OggOpusDecoder::ProcessPage(ogg_page* page,
                                 std::vector<uint8_t>* output,
                                 std::string* error) {
  const int32_t page_serial = static_cast<int32_t>(ogg_page_serialno(page));

  // 每条回复是一条独立的逻辑流，serial 不同。serial 变了就丢掉旧的
  // stream/decoder，并且必须从新的 OpusHead 重新开始。
  if (stream_inited_ && page_serial != serial_) {
    ogg_stream_clear(&stream_state_);
    stream_state_ = ogg_stream_state{};
    stream_inited_ = false;
    if (decoder_ != nullptr) {
      opus_decoder_destroy(decoder_);
      decoder_ = nullptr;
    }
    channels_ = 1;
    pre_skip_ = 0;
    skipped_ = 0;
    packet_index_ = 0;
    saw_headers_ = false;
  }

  if (!stream_inited_) {
    if (ogg_stream_init(&stream_state_, static_cast<int>(page_serial)) != 0) {
      SetError(error, "Ogg 错误：ogg_stream_init 失败");
      return false;
    }
    serial_ = page_serial;
    stream_inited_ = true;
  }
  if (ogg_stream_pagein(&stream_state_, page) != 0) {
    SetError(error, "Ogg 错误：ogg_stream_pagein 失败");
    return false;
  }

  ogg_packet packet{};
  while (ogg_stream_packetout(&stream_state_, &packet) == 1) {
    const int index = packet_index_;
    ++packet_index_;
    if (!saw_headers_) {
      if (!ParseHeaders(packet, index, output, error)) {
        return false;
      }
    } else {
      if (!DecodePacket(packet, output, error)) {
        return false;
      }
    }
  }
  return true;
}

bool OggOpusDecoder::ParseHeaders(const ogg_packet& packet, int packet_index,
                                  std::vector<uint8_t>* output,
                                  std::string* error) {
  if (packet.packet == nullptr) {
    SetError(error, "Ogg Opus 头不对：空包");
    return false;
  }
  const uint8_t* bytes = packet.packet;
  const size_t count =
      packet.bytes > 0 ? static_cast<size_t>(packet.bytes) : size_t{0};

  if (packet_index == 0) {
    if (count < 19) {
      SetError(error, "Ogg Opus 头不对：OpusHead 太短");
      return false;
    }
    if (std::memcmp(bytes, "OpusHead", 8) != 0) {
      SetError(error, "Ogg Opus 头不对：缺 OpusHead");
      return false;
    }
    const int channel_count = static_cast<int>(bytes[9]);
    // pre-skip 是 48kHz 下的采样数（LE UInt16）。
    pre_skip_ =
        static_cast<int>(bytes[10]) | (static_cast<int>(bytes[11]) << 8);

    int err = 0;
    OpusDecoder* decoder =
        opus_decoder_create(kOpusSampleRate, channel_count, &err);
    if (err != OPUS_OK || decoder == nullptr) {
      if (decoder != nullptr) {
        opus_decoder_destroy(decoder);
      }
      SetError(error,
               "Opus 错误：opus_decoder_create 失败：" + std::to_string(err));
      return false;
    }
    if (decoder_ != nullptr) {
      opus_decoder_destroy(decoder_);
    }
    decoder_ = decoder;
    channels_ = channel_count;
    skipped_ = 0;
    return true;
  }

  if (packet_index == 1) {
    const bool is_tags =
        count >= 8 && std::memcmp(bytes, "OpusTags", 8) == 0;
    if (is_tags) {
      saw_headers_ = true;
      return true;
    }
  }

  // 没有 OpusTags 的流（不合规但存在）：直接当音频处理。
  saw_headers_ = true;
  return DecodePacket(packet, output, error);
}

bool OggOpusDecoder::DecodePacket(const ogg_packet& packet,
                                  std::vector<uint8_t>* output,
                                  std::string* error) {
  if (decoder_ == nullptr) {
    SetError(error, "Ogg Opus 头不对：还没见到 OpusHead");
    return false;
  }
  if (packet.packet == nullptr || packet.bytes <= 0) {
    return true;
  }

  // 120ms @ 48k 是 Opus 允许的最大帧；每声道留足这么多样本。
  std::vector<int16_t> pcm(
      static_cast<size_t>(kMaxFrameSamples) *
          static_cast<size_t>(channels_),
      int16_t{0});
  const int decoded =
      opus_decode(decoder_, packet.packet, static_cast<opus_int32>(packet.bytes),
                  pcm.data(), kMaxFrameSamples, 0);
  if (decoded < 0) {
    SetError(error, "Opus 错误：opus_decode 失败：" + std::to_string(decoded));
    return false;
  }

  const int frames = decoded;
  int start = 0;
  if (skipped_ < pre_skip_) {
    const int drop = std::min(pre_skip_ - skipped_, frames);
    skipped_ += drop;
    start = drop;
  }
  const int usable = frames - start;
  if (usable <= 0) {
    return true;
  }

  // Windows 上 int16_t 就是小端，直接按内存布局输出交错 PCM。
  const size_t sample_offset =
      static_cast<size_t>(start) * static_cast<size_t>(channels_);
  const size_t byte_count = static_cast<size_t>(usable) *
                            static_cast<size_t>(channels_) * sizeof(int16_t);
  const uint8_t* base = reinterpret_cast<const uint8_t*>(pcm.data());
  const uint8_t* begin = base + sample_offset * sizeof(int16_t);
  output->insert(output->end(), begin, begin + byte_count);
  return true;
}

bool OggOpusEncoder::Available() {
  int err = 0;
  OpusEncoder* encoder =
      opus_encoder_create(kOpusSampleRate, 1, OPUS_APPLICATION_VOIP, &err);
  if (encoder == nullptr) {
    return false;
  }
  opus_encoder_destroy(encoder);
  return err == OPUS_OK;
}

bool OggOpusEncoder::Encode(const uint8_t* pcm16le, size_t size,
                            int sample_rate, int channels,
                            std::vector<uint8_t>* out, std::string* error) {
  if (out == nullptr) {
    SetError(error, "Opus 错误：输出为空指针");
    return false;
  }
  out->clear();
  if (error != nullptr) {
    error->clear();
  }

  const bool supported_rate = sample_rate == 8000 || sample_rate == 12000 ||
                              sample_rate == 16000 || sample_rate == 24000 ||
                              sample_rate == 48000;
  if (!supported_rate) {
    SetError(error, "Opus 错误：不支持的采样率 " + std::to_string(sample_rate));
    return false;
  }
  if (channels != 1) {
    SetError(error, "Opus 错误：目前只支持单声道");
    return false;
  }
  if (pcm16le == nullptr && size != 0) {
    SetError(error, "Opus 错误：空 PCM");
    return false;
  }

  const size_t sample_count = size / sizeof(int16_t);
  std::vector<int16_t> samples(sample_count, int16_t{0});
  if (sample_count > 0) {
    std::memcpy(samples.data(), pcm16le,
                sample_count * sizeof(int16_t));
  }
  if (samples.empty()) {
    SetError(error, "Opus 错误：空 PCM");
    return false;
  }

  int err = 0;
  OpusEncoder* raw_encoder = opus_encoder_create(
      static_cast<opus_int32>(sample_rate), channels, OPUS_APPLICATION_VOIP,
      &err);
  if (raw_encoder == nullptr) {
    SetError(error,
             "Opus 错误：opus_encoder_create 失败：" + std::to_string(err));
    return false;
  }
  std::unique_ptr<OpusEncoder, OpusEncoderDeleter> encoder(raw_encoder);
  if (err != OPUS_OK) {
    SetError(error,
             "Opus 错误：opus_encoder_create 失败：" + std::to_string(err));
    return false;
  }

  const int frame_samples = sample_rate / 50;  // 20ms
  std::vector<std::vector<uint8_t>> packets;
  packets.reserve((samples.size() + static_cast<size_t>(frame_samples) - 1) /
                  static_cast<size_t>(frame_samples));

  std::vector<uint8_t> encoded(kEncodeBufferSize, 0);
  std::vector<int16_t> frame(static_cast<size_t>(frame_samples), int16_t{0});
  for (size_t index = 0; index < samples.size();
       index += static_cast<size_t>(frame_samples)) {
    const size_t available =
        std::min(static_cast<size_t>(frame_samples), samples.size() - index);
    // 最后一帧不足 20ms 时补零，和 Swift 的 frame.append(...) 一致。
    std::fill(frame.begin(), frame.end(), int16_t{0});
    std::memcpy(frame.data(), samples.data() + index,
                available * sizeof(int16_t));

    const int written = opus_encode(
        encoder.get(), frame.data(), frame_samples, encoded.data(),
        static_cast<opus_int32>(encoded.size()));
    if (written <= 0) {
      SetError(error, "Opus 错误：opus_encode 失败：" +
                          std::to_string(written));
      return false;
    }
    packets.emplace_back(encoded.begin(), encoded.begin() + written);
  }

  return MuxOgg(packets, sample_rate, channels, frame_samples, out, error);
}

}  // namespace voice
}  // namespace pp_friend
