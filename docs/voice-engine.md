# Android 原生语音引擎

范围：**Android / macOS / Windows**。iOS 以后补，Dart 接口不变。

---

## 架构

```
Flutter (Dart) ──MethodChannel/EventChannel──┐
                                             ↓
   VoiceEnginePlugin (进程内单例)  ←── AudioRecord / AudioTrack / AudioManager
                                             ↑
                        VoiceAssistantService (只调 startForeground() 保活)
```

- 引擎是**进程内单例**，Service **不拥有**引擎，只负责让系统不杀进程。
- 采集和播放是两个**独立原生阻塞线程**，不跑在 Flutter main isolate 上。
- 切后台时 Dart isolate 照常运行，WebSocket / STT / LLM 留在 Dart。

---

## Dart 契约（定死，以后不改）

```dart
abstract class VoiceEngine {
  static VoiceEngine get instance =>
      Platform.isIOS ? IosVoiceEngine() : AndroidVoiceEngine();

  Future<void> beginSession();      // FGS + setMode + AEC + 开采集/播放，幂等
  Future<void> endSession();        // 释放全部资源，幂等
  Future<void> pushPlayback(Uint8List pcm16le);
  Future<void> flushPlayback();     // 打断：清空播放缓冲
  Stream<Uint8List> get micPcm;     // 16-bit LE / mono / 16k
  Stream<double> get micLevel;      // dBFS
  Stream<bool> get interruption;    // 来电、被其他 App 抢占
}
```

接口里**不出现** `audioSource` / `audioManagerMode` / `AVAudioSessionCategory` 等平台概念，全部藏在实现里。

VAD / 打断判定由 Dart（Rust FFI）负责，原生只提供 `micPcm` 和 `micLevel`。

---

## Android 三件套

| 组件 | 配置 |
|---|---|
| `AudioRecord` | `AudioSource.VOICE_COMMUNICATION`（系统强制开 AEC + NS）<br>采样率查设备实际支持值（通常 16k 或 48k）<br>`ENCODING_PCM_16BIT` |
| `AudioTrack` | ⚠️ `AudioAttributes` 用 **`USAGE_VOICE_COMMUNICATION` + `CONTENT_TYPE_SPEECH`**<br>用 `USAGE_MEDIA` 会导致 AEC 拿不到参考信号 ← 最容易踩且插件看不出来<br>`ENCODING_PCM_16BIT` + `MODE_STREAM` |
| `AudioManager` | `setMode(MODE_IN_COMMUNICATION)`<br>`setSpeakerphoneOn(true)`<br>`requestAudioFocus()` |

**性能模式取舍**：`AudioTrack` 用 `PERFORMANCE_MODE_LOW_LATENCY` 延迟低，但官方文档写明 *"Effects may not work"* —— AEC 本身就是 effect。必须实测。

**重采样**：Dart 声明的播放速率 ≠ 设备支持速率时，由原生重采样，Dart 不感知。

---

## 前台服务必配

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

<service android:name=".VoiceAssistantService"
    android:foregroundServiceType="microphone|mediaPlayback"
    android:exported="false" />
```

- `NotificationChannel` 用 `IMPORTANCE_LOW` —— **渠道重要性创建后不可改**。
- `startForeground()` 必须在 `startForegroundService()` 后 **5 秒内**调用，否则崩溃。
- 通知设 `setOngoing(true)` + 静默，加一个「结束」按钮。
- ⚠️ Service 必须在 App **前台**时启动，后台启动会 `SecurityException`。
- ⚠️ 小米 HyperOS 需手动开：自启动 / 省电策略无限制 / 后台弹出界面。

---

## 实测矩阵

基线：`VOICE_COMMUNICATION` + `USAGE_VOICE_COMMUNICATION` + `NONE` + 手动 AEC 关 + speakerphone 开。

在此基础上**一次只动一个变量**：

| 变量 | 对比值 |
|---|---|
| 采集源 | `VOICE_COMMUNICATION` / `MIC` |
| 播放属性 | `USAGE_VOICE_COMMUNICATION` / `USAGE_MEDIA` |
| 性能模式 | `NONE` / `LOW_LATENCY` |
| 手动 AEC effect | 开 / 关 |
| speakerphone | 开 / 关 |

**判据**：播测试音频时 `micLevel` 接近静默；用户说话时明显抬升。
**同时测**：按 Home / 锁屏 / 5 分钟后回来。

---

## macOS 实现说明

macOS 走的是**同一套 Dart 契约和通道名**，原生实现在 `macos/Runner/Voice/`：

| 文件 | 职责 |
| --- | --- |
| `VoiceEnginePlugin.swift` | 四条 channel、方法分发、麦克风权限、Ogg 解码串行队列 |
| `MacVoiceEngine.swift` | AVAudioEngine 采集/播放图、VPIO、epoch/flush/head/backlog |
| `AudioSupport.swift` | `MicFramer`、`PlaybackTimeline`、RMS —— 不依赖 AVFoundation |
| `OggOpusCodec.swift` | 流式 Ogg Opus 解码、上行 Ogg Opus 编码（libopus + libogg） |

关键语义（Windows 已按这个实现；Linux 以后照这个实现）：

- 采集固定切成 **20ms 一帧的 mono PCM16LE**；`format.channels` 恒为 1，
  `framesPerChunk = sampleRate / 50`。
- 播放块带 `epoch`，小于当前值的直接丢；`flushPlayback(newEpoch)` 抬高 epoch、
  清空设备缓冲、播放头归零，并返回没播出去的帧数。
- `playbackBacklogFrames = scheduled - played`，包含播放节点内部缓冲；
  `playbackHeadMs` 从 `AVAudioPlayerNode.playerTime(forNodeTime:)` 推算。
- 电平 ~30Hz：mic 用 VPIO 处理后的输入，playback 用 mainMixer 混音后的输出；
  100ms 没有播放数据报 `-120`。
- macOS 没有音频焦点：别的 App 放声音不会打断我们；只有设备变化/睡眠唤醒
  会补一对 `interruptionBegan(transient=true)` / `interruptionEnded`。
- `startService`/`stopService` 是 no-op；`setVolumeKeyClearsQueue` 只存值。
- 「停止说话」「结束对话」目前没有 macOS 菜单入口，这两个事件不会触发。

构建：

```bash
bash tools/build_opus_macos.sh     # libopus/libogg → macos/Vendor（静态）
bash tools/build_rust_macos.sh     # Rust dylib + ORT → macos/Frameworks
flutter build macos --release
```

Xcode 的 Build Phases 会自动跑这两个脚本，并把 dylib 嵌进
`Contents/Frameworks`。Rust/ORT 的查找路径在 `AppDelegate` 里通过
`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` 和 `ORT_DYLIB_PATH` 设置，
Dart 侧没有 macOS 分支。

平台分支只允许出现在两个地方：`lib/src/voice/mic_permission.dart`（macOS
用原生 `AVCaptureDevice`，其余平台回落 `permission_handler`）和上面的原生
runner。controller/UI 不应该出现 `Platform.isMacOS`。

## Windows 实现说明

Windows 走同一套 Dart 契约和通道名，原生实现在 `windows/runner/voice/`：

| 文件 | 职责 |
| --- | --- |
| `voice_engine_plugin.cpp` | 四条 channel、方法分发、麦克风权限/设置页 |
| `win_voice_engine.cpp` | miniaudio（WASAPI shared mode）duplex 采集/播放、epoch/flush/head/backlog、AEC 接线 |
| `ogg_opus_codec.cpp` | Ogg Opus 流式解码、上行编码（libopus + libogg） |
| `audio_support.cpp` | RMS 电平 |

关键语义：

- 统一 **16 kHz / mono / int16**，20ms 一帧（320 samples）。Dart 侧按这个格式
  重采样上行和下行的 TTS；Windows 原生不再做第二套采样率协商。
- 采集和播放用 miniaudio 的 `ma_device_type_duplex`，WASAPI shared mode，
  不用 communications 模式（避免系统 APO 再挂一套 AEC）。
- 回声消除用 Windows 自带的 **Voice Capture DSP**：`CLSID_CWMAudioAEC`
  （`mfwmaaec.dll`），filter mode，两路输入：
  - stream 0：麦克风；
  - stream 1：我们正在写入播放设备的 PCM（不是 WASAPI loopback）。

  这样只消自己的 TTS，不会把用户正在播放的音乐也消掉。DMO 跑在独立的
  MTA 线程上，音频回调只投递成对的 `(mic, reference)` 20ms 块。
- DMO 初始化失败（N 版缺 Media Feature Pack、精简系统、驱动异常）时自动
  退回**半双工**：播放期间门控麦克风，用户仍可用界面上的停止按钮打断。
- 播放头按“从上次 flush 起实际从队列里播出的采样数”计算；flush 归零，
  和 Android/macOS 的语义一致。
- `startService`/`stopService` 是 no-op；Windows 没有前台服务概念。
- 麦克风权限：首次采集时由系统隐私开关决定；`openMicSettings` 打开
  `ms-settings:privacy-microphone`。`permission_handler_windows` 对
  microphone 一律返回 granted，不能作为真实权限判断。

构建：

```powershell
pwsh -File tools/build_windows.ps1   # miniaudio + libopus/libogg + Rust DLL + ORT
flutter build windows --release
```

产物目录 `build\windows\x64\runner\Release` 需要包含
`pp_friend.exe`、`rust_lib_pp_friend.dll`、`onnxruntime.dll` 和
`data/flutter_assets`。CI 的 `windows` job 会验证这些文件并打 zip。

## iOS 以后要补什么

| Dart 接口 | Android 实现 | iOS 实现 |
|---|---|---|
| `beginSession` | `setMode` + FGS + 开 AEC | `AVAudioSession` category=`playAndRecord`, mode=**`voiceChat`**, `setActive(true)` |
| 采集 | `AudioRecord` | `AVAudioEngine` inputNode |
| 播放 | `AudioTrack` | `AVAudioEngine` playerNode |
| `interruption` | 音频焦点丢失回调 | `AVAudioSession.interruptionNotification` |
| 保活 | 前台服务 | `UIBackgroundModes: audio` |

⚠️ iOS 会话必须**全程保持 active**，频繁 `deactivate`/`activate` 会重建路由并重置 AEC 滤波器。
