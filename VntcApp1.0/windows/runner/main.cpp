#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

#define STRINGIFY_IMPL(x) #x
#define STRINGIFY(x) STRINGIFY_IMPL(x)
#define WIDEN_IMPL(x) L##x
#define WIDEN(x) WIDEN_IMPL(x)

#define VNT_APP_BASE_TITLE L"VNTC APP2.0"

#if defined(FLUTTER_VERSION_MAJOR) && defined(FLUTTER_VERSION_MINOR)
#define VNT_APP_WINDOW_TITLE \
  VNT_APP_BASE_TITLE L" v" WIDEN(STRINGIFY(FLUTTER_VERSION_MAJOR)) \
      L"." WIDEN(STRINGIFY(FLUTTER_VERSION_MINOR))
#else
#define VNT_APP_WINDOW_TITLE VNT_APP_BASE_TITLE
#endif

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(VNT_APP_WINDOW_TITLE, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
