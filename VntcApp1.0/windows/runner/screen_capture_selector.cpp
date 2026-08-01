#include "screen_capture_selector.h"

#include <dwmapi.h>
#include <gdiplus.h>
#include <windowsx.h>

#include <algorithm>
#include <cwchar>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kSelectorWindowClass[] =
    L"VntScreenshotSelectionOverlay";

struct CapturedScreen {
  int left = 0;
  int top = 0;
  int width = 0;
  int height = 0;
  HBITMAP bitmap = nullptr;
};

struct SelectorState {
  CapturedScreen screen;
  HWND owner = nullptr;
  HWND window = nullptr;
  std::vector<RECT> window_rects;
  POINT drag_start{};
  RECT hovered_rect{};
  RECT selection_rect{};
  bool has_hovered_rect = false;
  bool has_selection_rect = false;
  bool dragging = false;
  bool running = true;
  bool accepted = false;
};

bool IsValidRect(const RECT& rect) {
  return rect.right > rect.left && rect.bottom > rect.top;
}

bool RectEquals(const RECT& first, const RECT& second) {
  return first.left == second.left && first.top == second.top &&
         first.right == second.right && first.bottom == second.bottom;
}

RECT NormalizeRect(POINT first, POINT second) {
  return RECT{std::min(first.x, second.x), std::min(first.y, second.y),
              std::max(first.x, second.x), std::max(first.y, second.y)};
}

RECT ScreenBounds(const CapturedScreen& screen) {
  return RECT{screen.left, screen.top, screen.left + screen.width,
              screen.top + screen.height};
}

RECT ClampToScreen(const RECT& rect, const CapturedScreen& screen) {
  RECT clipped{};
  const RECT bounds = ScreenBounds(screen);
  if (!::IntersectRect(&clipped, &rect, &bounds)) {
    return RECT{};
  }
  return clipped;
}

void ReleaseCapturedScreen(CapturedScreen* screen) {
  if (screen->bitmap != nullptr) {
    ::DeleteObject(screen->bitmap);
    screen->bitmap = nullptr;
  }
}

bool CaptureVirtualScreenBitmap(CapturedScreen* capture,
                                std::string* error) {
  capture->left = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  capture->top = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  capture->width = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  capture->height = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (capture->width <= 0 || capture->height <= 0) {
    *error = "Unable to resolve the virtual screen size";
    return false;
  }

  HDC screen_dc = ::GetDC(nullptr);
  if (screen_dc == nullptr) {
    *error = "GetDC failed";
    return false;
  }
  HDC memory_dc = ::CreateCompatibleDC(screen_dc);
  if (memory_dc == nullptr) {
    ::ReleaseDC(nullptr, screen_dc);
    *error = "CreateCompatibleDC failed";
    return false;
  }
  capture->bitmap =
      ::CreateCompatibleBitmap(screen_dc, capture->width, capture->height);
  if (capture->bitmap == nullptr) {
    ::DeleteDC(memory_dc);
    ::ReleaseDC(nullptr, screen_dc);
    *error = "Unable to allocate screenshot bitmap";
    return false;
  }

  HGDIOBJ previous = ::SelectObject(memory_dc, capture->bitmap);
  const BOOL copied = ::BitBlt(
      memory_dc, 0, 0, capture->width, capture->height, screen_dc,
      capture->left, capture->top, SRCCOPY | CAPTUREBLT);
  ::SelectObject(memory_dc, previous);
  ::DeleteDC(memory_dc);
  ::ReleaseDC(nullptr, screen_dc);
  if (!copied) {
    ReleaseCapturedScreen(capture);
    *error = "BitBlt failed";
    return false;
  }
  return true;
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

bool SaveBitmapToPng(HBITMAP bitmap,
                     const std::wstring& output_path,
                     std::string* error) {
  Gdiplus::GdiplusStartupInput startup_input;
  ULONG_PTR gdiplus_token = 0;
  if (Gdiplus::GdiplusStartup(&gdiplus_token, &startup_input, nullptr) !=
      Gdiplus::Ok) {
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
  if (!saved) {
    *error = "Unable to encode screenshot as PNG";
  }
  return saved;
}

bool SaveScreenRegionToPng(const CapturedScreen& screen,
                           const RECT& requested_region,
                           const std::wstring& output_path,
                           std::string* error) {
  const RECT region = ClampToScreen(requested_region, screen);
  if (!IsValidRect(region)) {
    *error = "The selected screenshot region is empty";
    return false;
  }
  const int width = region.right - region.left;
  const int height = region.bottom - region.top;

  HDC screen_dc = ::GetDC(nullptr);
  HDC source_dc = screen_dc == nullptr ? nullptr : ::CreateCompatibleDC(screen_dc);
  HDC target_dc = screen_dc == nullptr ? nullptr : ::CreateCompatibleDC(screen_dc);
  HBITMAP target_bitmap = screen_dc == nullptr
                              ? nullptr
                              : ::CreateCompatibleBitmap(screen_dc, width, height);
  if (screen_dc == nullptr || source_dc == nullptr || target_dc == nullptr ||
      target_bitmap == nullptr) {
    if (target_bitmap != nullptr) {
      ::DeleteObject(target_bitmap);
    }
    if (source_dc != nullptr) {
      ::DeleteDC(source_dc);
    }
    if (target_dc != nullptr) {
      ::DeleteDC(target_dc);
    }
    if (screen_dc != nullptr) {
      ::ReleaseDC(nullptr, screen_dc);
    }
    *error = "Unable to allocate the selected screenshot bitmap";
    return false;
  }

  HGDIOBJ previous_source = ::SelectObject(source_dc, screen.bitmap);
  HGDIOBJ previous_target = ::SelectObject(target_dc, target_bitmap);
  const BOOL copied = ::BitBlt(
      target_dc, 0, 0, width, height, source_dc, region.left - screen.left,
      region.top - screen.top, SRCCOPY);
  ::SelectObject(source_dc, previous_source);
  ::SelectObject(target_dc, previous_target);
  ::DeleteDC(source_dc);
  ::DeleteDC(target_dc);
  ::ReleaseDC(nullptr, screen_dc);
  if (!copied) {
    ::DeleteObject(target_bitmap);
    *error = "Unable to crop the selected screenshot region";
    return false;
  }

  const bool saved = SaveBitmapToPng(target_bitmap, output_path, error);
  ::DeleteObject(target_bitmap);
  return saved;
}

struct WindowEnumerationContext {
  HWND owner;
  RECT screen_bounds;
  std::vector<RECT>* rects;
};

BOOL CALLBACK EnumerateSelectableWindows(HWND window, LPARAM parameter) {
  auto* context = reinterpret_cast<WindowEnumerationContext*>(parameter);
  if (window == context->owner ||
      ::GetAncestor(window, GA_ROOTOWNER) == context->owner ||
      !::IsWindowVisible(window) || ::IsIconic(window)) {
    return TRUE;
  }

  const LONG_PTR extended_style = ::GetWindowLongPtrW(window, GWL_EXSTYLE);
  if ((extended_style & WS_EX_TOOLWINDOW) != 0) {
    return TRUE;
  }
  DWORD cloaked = 0;
  if (SUCCEEDED(::DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked,
                                        sizeof(cloaked))) &&
      cloaked != 0) {
    return TRUE;
  }

  RECT window_rect{};
  if (FAILED(::DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS,
                                     &window_rect, sizeof(window_rect))) &&
      !::GetWindowRect(window, &window_rect)) {
    return TRUE;
  }
  RECT clipped{};
  if (!::IntersectRect(&clipped, &window_rect, &context->screen_bounds) ||
      clipped.right - clipped.left < 16 ||
      clipped.bottom - clipped.top < 16) {
    return TRUE;
  }
  context->rects->push_back(clipped);
  return TRUE;
}

std::vector<RECT> ResolveSelectableWindows(HWND owner,
                                           const CapturedScreen& screen) {
  std::vector<RECT> rects;
  WindowEnumerationContext context{owner, ScreenBounds(screen), &rects};
  ::EnumWindows(EnumerateSelectableWindows,
                reinterpret_cast<LPARAM>(&context));
  return rects;
}

bool ResolveHoverRect(const SelectorState& state,
                      POINT screen_point,
                      RECT* result) {
  for (const RECT& rect : state.window_rects) {
    if (::PtInRect(&rect, screen_point)) {
      *result = rect;
      return true;
    }
  }

  const HMONITOR monitor =
      ::MonitorFromPoint(screen_point, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (monitor != nullptr && ::GetMonitorInfoW(monitor, &monitor_info)) {
    *result = ClampToScreen(monitor_info.rcMonitor, state.screen);
    return IsValidRect(*result);
  }
  return false;
}

POINT ClientPointToScreenPoint(const SelectorState& state, LPARAM parameter) {
  return POINT{state.screen.left + GET_X_LPARAM(parameter),
               state.screen.top + GET_Y_LPARAM(parameter)};
}

bool UpdateHoveredRect(SelectorState* state, POINT screen_point) {
  RECT next_rect{};
  const bool next_has_rect =
      ResolveHoverRect(*state, screen_point, &next_rect);
  const bool changed = state->has_hovered_rect != next_has_rect ||
                       (next_has_rect &&
                        !RectEquals(state->hovered_rect, next_rect));
  state->has_hovered_rect = next_has_rect;
  state->hovered_rect = next_rect;
  return changed;
}

void FinishSelection(SelectorState* state, bool accepted) {
  if (accepted && !state->has_selection_rect && state->has_hovered_rect) {
    state->selection_rect = state->hovered_rect;
    state->has_selection_rect = true;
  }
  state->accepted = accepted && state->has_selection_rect &&
                    IsValidRect(state->selection_rect);
  state->running = false;
  if (::GetCapture() == state->window) {
    ::ReleaseCapture();
  }
  if (::IsWindow(state->window)) {
    ::DestroyWindow(state->window);
  }
}

RECT ToClientRect(const RECT& screen_rect, const CapturedScreen& screen) {
  return RECT{screen_rect.left - screen.left, screen_rect.top - screen.top,
              screen_rect.right - screen.left,
              screen_rect.bottom - screen.top};
}

void PaintSelector(HWND window, SelectorState* state) {
  PAINTSTRUCT paint{};
  HDC target_dc = ::BeginPaint(window, &paint);
  HDC buffer_dc = ::CreateCompatibleDC(target_dc);
  HBITMAP buffer_bitmap =
      ::CreateCompatibleBitmap(target_dc, state->screen.width,
                               state->screen.height);
  HDC source_dc = ::CreateCompatibleDC(target_dc);
  if (buffer_dc == nullptr || buffer_bitmap == nullptr ||
      source_dc == nullptr) {
    if (source_dc != nullptr) {
      ::DeleteDC(source_dc);
    }
    if (buffer_bitmap != nullptr) {
      ::DeleteObject(buffer_bitmap);
    }
    if (buffer_dc != nullptr) {
      ::DeleteDC(buffer_dc);
    }
    ::EndPaint(window, &paint);
    return;
  }

  HGDIOBJ previous_buffer = ::SelectObject(buffer_dc, buffer_bitmap);
  HGDIOBJ previous_bitmap = ::SelectObject(source_dc, state->screen.bitmap);
  ::BitBlt(buffer_dc, 0, 0, state->screen.width, state->screen.height,
           source_dc, 0, 0, SRCCOPY);

  {
    Gdiplus::Graphics graphics(buffer_dc);
    Gdiplus::SolidBrush shade(Gdiplus::Color(118, 0, 0, 0));
    graphics.FillRectangle(&shade, 0, 0, state->screen.width,
                           state->screen.height);
  }

  const bool has_highlight =
      state->has_selection_rect || state->has_hovered_rect;
  RECT highlight{};
  if (has_highlight) {
    highlight = ToClientRect(state->has_selection_rect
                                 ? state->selection_rect
                                 : state->hovered_rect,
                             state->screen);
    const int width = highlight.right - highlight.left;
    const int height = highlight.bottom - highlight.top;
    ::BitBlt(buffer_dc, highlight.left, highlight.top, width, height,
             source_dc, highlight.left, highlight.top, SRCCOPY);

    HPEN border_pen = ::CreatePen(PS_SOLID, 2, RGB(0, 174, 255));
    HGDIOBJ previous_pen = ::SelectObject(buffer_dc, border_pen);
    HGDIOBJ previous_brush =
        ::SelectObject(buffer_dc, ::GetStockObject(NULL_BRUSH));
    ::Rectangle(buffer_dc, highlight.left, highlight.top, highlight.right,
                highlight.bottom);
    ::SelectObject(buffer_dc, previous_brush);
    ::SelectObject(buffer_dc, previous_pen);
    ::DeleteObject(border_pen);

    wchar_t dimensions[64]{};
    ::swprintf_s(dimensions, _countof(dimensions), L"%d x %d", width,
                 height);
    RECT dimension_rect{highlight.left, std::max(0L, highlight.top - 26),
                        highlight.left + 130,
                        std::max(24L, highlight.top)};
    ::SetBkMode(buffer_dc, OPAQUE);
    ::SetBkColor(buffer_dc, RGB(0, 174, 255));
    ::SetTextColor(buffer_dc, RGB(255, 255, 255));
    ::DrawTextW(buffer_dc, dimensions, -1, &dimension_rect,
                DT_SINGLELINE | DT_CENTER | DT_VCENTER);
  }

  const int banner_width = std::min(640, std::max(240, state->screen.width - 40));
  const int banner_left = std::max(0, (state->screen.width - banner_width) / 2);
  RECT banner_rect{banner_left, 24, banner_left + banner_width, 66};
  {
    Gdiplus::Graphics graphics(buffer_dc);
    Gdiplus::SolidBrush banner(Gdiplus::Color(205, 24, 24, 24));
    graphics.FillRectangle(&banner, banner_rect.left, banner_rect.top,
                           banner_rect.right - banner_rect.left,
                           banner_rect.bottom - banner_rect.top);
  }
  ::SetBkMode(buffer_dc, TRANSPARENT);
  ::SetTextColor(buffer_dc, RGB(255, 255, 255));
  ::DrawTextW(buffer_dc,
              L"Drag to select | Hover to snap a window | Enter or double-click to finish | Esc to cancel",
              -1, &banner_rect, DT_SINGLELINE | DT_CENTER | DT_VCENTER);

  ::BitBlt(target_dc, 0, 0, state->screen.width, state->screen.height,
           buffer_dc, 0, 0, SRCCOPY);
  ::SelectObject(source_dc, previous_bitmap);
  ::SelectObject(buffer_dc, previous_buffer);
  ::DeleteObject(buffer_bitmap);
  ::DeleteDC(buffer_dc);
  ::DeleteDC(source_dc);
  ::EndPaint(window, &paint);
}

LRESULT CALLBACK SelectorWindowProcedure(HWND window,
                                         UINT message,
                                         WPARAM wparam,
                                         LPARAM lparam) {
  auto* state = reinterpret_cast<SelectorState*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    state = reinterpret_cast<SelectorState*>(create->lpCreateParams);
    state->window = window;
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(state));
  }
  if (state == nullptr) {
    return ::DefWindowProcW(window, message, wparam, lparam);
  }

  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_SETCURSOR:
      ::SetCursor(::LoadCursorW(nullptr, IDC_CROSS));
      return TRUE;
    case WM_MOUSEMOVE: {
      const POINT screen_point = ClientPointToScreenPoint(*state, lparam);
      bool changed = false;
      if (state->dragging) {
        const RECT previous_rect = state->selection_rect;
        const bool previous_has_rect = state->has_selection_rect;
        state->selection_rect = ClampToScreen(
            NormalizeRect(state->drag_start, screen_point), state->screen);
        state->has_selection_rect = IsValidRect(state->selection_rect);
        changed = previous_has_rect != state->has_selection_rect ||
                  (state->has_selection_rect &&
                   !RectEquals(previous_rect, state->selection_rect));
      } else {
        changed = UpdateHoveredRect(state, screen_point);
      }
      if (changed) {
        ::InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const POINT screen_point = ClientPointToScreenPoint(*state, lparam);
      state->drag_start = screen_point;
      state->selection_rect = RECT{screen_point.x, screen_point.y,
                                   screen_point.x, screen_point.y};
      state->has_selection_rect = false;
      state->dragging = true;
      ::SetCapture(window);
      return 0;
    }
    case WM_LBUTTONUP: {
      if (!state->dragging) {
        return 0;
      }
      state->dragging = false;
      if (::GetCapture() == window) {
        ::ReleaseCapture();
      }
      const POINT screen_point = ClientPointToScreenPoint(*state, lparam);
      const RECT dragged = ClampToScreen(
          NormalizeRect(state->drag_start, screen_point), state->screen);
      if (dragged.right - dragged.left >= 4 &&
          dragged.bottom - dragged.top >= 4) {
        state->selection_rect = dragged;
        state->has_selection_rect = true;
      } else {
        UpdateHoveredRect(state, screen_point);
        state->selection_rect = state->hovered_rect;
        state->has_selection_rect = state->has_hovered_rect;
      }
      ::InvalidateRect(window, nullptr, FALSE);
      return 0;
    }
    case WM_LBUTTONDBLCLK: {
      if (!state->has_selection_rect) {
        const POINT screen_point = ClientPointToScreenPoint(*state, lparam);
        UpdateHoveredRect(state, screen_point);
      }
      FinishSelection(state, true);
      return 0;
    }
    case WM_RBUTTONDOWN:
      FinishSelection(state, false);
      return 0;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        FinishSelection(state, false);
        return 0;
      }
      if (wparam == VK_RETURN) {
        if (!state->has_selection_rect) {
          POINT cursor{};
          if (::GetCursorPos(&cursor)) {
            UpdateHoveredRect(state, cursor);
          }
        }
        FinishSelection(state, true);
        return 0;
      }
      break;
    case WM_PAINT:
      PaintSelector(window, state);
      return 0;
    case WM_DESTROY:
      state->running = false;
      return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

bool RegisterSelectorWindowClass(HINSTANCE instance, std::string* error) {
  WNDCLASSEXW existing{};
  existing.cbSize = sizeof(existing);
  if (::GetClassInfoExW(instance, kSelectorWindowClass, &existing)) {
    return true;
  }

  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.style = CS_DBLCLKS;
  window_class.lpfnWndProc = SelectorWindowProcedure;
  window_class.hInstance = instance;
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_CROSS);
  window_class.lpszClassName = kSelectorWindowClass;
  if (::RegisterClassExW(&window_class) == 0) {
    *error = "Unable to register the screenshot selector window";
    return false;
  }
  return true;
}

bool RunSelectorOverlay(SelectorState* state, std::string* error) {
  HINSTANCE instance = ::GetModuleHandleW(nullptr);
  if (!RegisterSelectorWindowClass(instance, error)) {
    return false;
  }
  POINT initial_cursor{};
  if (::GetCursorPos(&initial_cursor)) {
    UpdateHoveredRect(state, initial_cursor);
  }

  HWND overlay = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kSelectorWindowClass, L"",
      WS_POPUP, state->screen.left, state->screen.top, state->screen.width,
      state->screen.height, nullptr, nullptr, instance, state);
  if (overlay == nullptr) {
    *error = "Unable to create the screenshot selector window";
    return false;
  }

  ::ShowWindow(overlay, SW_SHOW);
  ::SetWindowPos(overlay, HWND_TOPMOST, state->screen.left, state->screen.top,
                 state->screen.width, state->screen.height,
                 SWP_SHOWWINDOW | SWP_NOACTIVATE);
  ::SetForegroundWindow(overlay);
  ::SetFocus(overlay);
  ::UpdateWindow(overlay);

  MSG message{};
  while (state->running) {
    const BOOL message_result = ::GetMessageW(&message, nullptr, 0, 0);
    if (message_result == -1) {
      *error = "The screenshot selector message loop failed";
      if (::IsWindow(overlay)) {
        ::DestroyWindow(overlay);
      }
      return false;
    }
    if (message_result == 0) {
      ::PostQuitMessage(static_cast<int>(message.wParam));
      state->running = false;
      state->accepted = false;
      break;
    }
    ::TranslateMessage(&message);
    ::DispatchMessageW(&message);
  }
  if (::IsWindow(overlay)) {
    ::DestroyWindow(overlay);
  }
  return true;
}

void RestoreOwnerWindow(HWND owner,
                        bool was_visible,
                        bool was_iconic,
                        bool was_zoomed) {
  if (!was_visible || !::IsWindow(owner)) {
    return;
  }
  ::ShowWindow(owner, was_iconic ? SW_SHOWMINIMIZED
                                : was_zoomed ? SW_SHOWMAXIMIZED : SW_SHOW);
  if (!was_iconic) {
    ::SetForegroundWindow(owner);
  }
}

}  // namespace

bool CaptureVirtualScreenToPng(const std::wstring& output_path,
                               std::string* error) {
  CapturedScreen screen;
  if (!CaptureVirtualScreenBitmap(&screen, error)) {
    return false;
  }
  const bool saved = SaveBitmapToPng(screen.bitmap, output_path, error);
  ReleaseCapturedScreen(&screen);
  return saved;
}

ScreenCaptureSelectionResult CaptureScreenRegionInteractively(
    HWND owner,
    const std::wstring& output_path) {
  const bool was_visible = owner != nullptr && ::IsWindowVisible(owner);
  const bool was_iconic = owner != nullptr && ::IsIconic(owner);
  const bool was_zoomed = owner != nullptr && ::IsZoomed(owner);
  if (was_visible) {
    ::ShowWindow(owner, SW_HIDE);
    ::DwmFlush();
    ::Sleep(120);
  }

  SelectorState state;
  state.owner = owner;
  std::string error;
  if (!CaptureVirtualScreenBitmap(&state.screen, &error)) {
    RestoreOwnerWindow(owner, was_visible, was_iconic, was_zoomed);
    return {ScreenCaptureSelectionStatus::kFailed, error};
  }
  state.window_rects = ResolveSelectableWindows(owner, state.screen);

  Gdiplus::GdiplusStartupInput startup_input;
  ULONG_PTR selector_gdiplus_token = 0;
  if (Gdiplus::GdiplusStartup(&selector_gdiplus_token, &startup_input,
                              nullptr) != Gdiplus::Ok) {
    ReleaseCapturedScreen(&state.screen);
    RestoreOwnerWindow(owner, was_visible, was_iconic, was_zoomed);
    return {ScreenCaptureSelectionStatus::kFailed,
            "GDI+ startup failed for the screenshot selector"};
  }
  const bool overlay_succeeded = RunSelectorOverlay(&state, &error);
  Gdiplus::GdiplusShutdown(selector_gdiplus_token);
  bool saved = false;
  if (overlay_succeeded && state.accepted) {
    saved = SaveScreenRegionToPng(state.screen, state.selection_rect,
                                  output_path, &error);
  }
  ReleaseCapturedScreen(&state.screen);
  RestoreOwnerWindow(owner, was_visible, was_iconic, was_zoomed);

  if (!overlay_succeeded || (state.accepted && !saved)) {
    return {ScreenCaptureSelectionStatus::kFailed, error};
  }
  if (!state.accepted) {
    return {ScreenCaptureSelectionStatus::kCanceled, {}};
  }
  return {ScreenCaptureSelectionStatus::kSuccess, {}};
}
