#include "single_instance.h"

namespace {

constexpr wchar_t kMutexName[] =
    L"Local\\VNTS2.Console.SingleInstance.v1";
constexpr wchar_t kActivationEventName[] =
    L"Local\\VNTS2.Console.Activate.v1";
constexpr UINT kActivationWindowMessage = WM_APP + 0x2A1;

}  // namespace

SingleInstanceGuard::SingleInstanceGuard() {
  ::SetLastError(ERROR_SUCCESS);
  mutex_ = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (mutex_ == nullptr) {
    return;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(mutex_);
    mutex_ = nullptr;
    return;
  }
  owns_mutex_ = true;
  activation_event_ =
      ::CreateEventW(nullptr, FALSE, FALSE, kActivationEventName);
  if (activation_event_ == nullptr) {
    ::ReleaseMutex(mutex_);
    ::CloseHandle(mutex_);
    mutex_ = nullptr;
    owns_mutex_ = false;
  }
}

SingleInstanceGuard::~SingleInstanceGuard() {
  if (activation_wait_ != nullptr) {
    ::UnregisterWaitEx(activation_wait_, INVALID_HANDLE_VALUE);
  }
  if (activation_event_ != nullptr) {
    ::CloseHandle(activation_event_);
  }
  if (mutex_ != nullptr) {
    if (owns_mutex_) {
      ::ReleaseMutex(mutex_);
    }
    ::CloseHandle(mutex_);
  }
}

bool SingleInstanceGuard::IsPrimary() const {
  return owns_mutex_;
}

bool SingleInstanceGuard::StartActivationListener(HWND window) {
  if (!owns_mutex_ || activation_event_ == nullptr || window == nullptr) {
    return false;
  }
  return ::RegisterWaitForSingleObject(
             &activation_wait_, activation_event_, OnActivation, window,
             INFINITE, WT_EXECUTEDEFAULT) != FALSE;
}

UINT SingleInstanceGuard::ActivationWindowMessage() {
  return kActivationWindowMessage;
}

void CALLBACK SingleInstanceGuard::OnActivation(PVOID context,
                                                 BOOLEAN timed_out) {
  if (!timed_out && context != nullptr) {
    ::PostMessageW(static_cast<HWND>(context), kActivationWindowMessage, 0, 0);
  }
}

void SingleInstanceGuard::NotifyExistingInstance() {
  HANDLE activation_event =
      ::OpenEventW(EVENT_MODIFY_STATE, FALSE, kActivationEventName);
  if (activation_event == nullptr) {
    return;
  }
  ::AllowSetForegroundWindow(ASFW_ANY);
  ::SetEvent(activation_event);
  ::CloseHandle(activation_event);
}
