#define UNICODE
#define _UNICODE

#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <wchar.h>

static const wchar_t *LAUNCHER_EXE_NAME = L"vnt_app.exe";
static const wchar_t *RUNNER_EXE_NAME = L"vnt_app_runner.exe";
static const wchar_t *LOG_RELATIVE_PATH = L"logs\\launcher.log";

typedef struct WindowSearchState {
  DWORD pid;
  HWND hwnd;
} WindowSearchState;

static void build_path(wchar_t *buffer, size_t buffer_len, const wchar_t *left,
                       const wchar_t *right) {
  _snwprintf(buffer, buffer_len, L"%ls\\%ls", left, right);
  buffer[buffer_len - 1] = L'\0';
}

static void log_line(const wchar_t *exe_dir, const wchar_t *message) {
  wchar_t logs_dir[MAX_PATH];
  wchar_t log_path[MAX_PATH];
  build_path(logs_dir, MAX_PATH, exe_dir, L"logs");
  CreateDirectoryW(logs_dir, NULL);
  build_path(log_path, MAX_PATH, exe_dir, LOG_RELATIVE_PATH);

  FILE *file = _wfopen(log_path, L"a+, ccs=UTF-8");
  if (file == NULL) {
    return;
  }

  SYSTEMTIME st;
  GetLocalTime(&st);
  fwprintf(file, L"%04d-%02d-%02d %02d:%02d:%02d | %ls\r\n", st.wYear,
           st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, message);
  fclose(file);
}

static void show_error(const wchar_t *message) {
  MessageBoxW(NULL, message, L"VNT App Launcher", MB_OK | MB_ICONERROR);
}

static void log_system_version(const wchar_t *exe_dir) {
  OSVERSIONINFOW osvi;
  ZeroMemory(&osvi, sizeof(osvi));
  osvi.dwOSVersionInfoSize = sizeof(osvi);

#pragma warning(push)
#pragma warning(disable : 4996)
  BOOL ok = GetVersionExW(&osvi);
#pragma warning(pop)

  if (!ok) {
    log_line(exe_dir, L"GetVersionExW failed");
    return;
  }

  wchar_t message[256];
  _snwprintf(message, 256, L"os version: major=%lu minor=%lu build=%lu",
             osvi.dwMajorVersion, osvi.dwMinorVersion, osvi.dwBuildNumber);
  message[255] = L'\0';
  log_line(exe_dir, message);
}

static void log_last_error(const wchar_t *exe_dir, const wchar_t *prefix,
                           DWORD error_code) {
  wchar_t detail[1024];
  wchar_t *system_message = NULL;
  DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                FORMAT_MESSAGE_IGNORE_INSERTS;
  DWORD length = FormatMessageW(flags, NULL, error_code, 0,
                                (LPWSTR)&system_message, 0, NULL);

  if (length == 0 || system_message == NULL) {
    _snwprintf(detail, 1024, L"%ls | error=%lu (0x%08lX)", prefix, error_code,
               error_code);
  } else {
    while (length > 0 &&
           (system_message[length - 1] == L'\r' ||
            system_message[length - 1] == L'\n')) {
      system_message[length - 1] = L'\0';
      length--;
    }
    _snwprintf(detail, 1024, L"%ls | error=%lu (0x%08lX) | %ls", prefix,
               error_code, error_code, system_message);
  }

  detail[1023] = L'\0';
  log_line(exe_dir, detail);

  if (system_message != NULL) {
    LocalFree(system_message);
  }
}

static void kill_named_processes(const wchar_t *target_name, DWORD current_pid,
                                 const wchar_t *exe_dir) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    log_line(exe_dir, L"CreateToolhelp32Snapshot failed");
    return;
  }

  PROCESSENTRY32W entry;
  entry.dwSize = sizeof(PROCESSENTRY32W);
  if (!Process32FirstW(snapshot, &entry)) {
    CloseHandle(snapshot);
    log_line(exe_dir, L"Process32FirstW failed");
    return;
  }

  do {
    if (_wcsicmp(entry.szExeFile, target_name) != 0) {
      continue;
    }
    if (entry.th32ProcessID == current_pid) {
      continue;
    }

    HANDLE process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE,
                                 entry.th32ProcessID);
    if (process == NULL) {
      continue;
    }

    TerminateProcess(process, 1);
    WaitForSingleObject(process, 3000);
    CloseHandle(process);
  } while (Process32NextW(snapshot, &entry));

  CloseHandle(snapshot);
}

static BOOL CALLBACK enum_windows_callback(HWND hwnd, LPARAM lparam) {
  WindowSearchState *state = (WindowSearchState *)lparam;
  DWORD window_pid = 0;
  GetWindowThreadProcessId(hwnd, &window_pid);
  if (window_pid != state->pid) {
    return TRUE;
  }
  if (GetWindow(hwnd, GW_OWNER) != NULL) {
    return TRUE;
  }
  state->hwnd = hwnd;
  return FALSE;
}

static HWND find_main_window(DWORD pid) {
  WindowSearchState state;
  state.pid = pid;
  state.hwnd = NULL;
  EnumWindows(enum_windows_callback, (LPARAM)&state);
  return state.hwnd;
}

int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE prev_instance,
                      LPWSTR command_line, int show_command) {
  (void)instance;
  (void)prev_instance;
  (void)command_line;
  (void)show_command;

  wchar_t exe_path[MAX_PATH];
  DWORD path_len = GetModuleFileNameW(NULL, exe_path, MAX_PATH);
  if (path_len == 0 || path_len >= MAX_PATH) {
    show_error(L"无法获取启动器路径。");
    return 1;
  }

  wchar_t exe_dir[MAX_PATH];
  wcscpy(exe_dir, exe_path);
  wchar_t *last_slash = wcsrchr(exe_dir, L'\\');
  if (last_slash == NULL) {
    show_error(L"无法解析启动目录。");
    return 1;
  }
  *last_slash = L'\0';

  log_line(exe_dir, L"launcher start");
  log_system_version(exe_dir);

  DWORD current_pid = GetCurrentProcessId();
  kill_named_processes(LAUNCHER_EXE_NAME, current_pid, exe_dir);
  kill_named_processes(L"vnt_app_runner.exe", 0, exe_dir);
  log_line(exe_dir, L"old processes cleaned");

  wchar_t runner_path[MAX_PATH];
  build_path(runner_path, MAX_PATH, exe_dir, RUNNER_EXE_NAME);
  if (GetFileAttributesW(runner_path) == INVALID_FILE_ATTRIBUTES) {
    log_last_error(exe_dir, L"runner missing", GetLastError());
    log_line(exe_dir, L"runner missing");
    show_error(L"缺少 vnt_app_runner.exe，请检查 output 目录是否完整。");
    return 1;
  }

  wchar_t command[MAX_PATH * 2];
  _snwprintf(command, MAX_PATH * 2, L"\"%ls\"", runner_path);
  command[(MAX_PATH * 2) - 1] = L'\0';

  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  ZeroMemory(&pi, sizeof(pi));
  si.cb = sizeof(si);

  BOOL created = CreateProcessW(runner_path, command, NULL, NULL, FALSE, 0, NULL,
                                exe_dir, &si, &pi);
  if (!created) {
    DWORD error_code = GetLastError();
    log_last_error(exe_dir, L"CreateProcessW failed", error_code);

    wchar_t error_message[256];
    _snwprintf(error_message, 256,
               L"启动 vnt_app_runner.exe 失败，错误码 %lu。请查看 logs\\launcher.log。",
               error_code);
    error_message[255] = L'\0';
    show_error(error_message);
    return 1;
  }

  log_line(exe_dir, L"runner spawned");

  WaitForInputIdle(pi.hProcess, 5000);

  HWND runner_window = NULL;
  for (int i = 0; i < 20; ++i) {
    runner_window = find_main_window(pi.dwProcessId);
    if (runner_window != NULL) {
      log_line(exe_dir, L"runner window found");
      break;
    }
    Sleep(500);
  }

  if (runner_window == NULL) {
    log_line(exe_dir, L"runner window not found within 10s");
  }

  DWORD wait_result = WaitForSingleObject(pi.hProcess, 2000);
  if (wait_result == WAIT_OBJECT_0) {
    DWORD exit_code = 0;
    GetExitCodeProcess(pi.hProcess, &exit_code);
    wchar_t message[256];
    _snwprintf(message, 256, L"runner exited early: code=%lu", exit_code);
    message[255] = L'\0';
    log_line(exe_dir, message);
  } else {
    log_line(exe_dir, L"runner still alive after 2s");
  }

  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return 0;
}
