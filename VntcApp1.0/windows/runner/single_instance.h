#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

inline constexpr wchar_t kVntSingleInstanceMutexName[] =
    L"Local\\VNTC_APP2_SINGLE_INSTANCE_8D79499C";
inline constexpr wchar_t kVntActivateInstanceMessageName[] =
    L"VNTC_APP2_ACTIVATE_INSTANCE_8D79499C";

inline UINT GetVntActivateInstanceMessage() {
  static const UINT message =
      ::RegisterWindowMessageW(kVntActivateInstanceMessageName);
  return message;
}

#endif  // RUNNER_SINGLE_INSTANCE_H_
