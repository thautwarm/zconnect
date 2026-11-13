#include "voice_engine_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "win_voice_engine.h"

namespace pp_friend {
namespace voice {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodChannel;
using flutter::MethodResult;
using flutter::StandardMethodCodec;
using flutter::StreamHandlerError;
using flutter::StreamHandlerFunctions;

constexpr char kMethodChannelName[] = "pp_friend/voice_engine";
constexpr char kMicChannelName[] = "pp_friend/voice_engine/mic";
constexpr char kLevelsChannelName[] = "pp_friend/voice_engine/levels";
constexpr char kEventsChannelName[] = "pp_friend/voice_engine/events";

const EncodableMap* ArgumentsOf(const MethodCall<EncodableValue>& call) {
  return std::get_if<EncodableMap>(call.arguments());
}

int64_t GetInt64(const EncodableMap& args, const char* key,
                 int64_t fallback = 0) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<double>(&it->second)) {
    return static_cast<int64_t>(*value);
  }
  return fallback;
}

bool GetBool(const EncodableMap& args, const char* key, bool fallback) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
}

const std::vector<uint8_t>* GetBytes(const EncodableMap& args,
                                     const char* key) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return nullptr;
  return std::get_if<std::vector<uint8_t>>(&it->second);
}

EncodableValue DecodedValue(const DecodedPcm& decoded) {
  EncodableMap map;
  map[EncodableValue("pcm")] = EncodableValue(decoded.pcm16le);
  map[EncodableValue("sampleRate")] = EncodableValue(decoded.sample_rate);
  map[EncodableValue("channels")] = EncodableValue(decoded.channels);
  return EncodableValue(map);
}

struct SinkHolder {
  std::shared_ptr<flutter::EventSink<EncodableValue>> sink;
  std::atomic<bool> active{true};
};

}  // namespace

class VoiceEnginePluginImpl {
 public:
  explicit VoiceEnginePluginImpl(flutter::FlutterEngine* engine)
      : engine_(engine),
        method_channel_(std::make_unique<MethodChannel<EncodableValue>>(
            engine->messenger(), kMethodChannelName,
            &StandardMethodCodec::GetInstance())),
        mic_channel_(std::make_unique<flutter::EventChannel<EncodableValue>>(
            engine->messenger(), kMicChannelName,
            &StandardMethodCodec::GetInstance())),
        levels_channel_(std::make_unique<flutter::EventChannel<EncodableValue>>(
            engine->messenger(), kLevelsChannelName,
            &StandardMethodCodec::GetInstance())),
        events_channel_(std::make_unique<flutter::EventChannel<EncodableValue>>(
            engine->messenger(), kEventsChannelName,
            &StandardMethodCodec::GetInstance())) {
    method_channel_->SetMethodCallHandler(
        [this](const MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
          HandleMethodCall(call, std::move(result));
        });

    WireEvents();

    WinVoiceEngine::Instance().SetCallbacks(
        [this](const uint8_t* pcm, size_t size) { PostMic(pcm, size); },
        [this](double mic_db, double playback_db) {
          PostLevels(mic_db, playback_db);
        },
        [this](const std::string& type, const std::string& detail) {
          PostEvent(type, detail);
        });
  }

  ~VoiceEnginePluginImpl() {
    WinVoiceEngine::Instance().ClearCallbacks();
    WinVoiceEngine::Instance().Stop();
    DetachSinks();
  }

 private:
  void WireEvents() {
    mic_channel_->SetStreamHandler(
        std::make_unique<StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
                -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
              auto holder = std::make_shared<SinkHolder>();
              holder->sink = std::shared_ptr<flutter::EventSink<EncodableValue>>(
                  std::move(events));
              {
                std::lock_guard<std::mutex> lock(sink_mutex_);
                mic_sink_ = std::move(holder);
              }
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
              DetachMicSink();
              return nullptr;
            }));

    levels_channel_->SetStreamHandler(
        std::make_unique<StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
                -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
              auto holder = std::make_shared<SinkHolder>();
              holder->sink = std::shared_ptr<flutter::EventSink<EncodableValue>>(
                  std::move(events));
              {
                std::lock_guard<std::mutex> lock(sink_mutex_);
                levels_sink_ = std::move(holder);
              }
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
              DetachLevelsSink();
              return nullptr;
            }));

    events_channel_->SetStreamHandler(
        std::make_unique<StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
                -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
              auto holder = std::make_shared<SinkHolder>();
              holder->sink = std::shared_ptr<flutter::EventSink<EncodableValue>>(
                  std::move(events));
              {
                std::lock_guard<std::mutex> lock(sink_mutex_);
                events_sink_ = std::move(holder);
              }
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
              DetachEventsSink();
              return nullptr;
            }));
  }

  void DetachMicSink() {
    std::shared_ptr<SinkHolder> holder;
    {
      std::lock_guard<std::mutex> lock(sink_mutex_);
      holder = std::move(mic_sink_);
    }
    if (holder) holder->active = false;
  }

  void DetachLevelsSink() {
    std::shared_ptr<SinkHolder> holder;
    {
      std::lock_guard<std::mutex> lock(sink_mutex_);
      holder = std::move(levels_sink_);
    }
    if (holder) holder->active = false;
  }

  void DetachEventsSink() {
    std::shared_ptr<SinkHolder> holder;
    {
      std::lock_guard<std::mutex> lock(sink_mutex_);
      holder = std::move(events_sink_);
    }
    if (holder) holder->active = false;
  }

  void DetachSinks() {
    DetachMicSink();
    DetachLevelsSink();
    DetachEventsSink();
  }

  template <typename T>
  void SendToPlatform(std::shared_ptr<SinkHolder> holder, T value) {
    if (!holder || !holder->active || engine_ == nullptr) return;
    engine_->PostPlatformThreadTask(
        [holder = std::move(holder), value = std::move(value)]() mutable {
          if (!holder->active || !holder->sink) return;
          holder->sink->Success(value);
        });
  }

  void PostMic(const uint8_t* pcm, size_t size) {
    if (pcm == nullptr || size == 0) return;
    std::shared_ptr<SinkHolder> holder;
    {
      std::lock_guard<std::mutex> lock(sink_mutex_);
      holder = mic_sink_;
    }
    if (!holder || !holder->active) return;
    std::vector<uint8_t> bytes(pcm, pcm + size);
    SendToPlatform(std::move(holder), EncodableValue(std::move(bytes)));
  }

  void PostLevels(double mic_db, double playback_db) {
    std::shared_ptr<SinkHolder> holder;
    {
      std::lock_guard<std::mutex> lock(sink_mutex_);
      holder = levels_sink_;
    }
    if (!holder || !holder->active) return;
    SendToPlatform(std::move(holder),
                   EncodableValue(std::vector<double>{mic_db, playback_db}));
  }

  void PostEvent(const std::string& type, const std::string& detail) {
    std::shared_ptr<SinkHolder> holder;
    {
      std::lock_guard<std::mutex> lock(sink_mutex_);
      holder = events_sink_;
    }
    if (!holder || !holder->active) return;

    EncodableMap map;
    map[EncodableValue("type")] = EncodableValue(type);
    if (!detail.empty()) {
      map[EncodableValue("reason")] = EncodableValue(detail);
    }
    SendToPlatform(std::move(holder), EncodableValue(std::move(map)));
  }

  void HandleMethodCall(const MethodCall<EncodableValue>& call,
                        std::unique_ptr<MethodResult<EncodableValue>> result) {
    const std::string& method = call.method_name();
    const EncodableMap* args = ArgumentsOf(call);
    auto& engine = WinVoiceEngine::Instance();

    if (method == "startService" || method == "stopService") {
      result->Success(EncodableValue(true));
      return;
    }
    if (method == "serviceRunning") {
      result->Success(EncodableValue(false));
      return;
    }
    if (method == "applyDebugProfile") {
      result->Success(args == nullptr ? EncodableValue(EncodableMap{})
                                      : EncodableValue(*args));
      return;
    }
    if (method == "setVolumeKeyClearsQueue") {
      engine.SetVolumeKeyClearsQueue(
          args != nullptr ? GetBool(*args, "enabled", true) : true);
      result->Success(EncodableValue(true));
      return;
    }
    if (method == "startAudio") {
      std::string error;
      if (!engine.Start(&error)) {
        result->Error("startAudioFailed", error);
        return;
      }
      const AudioFormatInfo format = engine.Format();
      EncodableMap map;
      map[EncodableValue("sampleRate")] = EncodableValue(format.sample_rate);
      map[EncodableValue("channels")] = EncodableValue(format.channels);
      map[EncodableValue("framesPerChunk")] =
          EncodableValue(format.frames_per_chunk);
      // Dart 目前忽略多余字段；留给以后在 UI 上显示 AEC 状态。
      map[EncodableValue("aecActive")] = EncodableValue(engine.AecActive());
      result->Success(EncodableValue(std::move(map)));
      return;
    }
    if (method == "stopAudio") {
      engine.Stop();
      result->Success(EncodableValue(true));
      return;
    }
    if (method == "pushPlayback") {
      if (args == nullptr) {
        result->Error("badArgs", "pushPlayback 需要参数");
        return;
      }
      const auto* pcm = GetBytes(*args, "pcm");
      if (pcm == nullptr) {
        result->Error("badArgs", "pushPlayback 需要 pcm");
        return;
      }
      engine.PushPlayback(pcm->data(), pcm->size(), GetInt64(*args, "epoch"));
      result->Success();
      return;
    }
    if (method == "flushPlayback") {
      const int64_t new_epoch =
          args != nullptr ? GetInt64(*args, "newEpoch") : 0;
      result->Success(EncodableValue(engine.FlushPlayback(new_epoch)));
      return;
    }
    if (method == "playbackBacklogFrames") {
      result->Success(EncodableValue(engine.PlaybackBacklogFrames()));
      return;
    }
    if (method == "playbackHeadMs") {
      result->Success(EncodableValue(engine.PlaybackHeadMs()));
      return;
    }
    if (method == "droppedMicFrames") {
      result->Success(EncodableValue(engine.DroppedMicFrames()));
      return;
    }
    if (method == "isAudioRunning") {
      result->Success(EncodableValue(engine.IsRunning()));
      return;
    }
    if (method == "opusEncoderAvailable") {
      result->Success(EncodableValue(engine.OpusEncoderAvailable()));
      return;
    }
    if (method == "encodeOpus") {
      if (args == nullptr) {
        result->Error("badArgs", "encodeOpus 需要参数");
        return;
      }
      const auto* pcm = GetBytes(*args, "pcm");
      if (pcm == nullptr) {
        result->Error("badArgs", "encodeOpus 需要 pcm");
        return;
      }
      const int sample_rate = static_cast<int>(GetInt64(*args, "sampleRate"));
      const int channels = static_cast<int>(GetInt64(*args, "channels", 1));
      std::vector<uint8_t> encoded;
      std::string error;
      if (!engine.EncodeOpus(pcm->data(), pcm->size(), sample_rate, channels,
                             &encoded, &error)) {
        result->Success();
        return;
      }
      result->Success(EncodableValue(std::move(encoded)));
      return;
    }
    if (method == "decodeAudio") {
      if (args == nullptr) {
        result->Error("badArgs", "decodeAudio 需要参数");
        return;
      }
      const auto* bytes = GetBytes(*args, "bytes");
      if (bytes == nullptr) {
        result->Error("badArgs", "decodeAudio 需要 bytes");
        return;
      }
      DecodedPcm decoded;
      std::string error;
      if (!engine.DecodeAudio(bytes->data(), bytes->size(), &decoded, &error)) {
        result->Error("decodeFailed", error);
        return;
      }
      result->Success(DecodedValue(decoded));
      return;
    }
    if (method == "feedOggStream") {
      if (args == nullptr) {
        result->Error("badArgs", "feedOggStream 需要参数");
        return;
      }
      const auto* bytes = GetBytes(*args, "bytes");
      if (bytes == nullptr) {
        result->Error("badArgs", "feedOggStream 需要 bytes");
        return;
      }
      DecodedPcm decoded;
      std::string error;
      if (!engine.FeedOggStream(bytes->data(), bytes->size(), &decoded,
                                &error)) {
        result->Error("decodeFailed", error);
        return;
      }
      if (decoded.pcm16le.empty()) {
        result->Success();
        return;
      }
      result->Success(DecodedValue(decoded));
      return;
    }
    if (method == "finishOggStream") {
      DecodedPcm decoded;
      std::string error;
      if (!engine.FinishOggStream(&decoded, &error)) {
        result->Error("decodeFailed", error);
        return;
      }
      if (decoded.pcm16le.empty()) {
        result->Success();
        return;
      }
      result->Success(DecodedValue(decoded));
      return;
    }
    if (method == "resetOggStream") {
      engine.ResetOggStream();
      result->Success();
      return;
    }
    if (method == "requestMicPermission") {
      result->Success(EncodableValue(true));
      return;
    }
    if (method == "micPermissionStatus") {
      // Windows 的麦克风隐私开关在首次采集时由系统处理；这里不假装能查询。
      result->Success(EncodableValue("authorized"));
      return;
    }
    if (method == "openMicSettings") {
      ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-microphone",
                    nullptr, nullptr, SW_SHOWNORMAL);
      result->Success(EncodableValue(true));
      return;
    }
    if (method == "probeLocalNetwork") {
      // Windows 没有 macOS 15 的本地网络授权概念。
      result->Success(EncodableValue("ready"));
      return;
    }
    if (method == "openLocalNetworkSettings") {
      result->Success(EncodableValue(false));
      return;
    }

    result->NotImplemented();
  }

  flutter::FlutterEngine* engine_;
  std::unique_ptr<MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> mic_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> levels_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_channel_;

  std::mutex sink_mutex_;
  std::shared_ptr<SinkHolder> mic_sink_;
  std::shared_ptr<SinkHolder> levels_sink_;
  std::shared_ptr<SinkHolder> events_sink_;
};

void VoiceEnginePlugin::Register(flutter::FlutterEngine* engine) {
  if (engine == nullptr) return;
  // 通道 handler 由单例自己持有；不保留实例的话，通道会被提前释放。
  static VoiceEnginePluginImpl* instance = new VoiceEnginePluginImpl(engine);
  (void)instance;
}

}  // namespace voice
}  // namespace pp_friend
