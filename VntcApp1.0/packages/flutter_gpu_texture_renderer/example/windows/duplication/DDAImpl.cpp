/*
 * Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "DDAImpl.h"
#include <iomanip>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")

#pragma once
#pragma warning(disable : 4996)
#pragma warning(disable : 4838)

#if !defined(SAFE_RELEASE)
#define SAFE_RELEASE(X)                                                        \
  if (X) {                                                                     \
    X->Release();                                                              \
    X = nullptr;                                                               \
  }
#endif

#if !defined(PRINTERR1)
#define PRINTERR1(x)                                                           \
  printf(__FUNCTION__ ": Error 0x%08x at line %d in file %s\n", x, __LINE__,   \
         __FILE__);
#endif

#if !defined(PRINTERR)
#define PRINTERR(x, y)                                                         \
  printf(__FUNCTION__ ": Error 0x%08x in %s at line %d in file %s\n", x, y,    \
         __LINE__, __FILE__);
#endif

#define MICROSEC_TIME(x, f)                                                    \
  x.QuadPart *= 1000000;                                                       \
  x.QuadPart /= f.QuadPart;

/// Initialize DDA
HRESULT DDAImpl::Init() {
  IDXGIOutput *pOutput = nullptr;
  IDXGIDevice2 *pDevice = nullptr;
  IDXGIFactory1 *pFactory = nullptr;
  IDXGIAdapter *pAdapter = nullptr;
  IDXGIOutput1 *pOut1 = nullptr;

  /// Release all temporary refs before exit
#define CLEAN_RETURN(x)                                                        \
  SAFE_RELEASE(pDevice);                                                       \
  SAFE_RELEASE(pFactory);                                                      \
  SAFE_RELEASE(pOutput);                                                       \
  SAFE_RELEASE(pOut1);                                                         \
  SAFE_RELEASE(pAdapter);                                                      \
  return x;

  HRESULT hr = S_OK;
  /// To create a DDA object given a D3D11 device, we must first get to the DXGI
  /// Adapter associated with that device
  if (FAILED(hr = pD3DDev->QueryInterface(__uuidof(IDXGIDevice2),
                                          (void **)&pDevice))) {
    CLEAN_RETURN(hr);
  }

  if (FAILED(hr = pDevice->GetParent(__uuidof(IDXGIAdapter),
                                     (void **)&pAdapter))) {
    CLEAN_RETURN(hr);
  }
  /// Once we have the DXGI Adapter, we enumerate the attached display outputs,
  /// and select which one we want to capture This sample application always
  /// captures the primary display output, enumerated at index 0.
  if (FAILED(hr = pAdapter->EnumOutputs(0, &pOutput))) {
    CLEAN_RETURN(hr);
  }

  if (FAILED(hr = pOutput->QueryInterface(__uuidof(IDXGIOutput1),
                                          (void **)&pOut1))) {
    CLEAN_RETURN(hr);
  }
  /// Ask DXGI to create an instance of IDXGIOutputDuplication for the selected
  /// output. We can now capture this display output
  if (FAILED(hr = pOut1->DuplicateOutput(pDevice, &pDup))) {
    CLEAN_RETURN(hr);
  }

  DXGI_OUTDUPL_DESC outDesc;
  ZeroMemory(&outDesc, sizeof(outDesc));
  pDup->GetDesc(&outDesc);

  height = outDesc.ModeDesc.Height;
  width = outDesc.ModeDesc.Width;
  CLEAN_RETURN(hr);
}

/// Acquire a new frame from DDA, and return it as a Texture2D object.
/// 'wait' specifies the time in milliseconds that DDA shoulo wait for a new
/// screen update.
HRESULT DDAImpl::GetCapturedFrame(ID3D11Texture2D **ppTex2D, int wait,
                                  bool fail_if_equal) {
  HRESULT hr = S_OK;
  DXGI_OUTDUPL_FRAME_INFO frameInfo;
  ZeroMemory(&frameInfo, sizeof(frameInfo));
  // int acquired = 0;

#define RETURN_ERR(x)                                                          \
  {                                                                            \
    printf(__FUNCTION__ ": %d : Line %d return 0x%x\n", frameno, __LINE__, x); \
    return x;                                                                  \
  }

  if (pResource) {
    pDup->ReleaseFrame();
    pResource->Release();
    pResource = nullptr;
  }

  hr = pDup->AcquireNextFrame(wait, &frameInfo, &pResource);
  if (FAILED(hr)) {
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
      // printf(__FUNCTION__": %d : Wait for %d ms timed out\n", frameno, wait);
    }
    if (hr == DXGI_ERROR_INVALID_CALL) {
      printf(__FUNCTION__ ": %d : Invalid Call, previous frame not released?\n",
             frameno);
    }
    if (hr == DXGI_ERROR_ACCESS_LOST) {
      printf(__FUNCTION__ ": %d : Access lost, frame needs to be released?\n",
             frameno);
    }
    // RETURN_ERR(hr);
    return hr;
  }
  if (fail_if_equal) {
    if (frameInfo.AccumulatedFrames == 0 ||
        frameInfo.LastPresentTime.QuadPart == 0) {
      // No image update, only cursor moved.
      RETURN_ERR(DXGI_ERROR_WAIT_TIMEOUT);
    }
  }

  if (!pResource) {
    printf(__FUNCTION__ ": %d : Null output resource. Return error.\n",
           frameno);
    return E_UNEXPECTED;
  }

  if (FAILED(hr = pResource->QueryInterface(__uuidof(ID3D11Texture2D),
                                            (void **)ppTex2D))) {
    return hr;
  }

  LARGE_INTEGER pts = frameInfo.LastPresentTime;
  MICROSEC_TIME(pts, qpcFreq);
  // LONGLONG interval = pts.QuadPart - lastPTS.QuadPart;

  // printf(__FUNCTION__": %d : Accumulated Frames %u PTS Interval %lld PTS
  // %lld\n", frameno, frameInfo.AccumulatedFrames,  interval * 1000,
  // frameInfo.LastPresentTime.QuadPart);
  lastPTS = pts; // store microsec value
  frameno += frameInfo.AccumulatedFrames;
  return hr;
}

/// Release all resources
int DDAImpl::Cleanup() {
  if (pResource) {
    pDup->ReleaseFrame();
    SAFE_RELEASE(pResource);
  }

  width = height = frameno = 0;

  SAFE_RELEASE(pDup);
  SAFE_RELEASE(pCtx);
  SAFE_RELEASE(pD3DDev);

  return 0;
}

#include <d3d11.h>
#include <dxgi.h>
#include <mutex>
#include <thread>
#include <wrl/client.h>

using namespace Microsoft::WRL;

typedef void (*DuplicateCallback)(void *output, void *texture);

static DuplicateCallback duplicateCallback = nullptr;
static std::vector<void *> outputs;
static ComPtr<ID3D11Device> device = nullptr;
static ComPtr<ID3D11DeviceContext> deviceContext = nullptr;
static ComPtr<ID3D11Query> query = nullptr;
static std::atomic_bool stop = false;
static std::unique_ptr<std::thread> duplicateThreadHandle;
static std::mutex mutex;

#define HRB(f) MS_CHECK(f, return false;)
#define HRC(f) MS_CHECK(f, continue;)
#define MS_CHECK(f, ...)                                                       \
  do {                                                                         \
    HRESULT __ms_hr__ = (f);                                                   \
    if (FAILED(__ms_hr__)) {                                                   \
      std::clog                                                                \
          << #f "  ERROR@" << __LINE__ << __FUNCTION__ << ": (" << std::hex    \
          << __ms_hr__ << std::dec << ") "                                     \
          << std::error_code(__ms_hr__, std::system_category()).message()      \
          << std::endl                                                         \
          << std::flush;                                                       \
      __VA_ARGS__                                                              \
    }                                                                          \
  } while (false)
#define LUID(desc)                                                             \
  (((int64_t)desc.AdapterLuid.HighPart << 32) | desc.AdapterLuid.LowPart)

namespace {
void duplicateThread() {
  std::unique_ptr<DDAImpl> dda = nullptr;
  ComPtr<ID3D11Texture2D> texture = nullptr;
  ComPtr<ID3D11Texture2D> sharedTexture = nullptr;
  ComPtr<IDXGIResource> resource = nullptr;

  while (!stop) {
    if (!duplicateCallback || outputs.size() == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      continue;
    }
    if (!dda) {
      dda = std::make_unique<DDAImpl>(device.Get());
      dda->Init();
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (SUCCEEDED(
            dda->GetCapturedFrame(texture.ReleaseAndGetAddressOf(), 100))) {
      D3D11_TEXTURE2D_DESC desc;
      ZeroMemory(&desc, sizeof(desc));
      texture->GetDesc(&desc);
      desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
      HRC(device->CreateTexture2D(&desc, nullptr,
                                  sharedTexture.ReleaseAndGetAddressOf()));
      ComPtr<ID3D11Query> query;
      D3D11_QUERY_DESC queryDesc;
      ZeroMemory(&queryDesc, sizeof(queryDesc));
      queryDesc.Query = D3D11_QUERY_EVENT;
      queryDesc.MiscFlags = 0;
      HRC(device->CreateQuery(&queryDesc, query.ReleaseAndGetAddressOf()));
      auto start = std::chrono::steady_clock::now();
      deviceContext->Begin(query.Get());
      deviceContext->CopyResource(sharedTexture.Get(), texture.Get());
      deviceContext->End(query.Get());
      BOOL bResult = FALSE;
      while (!bResult) {
        HRESULT hr =
            deviceContext->GetData(query.Get(), &bResult, sizeof(BOOL), 0);
        if (SUCCEEDED(hr)) {
          if (bResult) {
            break;
          }
        }
      }
      deviceContext->Flush();
      auto end = std::chrono::steady_clock::now();
      auto elapsed =
          std::chrono::duration_cast<std::chrono::milliseconds>(end - start)
              .count();
      // std::cout << "copy elapsed:" << elapsed << " ms" << std::endl;
      HRC(sharedTexture.As(&resource));
      std::lock_guard<std::mutex> lock(mutex);
      for (auto output : outputs) {
        duplicateCallback(output, sharedTexture.Get());
      }
    }
    // else {
    //   std::cerr << "dda reset" << std::endl;
    //   dda.reset();
    // }
  }
}

bool CreateDevice(int64_t luid) {
  HRESULT hr = S_OK;

  ComPtr<IDXGIFactory1> factory1 = nullptr;
  ComPtr<IDXGIAdapter1> adapter1 = nullptr;
  HRB(CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                         (void **)factory1.ReleaseAndGetAddressOf()));

  ComPtr<IDXGIAdapter1> tmpAdapter = nullptr;
  for (int i = 0;
       !FAILED(factory1->EnumAdapters1(i, tmpAdapter.ReleaseAndGetAddressOf()));
       i++) {
    DXGI_ADAPTER_DESC1 desc = DXGI_ADAPTER_DESC1();
    tmpAdapter->GetDesc1(&desc);
    if (LUID(desc) == luid) {
      adapter1.Swap(tmpAdapter);
      break;
    }
  }
  if (!adapter1) {
    return false;
  }

  UINT createDeviceFlags = 0;
  D3D_FEATURE_LEVEL featureLevels[] = {
      D3D_FEATURE_LEVEL_11_0,
  };
  UINT numFeatureLevels = ARRAYSIZE(featureLevels);

  D3D_FEATURE_LEVEL featureLevel;
  D3D_DRIVER_TYPE d3dDriverType =
      adapter1 ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE;
  hr = D3D11CreateDevice(adapter1.Get(), d3dDriverType, nullptr,
                         createDeviceFlags, featureLevels, numFeatureLevels,
                         D3D11_SDK_VERSION, device.ReleaseAndGetAddressOf(),
                         &featureLevel, deviceContext.ReleaseAndGetAddressOf());

  if (FAILED(hr)) {
    return false;
  }

  if (featureLevel != D3D_FEATURE_LEVEL_11_0) {
    std::cerr << "Direct3D Feature Level 11 unsupported." << std::endl;
    return false;
  }
  D3D11_QUERY_DESC queryDesc;
  ZeroMemory(&queryDesc, sizeof(queryDesc));
  queryDesc.Query = D3D11_QUERY_EVENT;
  queryDesc.MiscFlags = 0;
  if (FAILED(device->CreateQuery(&queryDesc, query.ReleaseAndGetAddressOf()))) {
    return false;
  }
  return true;
}
} // namespace

extern "C" __declspec(dllexport) void StartDuplicateThread(int64_t luid) {
  std::lock_guard<std::mutex> lock(mutex);
  if (duplicateThreadHandle)
    return;
  if (!CreateDevice(luid))
    return;

  HMODULE hDll = LoadLibraryA("flutter_gpu_texture_renderer_plugin.dll");
  duplicateCallback = reinterpret_cast<DuplicateCallback>(
      GetProcAddress(hDll, "FlutterGpuTextureRendererPluginCApiSetTexture"));

  duplicateThreadHandle = std::make_unique<std::thread>(duplicateThread);
}

extern "C" __declspec(dllexport) void StopDuplicateThread() {
  stop = true;
  duplicateThreadHandle->join();
  duplicateThreadHandle.reset();
}

extern "C" __declspec(dllexport) void AddOutput(void *output) {
  std::lock_guard<std::mutex> lock(mutex);
  outputs.push_back(output);
}

extern "C" __declspec(dllexport) void RemoveOutput(void *output) {
  std::lock_guard<std::mutex> lock(mutex);
  auto it = std::find(outputs.begin(), outputs.end(), output);
  if (it != outputs.end()) {
    outputs.erase(it);
  }
}
