#ifndef RUNNER_SCREEN_CAPTURE_SELECTOR_H_
#define RUNNER_SCREEN_CAPTURE_SELECTOR_H_

#include <windows.h>

#include <string>

enum class ScreenCaptureSelectionStatus {
  kSuccess,
  kCanceled,
  kFailed,
};

struct ScreenCaptureSelectionResult {
  ScreenCaptureSelectionStatus status;
  std::string error;
};

bool CaptureVirtualScreenToPng(const std::wstring& output_path,
                               std::string* error);

ScreenCaptureSelectionResult CaptureScreenRegionInteractively(
    HWND owner,
    const std::wstring& output_path);

#endif  // RUNNER_SCREEN_CAPTURE_SELECTOR_H_
