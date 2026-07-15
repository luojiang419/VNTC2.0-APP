#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <array>
#include <cwctype>
#include <iomanip>
#include <sstream>
#include <string>

inline std::wstring GetVntInstanceIdentity() {
  std::array<wchar_t, 32768> module_path{};
  const DWORD length = ::GetModuleFileNameW(
      nullptr, module_path.data(), static_cast<DWORD>(module_path.size()));
  const std::wstring path =
      length > 0 && length < module_path.size()
          ? std::wstring(module_path.data(), length)
          : L"vnt_app.exe";

  uint64_t hash = 1469598103934665603ULL;
  for (const wchar_t value : path) {
    hash ^= static_cast<uint64_t>(std::towlower(value));
    hash *= 1099511628211ULL;
  }

  std::wostringstream stream;
  stream << std::hex << std::uppercase << std::setw(16) << std::setfill(L'0')
         << hash;
  return stream.str();
}

inline const std::wstring& GetVntSingleInstanceMutexName() {
  static const std::wstring name =
      L"Local\\VNTC_APP2_SINGLE_INSTANCE_" + GetVntInstanceIdentity();
  return name;
}

inline const std::wstring& GetVntActivateInstanceMessageName() {
  static const std::wstring name =
      L"VNTC_APP2_ACTIVATE_INSTANCE_" + GetVntInstanceIdentity();
  return name;
}

inline UINT GetVntActivateInstanceMessage() {
  static const UINT message =
      ::RegisterWindowMessageW(GetVntActivateInstanceMessageName().c_str());
  return message;
}

#endif  // RUNNER_SINGLE_INSTANCE_H_
