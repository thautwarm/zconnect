#include "audio_support.h"

#include <algorithm>
#include <cmath>

namespace pp_friend {
namespace voice {

namespace {

double RmsDbFromSum(double sum_squares, size_t count) {
  if (count == 0) return -120.0;
  const double rms = std::sqrt(sum_squares / static_cast<double>(count));
  if (rms <= 1e-7) return -120.0;
  return 20.0 * std::log10(rms);
}

}  // namespace

double RmsDb(const int16_t* samples, size_t count) {
  if (samples == nullptr || count == 0) return -120.0;
  double sum = 0.0;
  for (size_t i = 0; i < count; ++i) {
    const double v = static_cast<double>(samples[i]) / 32768.0;
    sum += v * v;
  }
  return RmsDbFromSum(sum, count);
}

double RmsDb(const float* samples, size_t count) {
  if (samples == nullptr || count == 0) return -120.0;
  double sum = 0.0;
  for (size_t i = 0; i < count; ++i) {
    const double v = std::clamp(static_cast<double>(samples[i]), -1.0, 1.0);
    sum += v * v;
  }
  return RmsDbFromSum(sum, count);
}

double RmsDb(const int16_t* samples, size_t count, double gain) {
  if (samples == nullptr || count == 0) return -120.0;
  double sum = 0.0;
  for (size_t i = 0; i < count; ++i) {
    const double v =
        std::clamp(static_cast<double>(samples[i]) / 32768.0 * gain, -1.0, 1.0);
    sum += v * v;
  }
  return RmsDbFromSum(sum, count);
}

}  // namespace voice
}  // namespace pp_friend
