#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"

namespace {

constexpr UINT_PTR kActivationReassertTimer = 0x564E5453;

void ActivateWindow(HWND hwnd) {
  LONG_PTR extended_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  extended_style &= ~WS_EX_TOOLWINDOW;
  extended_style |= WS_EX_APPWINDOW;
  ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, extended_style);
  ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  if (!::SetForegroundWindow(hwnd)) {
    FLASHWINFO flash = {sizeof(FLASHWINFO), hwnd,
                        FLASHW_TRAY | FLASHW_TIMERNOFG, 3, 0};
    ::FlashWindowEx(&flash);
  }
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == SingleInstanceGuard::ActivationWindowMessage()) {
    ActivateWindow(hwnd);
    ::SetTimer(hwnd, kActivationReassertTimer, 1500, nullptr);
    return 0;
  }
  if (message == WM_TIMER && wparam == kActivationReassertTimer) {
    ::KillTimer(hwnd, kActivationReassertTimer);
    ActivateWindow(hwnd);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
