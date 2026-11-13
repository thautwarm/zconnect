#ifndef RUNNER_VOICE_VOICE_ENGINE_PLUGIN_H_
#define RUNNER_VOICE_VOICE_ENGINE_PLUGIN_H_

namespace flutter {
class FlutterEngine;
}

namespace pp_friend {
namespace voice {

/// 把 Windows 语音引擎接到 Flutter 的 MethodChannel/EventChannel 上。
///
/// 通道名、方法名、事件字段与 Android `VoiceEnginePlugin.kt`、macOS
/// `VoiceEnginePlugin.swift` 保持一致；Dart 侧不需要平台分支。
class VoiceEnginePlugin {
 public:
  static void Register(flutter::FlutterEngine* engine);
};

}  // namespace voice
}  // namespace pp_friend

#endif  // RUNNER_VOICE_VOICE_ENGINE_PLUGIN_H_
