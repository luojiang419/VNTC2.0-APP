#ifndef FLUTTER_PLUGIN_FLUTTER_GPU_TEXTURE_RENDERER_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_GPU_TEXTURE_RENDERER_PLUGIN_H_

#include "d3d11_output.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <memory>
#include <mutex>
#include <wrl/client.h>

using namespace Microsoft::WRL;

namespace flutter_gpu_texture_renderer {

class FlutterGpuTextureRendererPlugin : public flutter::Plugin {
public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterGpuTextureRendererPlugin(flutter::PluginRegistrarWindows *registrar);

  virtual ~FlutterGpuTextureRendererPlugin();

  // Disallow copy and assign.
  FlutterGpuTextureRendererPlugin(const FlutterGpuTextureRendererPlugin &) =
      delete;
  FlutterGpuTextureRendererPlugin &
  operator=(const FlutterGpuTextureRendererPlugin &) = delete;

  static int64_t GetAdapterLuid() {
    if (unusable_)
      return 0;
    return (int64_t(desc_.AdapterLuid.HighPart) << 32) |
           desc_.AdapterLuid.LowPart;
  }

  // https://github.com/rustdesk/rustdesk/commit/89150317e14500170f30570c873b7efa8cb826ad#commitcomment-138449157
  static bool Check(void *ptr) {
    if (unusable_)
      return false;
    if (ptr == nullptr) {
      unusable_ = true;
      std::cout << "set plugin flutter_gpu_texture_renderer unusable"
                << std::endl;
      return false;
    }
    return true;
  }

private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

private:
  flutter::PluginRegistrarWindows *registrar_ = nullptr;
  std::vector<std::unique_ptr<D3D11Output>> outputs_;
  std::mutex mutex_;
  static DXGI_ADAPTER_DESC desc_;
  static bool unusable_;
};

} // namespace flutter_gpu_texture_renderer

#endif // FLUTTER_PLUGIN_FLUTTER_GPU_TEXTURE_RENDERER_PLUGIN_H_
