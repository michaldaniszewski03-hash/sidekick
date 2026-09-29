#ifndef RUNNER_SCREEN_CAPTURE_H_
#define RUNNER_SCREEN_CAPTURE_H_

#include <cstdint>
#include <vector>

// Captures the primary monitor (with the mouse pointer), scaled down to at
// most |max_width| pixels wide, as a JPEG of |quality| 0.0-1.0.
// Returns an empty vector on failure.
std::vector<uint8_t> CaptureScreenJpeg(int max_width, float quality);

#endif  // RUNNER_SCREEN_CAPTURE_H_
