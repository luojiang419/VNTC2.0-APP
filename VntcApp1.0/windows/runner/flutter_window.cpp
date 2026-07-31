#include "flutter_window.h"

#include <gdiplus.h>

#include <cwchar>
#include <memory>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "flutter/standard_method_codec.h"
#include "single_instance.h"

namespace {

void ActivatePrimaryWindow(HWND window) {
  LONG_PTR extended_style = ::GetWindowLongPtrW(window, GWL_EXSTYLE);
  extended_style &= ~static_cast<LONG_PTR>(WS_EX_TOOLWINDOW);
  extended_style |= WS_EX_APPWINDOW;
  ::SetWindowLongPtrW(window, GWL_EXSTYLE, extended_style);

  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
  constexpr UINT flags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW |
                         SWP_FRAMECHANGED | SWP_NOOWNERZORDER;
  ::SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, flags);
  ::SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
  ::BringWindowToTop(window);
  ::SetForegroundWindow(window);
  ::SetFocus(window);
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
      nullptr, 0);
  if (length <= 0) {
    return {};
  }
  std::wstring result(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), length);
  return result;
}

bool FindPngEncoder(CLSID* encoder_clsid) {
  UINT encoder_count = 0;
  UINT encoder_bytes = 0;
  if (Gdiplus::GetImageEncodersSize(&encoder_count, &encoder_bytes) !=
          Gdiplus::Ok ||
      encoder_bytes == 0) {
    return false;
  }

  auto buffer = std::make_unique<BYTE[]>(encoder_bytes);
  auto* encoders =
      reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.get());
  if (Gdiplus::GetImageEncoders(encoder_count, encoder_bytes, encoders) !=
      Gdiplus::Ok) {
    return false;
  }
  for (UINT index = 0; index < encoder_count; ++index) {
    if (encoders[index].MimeType != nullptr &&
        ::wcscmp(encoders[index].MimeType, L"image/png") == 0) {
      *encoder_clsid = encoders[index].Clsid;
      return true;
    }
  }
  return false;
}

bool CaptureVirtualScreenToPng(const std::wstring& output_path,
                               std::string* error) {
  const int left = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int top = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (width <= 0 || height <= 0) {
    *error = "Unable to resolve the virtual screen size";
    return false;
  }

  HDC screen_dc = ::GetDC(nullptr);
  if (screen_dc == nullptr) {
    *error = "GetDC failed";
    return false;
  }
  HDC memory_dc = ::CreateCompatibleDC(screen_dc);
  HBITMAP bitmap = ::CreateCompatibleBitmap(screen_dc, width, height);
  if (memory_dc == nullptr || bitmap == nullptr) {
    if (bitmap != nullptr) {
      ::DeleteObject(bitmap);
    }
    if (memory_dc != nullptr) {
      ::DeleteDC(memory_dc);
    }
    ::ReleaseDC(nullptr, screen_dc);
    *error = "Unable to allocate screenshot bitmap";
    return false;
  }

  HGDIOBJ previous = ::SelectObject(memory_dc, bitmap);
  const BOOL copied = ::BitBlt(memory_dc, 0, 0, width, height, screen_dc, left,
                               top, SRCCOPY | CAPTUREBLT);
  ::SelectObject(memory_dc, previous);
  ::DeleteDC(memory_dc);
  ::ReleaseDC(nullptr, screen_dc);
  if (!copied) {
    ::DeleteObject(bitmap);
    *error = "BitBlt failed";
    return false;
  }

  Gdiplus::GdiplusStartupInput startup_input;
  ULONG_PTR gdiplus_token = 0;
  if (Gdiplus::GdiplusStartup(&gdiplus_token, &startup_input, nullptr) !=
      Gdiplus::Ok) {
    ::DeleteObject(bitmap);
    *error = "GDI+ startup failed";
    return false;
  }

  bool saved = false;
  {
    Gdiplus::Bitmap image(bitmap, nullptr);
    CLSID png_encoder{};
    saved = FindPngEncoder(&png_encoder) &&
            image.Save(output_path.c_str(), &png_encoder, nullptr) ==
                Gdiplus::Ok;
  }
  Gdiplus::GdiplusShutdown(gdiplus_token);
  ::DeleteObject(bitmap);
  if (!saved) {
    *error = "Unable to encode screenshot as PNG";
  }
  return saved;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

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

  screenshot_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "top.wherewego.vnt/system_screenshot",
          &flutter::StandardMethodCodec::GetInstance());
  screenshot_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "registerShortcut") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Missing shortcut arguments");
            return;
          }
          const auto key =
              arguments->find(flutter::EncodableValue("virtualKey"));
          const auto* virtual_key =
              key == arguments->end() ? nullptr : std::get_if<int>(&key->second);
          if (virtual_key == nullptr) {
            result->Error("invalid_arguments", "Missing virtualKey");
            return;
          }
          ::UnregisterHotKey(GetHandle(), kScreenshotHotKeyId);
          if (!::RegisterHotKey(GetHandle(), kScreenshotHotKeyId, MOD_NOREPEAT,
                                static_cast<UINT>(*virtual_key))) {
            result->Error("shortcut_unavailable",
                          "The screenshot shortcut is already in use");
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() == "captureFullScreen") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Missing capture arguments");
            return;
          }
          const auto output =
              arguments->find(flutter::EncodableValue("outputPath"));
          const auto* output_path = output == arguments->end()
                                        ? nullptr
                                        : std::get_if<std::string>(&output->second);
          if (output_path == nullptr || output_path->empty()) {
            result->Error("invalid_arguments", "Missing outputPath");
            return;
          }
          std::string error;
          if (!CaptureVirtualScreenToPng(Utf8ToWide(*output_path), &error)) {
            result->Error("capture_failed", error);
            return;
          }
          result->Success(flutter::EncodableValue(*output_path));
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ::UnregisterHotKey(GetHandle(), kScreenshotHotKeyId);
  screenshot_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  const UINT activate_message = GetVntActivateInstanceMessage();
  if (activate_message != 0 && message == activate_message) {
    ActivatePrimaryWindow(hwnd);
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
    case WM_HOTKEY:
      if (static_cast<int>(wparam) == kScreenshotHotKeyId &&
          screenshot_channel_) {
        screenshot_channel_->InvokeMethod(
            "shortcutPressed",
            std::make_unique<flutter::EncodableValue>());
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
