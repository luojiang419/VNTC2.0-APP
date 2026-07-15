#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <array>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "single_instance.h"
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

namespace {

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

std::wstring ReadRuntimeWindowTitle() {
  std::array<wchar_t, 32768> module_path{};
  const DWORD path_length = ::GetModuleFileNameW(
      nullptr, module_path.data(), static_cast<DWORD>(module_path.size()));
  if (path_length == 0 || path_length >= module_path.size()) {
    return VNT_APP_WINDOW_TITLE;
  }

  std::wstring branding_path(module_path.data(), path_length);
  const auto separator = branding_path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return VNT_APP_WINDOW_TITLE;
  }
  branding_path.resize(separator + 1);
  branding_path.append(L"branding.json");

  std::ifstream input(branding_path, std::ios::binary);
  if (!input) {
    return VNT_APP_WINDOW_TITLE;
  }
  const std::string json((std::istreambuf_iterator<char>(input)),
                         std::istreambuf_iterator<char>());
  const std::string key = "\"windowTitle\"";
  const auto key_position = json.find(key);
  if (key_position == std::string::npos) {
    return VNT_APP_WINDOW_TITLE;
  }
  const auto colon = json.find(':', key_position + key.size());
  const auto quote = colon == std::string::npos ? std::string::npos
                                                 : json.find('"', colon + 1);
  if (quote == std::string::npos) {
    return VNT_APP_WINDOW_TITLE;
  }

  std::string utf8_title;
  bool escaped = false;
  for (size_t index = quote + 1; index < json.size(); ++index) {
    const char current = json[index];
    if (escaped) {
      if (current == '"' || current == '\\' || current == '/') {
        utf8_title.push_back(current);
      }
      escaped = false;
      continue;
    }
    if (current == '\\') {
      escaped = true;
      continue;
    }
    if (current == '"') {
      break;
    }
    utf8_title.push_back(current);
  }

  const auto title = Utf8ToWide(utf8_title);
  return title.empty() ? VNT_APP_WINDOW_TITLE : title;
}

bool HasNonEmptyArgument(const std::vector<std::string>& arguments,
                         const std::string& prefix) {
  return std::any_of(arguments.begin(), arguments.end(), [&](const auto& arg) {
    return arg.rfind(prefix, 0) == 0 && arg.size() > prefix.size();
  });
}

bool HasArgument(const std::vector<std::string>& arguments,
                 const std::string& expected) {
  return std::find(arguments.begin(), arguments.end(), expected) !=
         arguments.end();
}

bool IsCompleteUpdateSession(const std::vector<std::string>& arguments) {
  constexpr std::array<const char*, 8> required_prefixes = {
      "--run-update-session=", "--update-token=",       "--update-version=",
      "--update-installer=",   "--update-install-root=", "--update-old-pid=",
      "--update-storage-root=", "--update-launch-path=",
  };
  return std::all_of(required_prefixes.begin(), required_prefixes.end(),
                     [&](const char* prefix) {
                       return HasNonEmptyArgument(arguments, prefix);
                     });
}

void NotifyPrimaryInstance() {
  ::AllowSetForegroundWindow(ASFW_ANY);
  const UINT message = GetVntActivateInstanceMessage();
  if (message != 0) {
    ::PostMessageW(HWND_BROADCAST, message,
                   static_cast<WPARAM>(::GetCurrentProcessId()), 0);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool start_hidden =
      HasArgument(command_line_arguments, "--silent");
  HANDLE single_instance_mutex = nullptr;
  if (!IsCompleteUpdateSession(command_line_arguments)) {
    ::SetLastError(ERROR_SUCCESS);
    single_instance_mutex = ::CreateMutexW(
        nullptr, TRUE, GetVntSingleInstanceMutexName().c_str());
    if (single_instance_mutex == nullptr) {
      return EXIT_FAILURE;
    }
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
      if (!start_hidden) {
        NotifyPrimaryInstance();
      }
      ::CloseHandle(single_instance_mutex);
      return EXIT_SUCCESS;
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(ReadRuntimeWindowTitle(), origin, size)) {
    if (single_instance_mutex != nullptr) {
      ::ReleaseMutex(single_instance_mutex);
      ::CloseHandle(single_instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ::ReleaseMutex(single_instance_mutex);
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
