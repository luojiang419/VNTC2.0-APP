#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

class SingleInstanceGuard {
 public:
  SingleInstanceGuard();
  ~SingleInstanceGuard();

  SingleInstanceGuard(const SingleInstanceGuard&) = delete;
  SingleInstanceGuard& operator=(const SingleInstanceGuard&) = delete;

  bool IsPrimary() const;
  bool StartActivationListener(HWND window);
  static UINT ActivationWindowMessage();
  static void NotifyExistingInstance();

 private:
  static void CALLBACK OnActivation(PVOID context, BOOLEAN timed_out);

  HANDLE mutex_ = nullptr;
  HANDLE activation_event_ = nullptr;
  HANDLE activation_wait_ = nullptr;
  bool owns_mutex_ = false;
};

#endif  // RUNNER_SINGLE_INSTANCE_H_
