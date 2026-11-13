#include "win_voice_engine.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

// Windows 宏必须在任何 Windows 头（包括 miniaudio 内部）之前定义。
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

// miniaudio 的实现只放在这个 TU 里，避免每个文件都编译一遍。
#define MINIAUDIO_IMPLEMENTATION
#include <miniaudio.h>

// miniaudio 在 WIN32_LEAN_AND_MEAN 下自己定义了 CLSCTX_ALL 宏；后面的
// dmo.h/mediaobj.h 会从 combaseapi.h 再定义一次。先撤掉，避免 /W4 /WX
// 把 C4005 当成错误。
#undef CLSCTX_ALL

// Voice Capture DSP (CLSID_CWMAudioAEC / mfwmaaec.dll)。
#include <windows.h>

#include <dmo.h>
#include <mediaobj.h>
#include <mmreg.h>
#include <propsys.h>
#include <propvarutil.h>
#include <uuids.h>
#include <wmcodecdsp.h>

#include "audio_support.h"

namespace pp_friend {
namespace voice {

namespace {

constexpr int kSampleRate = 16000;
constexpr int kChannels = 1;
constexpr int kFrameSamples = 320;  // 20ms
constexpr int kFrameBytes = kFrameSamples * sizeof(int16_t);

using Clock = std::chrono::steady_clock;

std::string HrToString(HRESULT hr) {
  std::ostringstream out;
  out << "0x" << std::hex << static_cast<unsigned long>(hr);
  return out.str();
}

class CMediaBuffer final : public IMediaBuffer {
 public:
  explicit CMediaBuffer(DWORD capacity) : capacity_(capacity) {
    data_ = new (std::nothrow) BYTE[capacity];
    if (data_ == nullptr) capacity_ = 0;
  }
  ~CMediaBuffer() { delete[] data_; }

  CMediaBuffer(const CMediaBuffer&) = delete;
  CMediaBuffer& operator=(const CMediaBuffer&) = delete;

  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IMediaBuffer) {
      *ppv = static_cast<IMediaBuffer*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&ref_));
  }
  STDMETHODIMP_(ULONG) Release() override {
    const LONG ref = InterlockedDecrement(&ref_);
    if (ref == 0) delete this;
    return static_cast<ULONG>(ref);
  }
  STDMETHODIMP SetLength(DWORD length) override {
    if (length > capacity_) return E_INVALIDARG;
    length_ = length;
    return S_OK;
  }
  STDMETHODIMP GetMaxLength(DWORD* capacity) override {
    if (capacity == nullptr) return E_POINTER;
    *capacity = capacity_;
    return S_OK;
  }
  STDMETHODIMP GetBufferAndLength(BYTE** buffer, DWORD* length) override {
    if (buffer != nullptr) *buffer = data_;
    if (length != nullptr) *length = length_;
    return S_OK;
  }

  BYTE* data() { return data_; }
  DWORD capacity() const { return capacity_; }

 private:
  LONG ref_ = 1;
  BYTE* data_ = nullptr;
  DWORD capacity_ = 0;
  DWORD length_ = 0;
};

bool SetBoolProperty(IPropertyStore* store, REFPROPERTYKEY key, BOOL value) {
  PROPVARIANT prop;
  PropVariantInit(&prop);
  prop.vt = VT_BOOL;
  prop.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
  const HRESULT hr = store->SetValue(key, prop);
  PropVariantClear(&prop);
  return SUCCEEDED(hr);
}

bool SetI4Property(IPropertyStore* store, REFPROPERTYKEY key, LONG value) {
  PROPVARIANT prop;
  PropVariantInit(&prop);
  prop.vt = VT_I4;
  prop.lVal = value;
  const HRESULT hr = store->SetValue(key, prop);
  PropVariantClear(&prop);
  return SUCCEEDED(hr);
}

bool MakePcmType(WORD channels, DWORD sample_rate, WORD bits,
                 DMO_MEDIA_TYPE* type) {
  ZeroMemory(type, sizeof(*type));
  type->majortype = MEDIATYPE_Audio;
  type->subtype = MEDIASUBTYPE_PCM;
  type->bFixedSizeSamples = TRUE;
  type->bTemporalCompression = FALSE;
  type->formattype = FORMAT_WaveFormatEx;

  const HRESULT hr = MoInitMediaType(type, sizeof(WAVEFORMATEX));
  if (FAILED(hr)) return false;

  auto* format = reinterpret_cast<WAVEFORMATEX*>(type->pbFormat);
  format->wFormatTag = WAVE_FORMAT_PCM;
  format->nChannels = channels;
  format->nSamplesPerSec = sample_rate;
  format->wBitsPerSample = bits;
  format->nBlockAlign = channels * (bits / 8);
  format->nAvgBytesPerSec = sample_rate * format->nBlockAlign;
  format->cbSize = 0;
  type->lSampleSize = format->nBlockAlign;
  return true;
}

/// Voice Capture DSP 的工作线程。
///
/// DMO 是 COM 对象，而且不是多线程安全的；把它固定在自己的 MTA 线程上，
/// 音频回调只负责投递成对的 (mic, reference) 块和取走消过回声的 PCM。
class AecProcessor {
 public:
  AecProcessor() = default;
  ~AecProcessor() { Stop(); }

  AecProcessor(const AecProcessor&) = delete;
  AecProcessor& operator=(const AecProcessor&) = delete;

  bool Start(std::string* error) {
    Stop();
    {
      std::lock_guard<std::mutex> lock(init_mutex_);
      ready_ = false;
      available_ = false;
      init_error_.clear();
    }
    {
      std::lock_guard<std::mutex> lock(in_mutex_);
      stop_ = false;
      input_.clear();
    }
    {
      std::lock_guard<std::mutex> lock(out_mutex_);
      output_.clear();
      dropped_samples_ = 0;
    }

    thread_ = std::thread([this] { ThreadMain(); });

    std::unique_lock<std::mutex> lock(init_mutex_);
    init_cv_.wait(lock, [this] { return ready_; });
    if (!available_) {
      if (error != nullptr) *error = init_error_;
      return false;
    }
    return true;
  }

  void Stop() {
    {
      std::lock_guard<std::mutex> lock(in_mutex_);
      stop_ = true;
    }
    in_cv_.notify_all();
    if (thread_.joinable()) thread_.join();
    available_ = false;
  }

  bool Available() const { return available_; }

  void Push(const int16_t* mic, const int16_t* reference, size_t samples) {
    if (!available_ || mic == nullptr || reference == nullptr) return;
    Block block;
    block.mic.assign(mic, mic + samples);
    block.reference.assign(reference, reference + samples);
    {
      std::lock_guard<std::mutex> lock(in_mutex_);
      // AEC 线程跟不上时丢最旧的块：宁可短暂断一下，也不让延迟无限增长。
      while (input_.size() >= 8) {
        input_.pop_front();
        dropped_samples_ += static_cast<int>(samples);
      }
      input_.push_back(std::move(block));
    }
    in_cv_.notify_one();
  }

  size_t Pop(int16_t* out, size_t max_samples) {
    std::lock_guard<std::mutex> lock(out_mutex_);
    const size_t count = std::min(max_samples, output_.size());
    for (size_t i = 0; i < count; ++i) out[i] = output_[i];
    output_.erase(output_.begin(), output_.begin() + count);
    return count;
  }

  int DroppedSamples() const { return dropped_samples_.load(); }

 private:
  struct Block {
    std::vector<int16_t> mic;
    std::vector<int16_t> reference;
  };

  void ThreadMain() {
    const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool ok = false;
    std::string error;
    if (FAILED(com_hr)) {
      error = "CoInitializeEx 失败：" + HrToString(com_hr);
    } else {
      ok = InitDmo(&error);
      if (!ok) ReleaseDmo();
    }

    {
      std::lock_guard<std::mutex> lock(init_mutex_);
      available_ = ok;
      init_error_ = error;
      ready_ = true;
    }
    init_cv_.notify_all();

    if (ok) {
      for (;;) {
        Block block;
        {
          std::unique_lock<std::mutex> lock(in_mutex_);
          in_cv_.wait(lock, [this] { return stop_ || !input_.empty(); });
          if (stop_) break;
          block = std::move(input_.front());
          input_.pop_front();
        }
        ProcessBlock(block);
      }
    }

    ReleaseDmo();
    if (SUCCEEDED(com_hr)) CoUninitialize();
  }

  bool InitDmo(std::string* error) {
    HRESULT hr = CoCreateInstance(CLSID_CWMAudioAEC, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dmo_));
    if (FAILED(hr)) {
      *error = "CoCreateInstance(CLSID_CWMAudioAEC) 失败：" + HrToString(hr);
      return false;
    }

    hr = dmo_->QueryInterface(IID_PPV_ARGS(&properties_));
    if (FAILED(hr)) {
      *error = "IPropertyStore 不可用：" + HrToString(hr);
      return false;
    }

    // filter mode：我们自己喂 mic + 播放参考，不让 DMO 去打开设备。
    if (!SetBoolProperty(properties_, MFPKEY_WMAAECMA_DMO_SOURCE_MODE, FALSE)) {
      *error = "无法设置 filter mode";
      return false;
    }
    if (!SetI4Property(properties_, MFPKEY_WMAAECMA_SYSTEM_MODE,
                       SINGLE_CHANNEL_AEC)) {
      *error = "无法设置 SINGLE_CHANNEL_AEC";
      return false;
    }
    if (!SetBoolProperty(properties_, MFPKEY_WMAAECMA_FEATURE_MODE, TRUE)) {
      *error = "无法打开 FEATURE_MODE";
      return false;
    }
    // 注意：FEATR_NS 是 VT_I4，不是 VT_BOOL。
    SetI4Property(properties_, MFPKEY_WMAAECMA_FEATR_NS, 1);
    SetBoolProperty(properties_, MFPKEY_WMAAECMA_FEATR_AGC, FALSE);
    SetI4Property(properties_, MFPKEY_WMAAECMA_FEATR_ECHO_LENGTH, 256);

    DMO_MEDIA_TYPE mic_type{};
    DMO_MEDIA_TYPE ref_type{};
    DMO_MEDIA_TYPE out_type{};
    if (!MakePcmType(1, kSampleRate, 16, &mic_type) ||
        !MakePcmType(1, kSampleRate, 16, &ref_type) ||
        !MakePcmType(1, kSampleRate, 16, &out_type)) {
      *error = "无法构造 DMO 媒体类型";
      return false;
    }

    hr = dmo_->SetInputType(0, &mic_type, 0);
    if (SUCCEEDED(hr)) hr = dmo_->SetInputType(1, &ref_type, 0);
    if (SUCCEEDED(hr)) hr = dmo_->SetOutputType(0, &out_type, 0);
    if (SUCCEEDED(hr)) hr = dmo_->AllocateStreamingResources();

    MoFreeMediaType(&mic_type);
    MoFreeMediaType(&ref_type);
    MoFreeMediaType(&out_type);

    if (FAILED(hr)) {
      *error = "DMO 类型/资源初始化失败：" + HrToString(hr);
      return false;
    }

    DWORD lookahead = 0;
    DWORD alignment = 0;
    if (FAILED(dmo_->GetInputSizeInfo(0, &mic_input_bytes_, &lookahead,
                                      &alignment)) ||
        FAILED(dmo_->GetInputSizeInfo(1, &ref_input_bytes_, &lookahead,
                                      &alignment)) ||
        FAILED(dmo_->GetOutputSizeInfo(0, &output_bytes_, &alignment))) {
      *error = "无法读取 DMO 缓冲区大小";
      return false;
    }
    return true;
  }

  void ReleaseDmo() {
    if (properties_ != nullptr) {
      properties_->Release();
      properties_ = nullptr;
    }
    if (dmo_ != nullptr) {
      dmo_->FreeStreamingResources();
      dmo_->Release();
      dmo_ = nullptr;
    }
  }

  void ProcessBlock(const Block& block) {
    if (dmo_ == nullptr || block.mic.empty() ||
        block.mic.size() != block.reference.size()) {
      return;
    }
    const DWORD bytes =
        static_cast<DWORD>(block.mic.size() * sizeof(int16_t));

    auto* mic = new CMediaBuffer(bytes);
    auto* reference = new CMediaBuffer(bytes);
    if (mic->capacity() < bytes || reference->capacity() < bytes) {
      mic->Release();
      reference->Release();
      return;
    }
    mic->SetLength(bytes);
    reference->SetLength(bytes);
    std::memcpy(mic->data(), block.mic.data(), bytes);
    std::memcpy(reference->data(), block.reference.data(), bytes);

    HRESULT hr = dmo_->ProcessInput(0, mic, 0, 0, 0);
    if (hr == DMO_E_NOTACCEPTING) {
      DrainOutput();
      hr = dmo_->ProcessInput(0, mic, 0, 0, 0);
    }
    HRESULT hr_ref = dmo_->ProcessInput(1, reference, 0, 0, 0);
    if (hr_ref == DMO_E_NOTACCEPTING) {
      DrainOutput();
      hr_ref = dmo_->ProcessInput(1, reference, 0, 0, 0);
    }

    mic->Release();
    reference->Release();

    if (FAILED(hr) || FAILED(hr_ref)) return;
    DrainOutput();
  }

  void DrainOutput() {
    if (dmo_ == nullptr || output_bytes_ == 0) return;
    for (;;) {
      auto* out = new CMediaBuffer(output_bytes_);
      DMO_OUTPUT_DATA_BUFFER buffer{};
      buffer.pBuffer = out;
      DWORD status = 0;
      const HRESULT hr = dmo_->ProcessOutput(0, 1, &buffer, &status);
      if (SUCCEEDED(hr)) {
        DWORD length = 0;
        out->GetBufferAndLength(nullptr, &length);
        if (length > 0) {
          const size_t samples = length / sizeof(int16_t);
          const auto* data = reinterpret_cast<const int16_t*>(out->data());
          std::lock_guard<std::mutex> lock(out_mutex_);
          output_.insert(output_.end(), data, data + samples);
          // AEC 输出最多留 2 秒；再长说明消费端卡住了。
          const size_t max_samples = kSampleRate * 2;
          if (output_.size() > max_samples) {
            const size_t drop = output_.size() - max_samples;
            output_.erase(output_.begin(), output_.begin() + drop);
            dropped_samples_ += static_cast<int>(drop);
          }
        }
      }
      out->Release();
      if (FAILED(hr) || !(status & DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE)) break;
    }
  }

  std::thread thread_;
  std::mutex init_mutex_;
  std::condition_variable init_cv_;
  bool ready_ = false;
  std::atomic<bool> available_{false};
  std::string init_error_;

  std::mutex in_mutex_;
  std::condition_variable in_cv_;
  bool stop_ = false;
  std::deque<Block> input_;

  std::mutex out_mutex_;
  std::vector<int16_t> output_;
  std::atomic<int> dropped_samples_{0};

  IMediaObject* dmo_ = nullptr;
  IPropertyStore* properties_ = nullptr;
  DWORD mic_input_bytes_ = 0;
  DWORD ref_input_bytes_ = 0;
  DWORD output_bytes_ = 0;
};

}  // namespace

struct WinVoiceEngine::Impl {
  Impl() = default;
  ~Impl() { Stop(); }

  void SetCallbacks(MicCallback mic, LevelsCallback levels,
                    EventCallback event) {
    mic_callback_ = std::move(mic);
    levels_callback_ = std::move(levels);
    event_callback_ = std::move(event);
  }

  void ClearCallbacks() {
    mic_callback_ = nullptr;
    levels_callback_ = nullptr;
    event_callback_ = nullptr;
  }

  bool Start(std::string* error) {
    Stop();

    std::string aec_error;
    const bool aec_ok = aec_.Start(&aec_error);
    aec_active_ = aec_ok;

    ma_device_config config = ma_device_config_init(ma_device_type_duplex);
    config.capture.format = ma_format_s16;
    config.capture.channels = 1;
    config.playback.format = ma_format_s16;
    config.playback.channels = 1;
    config.sampleRate = kSampleRate;
    config.periodSizeInFrames = kFrameSamples;
    config.performanceProfile = ma_performance_profile_low_latency;
    config.dataCallback = &Impl::DataCallback;
    config.pUserData = this;
    // 不要用 communications 模式：那会再挂一套系统 AEC，和我们的 DMO 打架。
    config.wasapi.usage = ma_wasapi_usage_default;

    const ma_result init_result = ma_device_init(nullptr, &config, &device_);
    if (init_result != MA_SUCCESS) {
      if (error != nullptr) {
        *error = std::string("ma_device_init 失败：") +
                 ma_result_description(init_result);
      }
      aec_.Stop();
      aec_active_ = false;
      return false;
    }
    device_inited_ = true;

    const ma_result start_result = ma_device_start(&device_);
    if (start_result != MA_SUCCESS) {
      if (error != nullptr) {
        *error = std::string("ma_device_start 失败：") +
                 ma_result_description(start_result);
      }
      ma_device_uninit(&device_);
      device_inited_ = false;
      aec_.Stop();
      aec_active_ = false;
      return false;
    }

    running_ = true;
    // 起完再报 AEC 状态，避免启动窗口里的监听漏掉事件。
    if (!aec_ok && event_callback_) {
      event_callback_(
          "engineFailure",
          "Windows 原生 AEC 不可用，已切换半双工：" + aec_error);
    }
    return true;
  }

  void Stop() {
    running_ = false;
    if (device_inited_) {
      ma_device_stop(&device_);
      ma_device_uninit(&device_);
      device_inited_ = false;
    }
    aec_.Stop();
    aec_active_ = false;

    {
      std::lock_guard<std::mutex> lock(playback_mutex_);
      playback_.clear();
      scheduled_frames_ = 0;
      played_frames_ = 0;
    }
    mic_acc_.clear();
    ref_acc_.clear();
    aec_out_acc_.clear();
    last_playback_at_ = Clock::time_point{};
    last_mic_db_ = -120.0;
    last_playback_db_ = -120.0;
    level_counter_ = 0;
  }

  static void DataCallback(ma_device* device, void* output, const void* input,
                           ma_uint32 frame_count) {
    auto* self = static_cast<Impl*>(device->pUserData);
    if (self != nullptr) self->OnAudio(output, input, frame_count);
  }

  void OnAudio(void* output, const void* input, ma_uint32 frame_count) {
    auto* out = static_cast<int16_t*>(output);
    const auto* in = static_cast<const int16_t*>(input);
    const size_t frames = frame_count;
    if (out == nullptr || frames == 0) return;

    if (!running_) {
      std::memset(out, 0, frames * sizeof(int16_t));
      return;
    }

    bool played_any = false;
    {
      std::lock_guard<std::mutex> lock(playback_mutex_);
      for (size_t i = 0; i < frames; ++i) {
        if (!playback_.empty()) {
          out[i] = playback_.front();
          playback_.pop_front();
          ++played_frames_;
          played_any = true;
        } else {
          out[i] = 0;
        }
      }
    }
    if (played_any) last_playback_at_ = Clock::now();

    if (in != nullptr) {
      mic_acc_.insert(mic_acc_.end(), in, in + frames);
    } else {
      mic_acc_.insert(mic_acc_.end(), frames, 0);
    }
    ref_acc_.insert(ref_acc_.end(), out, out + frames);

    // 输入积压上限 2 秒；正常不会触发，触发说明音频线程被卡住了。
    TrimFront(&mic_acc_, kSampleRate * 2);
    TrimFront(&ref_acc_, kSampleRate * 2);

    while (mic_acc_.size() >= kFrameSamples &&
           ref_acc_.size() >= kFrameSamples) {
      if (aec_active_ && aec_.Available()) {
        aec_.Push(mic_acc_.data(), ref_acc_.data(), kFrameSamples);
      } else {
        const bool gate = PlaybackActive() ||
                          (Clock::now() - last_playback_at_ <
                           std::chrono::milliseconds(150));
        if (gate) {
          aec_out_acc_.insert(aec_out_acc_.end(), kFrameSamples, 0);
        } else {
          aec_out_acc_.insert(aec_out_acc_.end(), mic_acc_.begin(),
                              mic_acc_.begin() + kFrameSamples);
        }
      }
      mic_acc_.erase(mic_acc_.begin(), mic_acc_.begin() + kFrameSamples);
      ref_acc_.erase(ref_acc_.begin(), ref_acc_.begin() + kFrameSamples);
    }

    if (aec_active_ && aec_.Available()) {
      int16_t tmp[kFrameSamples * 4];
      const size_t got = aec_.Pop(tmp, kFrameSamples * 4);
      if (got > 0) {
        aec_out_acc_.insert(aec_out_acc_.end(), tmp, tmp + got);
      }
      const int aec_dropped = aec_.DroppedSamples();
      if (aec_dropped > last_aec_dropped_) {
        dropped_mic_frames_ +=
            (aec_dropped - last_aec_dropped_) / kFrameSamples;
        last_aec_dropped_ = aec_dropped;
      }
    }

    // AEC 输出按 20ms 一帧交给 Dart。
    TrimFront(&aec_out_acc_, kSampleRate * 2);
    while (aec_out_acc_.size() >= kFrameSamples) {
      if (mic_callback_) {
        mic_callback_(reinterpret_cast<const uint8_t*>(aec_out_acc_.data()),
                      kFrameBytes);
      }
      last_mic_db_ = RmsDb(aec_out_acc_.data(), kFrameSamples);
      aec_out_acc_.erase(aec_out_acc_.begin(),
                         aec_out_acc_.begin() + kFrameSamples);
    }

    if (levels_callback_ != nullptr) {
      last_playback_db_ = RmsDb(out, frames);
      if (++level_counter_ >= 2) {
        level_counter_ = 0;
        levels_callback_(last_mic_db_, last_playback_db_);
      }
    }
  }

  void TrimFront(std::vector<int16_t>* buffer, size_t max_samples) {
    if (buffer->size() <= max_samples) return;
    const size_t drop = buffer->size() - max_samples;
    buffer->erase(buffer->begin(), buffer->begin() + drop);
    dropped_mic_frames_ += static_cast<int>(drop / kFrameSamples);
  }

  bool PlaybackActive() const {
    std::lock_guard<std::mutex> lock(playback_mutex_);
    return !playback_.empty() || scheduled_frames_ > played_frames_;
  }

  void PushPlayback(const uint8_t* pcm16le, size_t size, int64_t epoch) {
    if (pcm16le == nullptr || size < sizeof(int16_t)) return;
    const size_t frames = size / sizeof(int16_t);
    const auto* samples = reinterpret_cast<const int16_t*>(pcm16le);
    std::lock_guard<std::mutex> lock(playback_mutex_);
    if (epoch < epoch_) return;

    // 上限 30 秒。正常回复远小于它；真的超了说明 Dart 侧失控了。
    const size_t cap = kSampleRate * 30;
    if (playback_.size() + frames > cap) return;
    playback_.insert(playback_.end(), samples, samples + frames);
    scheduled_frames_ += frames;
  }

  int FlushPlayback(int64_t new_epoch) {
    std::lock_guard<std::mutex> lock(playback_mutex_);
    const int discarded = static_cast<int>(
        scheduled_frames_ > played_frames_ ? scheduled_frames_ - played_frames_
                                           : 0);
    playback_.clear();
    epoch_ = std::max(epoch_, new_epoch);
    scheduled_frames_ = 0;
    played_frames_ = 0;
    return discarded;
  }

  int PlaybackBacklogFrames() const {
    std::lock_guard<std::mutex> lock(playback_mutex_);
    return static_cast<int>(scheduled_frames_ > played_frames_
                                ? scheduled_frames_ - played_frames_
                                : 0);
  }

  int PlaybackHeadMs() const {
    std::lock_guard<std::mutex> lock(playback_mutex_);
    return static_cast<int>(played_frames_ * 1000 / kSampleRate);
  }

  bool EncodeOpus(const uint8_t* pcm16le, size_t size, int sample_rate,
                  int channels, std::vector<uint8_t>* out,
                  std::string* error) {
    return OggOpusEncoder::Encode(pcm16le, size, sample_rate, channels, out,
                                  error);
  }

  bool DecodeAudio(const uint8_t* bytes, size_t size, DecodedPcm* out,
                   std::string* error) {
    // decodeAudio 在 Android/macOS 上支持多种容器；Windows 的下行协议是
    // Ogg Opus，这里只实现这一种。非 Opus 数据由调用方按失败处理。
    OggOpusDecoder decoder;
    DecodedPcm decoded;
    if (!decoder.Feed(bytes, size, &decoded, error)) return false;
    DecodedPcm tail;
    if (!decoder.Finish(&tail, error)) return false;
    if (!tail.pcm16le.empty()) {
      decoded.pcm16le.insert(decoded.pcm16le.end(), tail.pcm16le.begin(),
                             tail.pcm16le.end());
    }
    *out = std::move(decoded);
    return true;
  }

  bool FeedOggStream(const uint8_t* bytes, size_t size, DecodedPcm* out,
                     std::string* error) {
    std::lock_guard<std::mutex> lock(codec_mutex_);
    const bool ok = decoder_.Feed(bytes, size, out, error);
    if (!ok) decoder_.Reset();
    return ok;
  }

  bool FinishOggStream(DecodedPcm* out, std::string* error) {
    std::lock_guard<std::mutex> lock(codec_mutex_);
    return decoder_.Finish(out, error);
  }

  void ResetOggStream() {
    std::lock_guard<std::mutex> lock(codec_mutex_);
    decoder_.Reset();
  }

  ma_device device_{};
  bool device_inited_ = false;
  std::atomic<bool> running_{false};
  std::atomic<bool> aec_active_{false};
  AecProcessor aec_;

  mutable std::mutex playback_mutex_;
  std::deque<int16_t> playback_;
  int64_t epoch_ = 0;
  uint64_t scheduled_frames_ = 0;
  uint64_t played_frames_ = 0;

  std::vector<int16_t> mic_acc_;
  std::vector<int16_t> ref_acc_;
  std::vector<int16_t> aec_out_acc_;
  Clock::time_point last_playback_at_{};
  int level_counter_ = 0;
  double last_mic_db_ = -120.0;
  double last_playback_db_ = -120.0;
  std::atomic<int> dropped_mic_frames_{0};
  int last_aec_dropped_ = 0;

  std::mutex codec_mutex_;
  OggOpusDecoder decoder_;

  MicCallback mic_callback_;
  LevelsCallback levels_callback_;
  EventCallback event_callback_;

  std::atomic<bool> volume_key_clears_queue_{true};
};

WinVoiceEngine& WinVoiceEngine::Instance() {
  static WinVoiceEngine engine;
  return engine;
}

WinVoiceEngine::WinVoiceEngine() : impl_(std::make_unique<Impl>()) {}
WinVoiceEngine::~WinVoiceEngine() = default;

void WinVoiceEngine::SetCallbacks(MicCallback mic, LevelsCallback levels,
                                  EventCallback event) {
  impl_->SetCallbacks(std::move(mic), std::move(levels), std::move(event));
}

void WinVoiceEngine::ClearCallbacks() { impl_->ClearCallbacks(); }

bool WinVoiceEngine::Start(std::string* error) { return impl_->Start(error); }

void WinVoiceEngine::Stop() { impl_->Stop(); }

bool WinVoiceEngine::IsRunning() const { return impl_->running_; }

bool WinVoiceEngine::AecActive() const { return impl_->aec_active_; }

AudioFormatInfo WinVoiceEngine::Format() const {
  return AudioFormatInfo{kSampleRate, kChannels, kFrameSamples};
}

void WinVoiceEngine::PushPlayback(const uint8_t* pcm16le, size_t size,
                                  int64_t epoch) {
  impl_->PushPlayback(pcm16le, size, epoch);
}

int WinVoiceEngine::FlushPlayback(int64_t new_epoch) {
  return impl_->FlushPlayback(new_epoch);
}

int WinVoiceEngine::PlaybackBacklogFrames() const {
  return impl_->PlaybackBacklogFrames();
}

int WinVoiceEngine::PlaybackHeadMs() const { return impl_->PlaybackHeadMs(); }

int WinVoiceEngine::DroppedMicFrames() const {
  return impl_->dropped_mic_frames_.load();
}

bool WinVoiceEngine::OpusEncoderAvailable() const {
  return OggOpusEncoder::Available();
}

bool WinVoiceEngine::EncodeOpus(const uint8_t* pcm16le, size_t size,
                                int sample_rate, int channels,
                                std::vector<uint8_t>* out,
                                std::string* error) {
  return impl_->EncodeOpus(pcm16le, size, sample_rate, channels, out, error);
}

bool WinVoiceEngine::DecodeAudio(const uint8_t* bytes, size_t size,
                                 DecodedPcm* out, std::string* error) {
  return impl_->DecodeAudio(bytes, size, out, error);
}

bool WinVoiceEngine::FeedOggStream(const uint8_t* bytes, size_t size,
                                   DecodedPcm* out, std::string* error) {
  return impl_->FeedOggStream(bytes, size, out, error);
}

bool WinVoiceEngine::FinishOggStream(DecodedPcm* out, std::string* error) {
  return impl_->FinishOggStream(out, error);
}

void WinVoiceEngine::ResetOggStream() { impl_->ResetOggStream(); }

void WinVoiceEngine::SetVolumeKeyClearsQueue(bool enabled) {
  impl_->volume_key_clears_queue_ = enabled;
}

bool WinVoiceEngine::VolumeKeyClearsQueue() const {
  return impl_->volume_key_clears_queue_.load();
}

}  // namespace voice
}  // namespace pp_friend
