#include "flutter_gpu_texture_renderer_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <sstream>

namespace flutter_gpu_texture_renderer {

DXGI_ADAPTER_DESC FlutterGpuTextureRendererPlugin::desc_ = {0};
bool FlutterGpuTextureRendererPlugin::unusable_ = false;

// static
void FlutterGpuTextureRendererPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  if (Check(registrar)) {
    auto plugin = std::make_unique<FlutterGpuTextureRendererPlugin>(registrar);
    if (Check(plugin.get())) {
      registrar->AddPlugin(std::move(plugin));
    }
  }
}

FlutterGpuTextureRendererPlugin::FlutterGpuTextureRendererPlugin(
    flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {
  if (Check(registrar)) {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "flutter_gpu_texture_renderer",
            &flutter::StandardMethodCodec::GetInstance());
    if (Check(channel.get())) {
      channel->SetMethodCallHandler([&](const auto &call, auto result) {
        this->HandleMethodCall(call, std::move(result));
      });
      auto view = registrar_->GetView();
      if (Check(view)) {
        auto adapter = view->GetGraphicsAdapter();
        if (Check(adapter)) {
          if (SUCCEEDED(adapter->GetDesc(&desc_))) {
            std::wcout << "Graphics adapter: " << desc_.Description
                       << std::endl;
          } else {
            unusable_ = true;
          }
        }
      }
    }
  }
}

FlutterGpuTextureRendererPlugin::~FlutterGpuTextureRendererPlugin() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto &output : outputs_)
    output.reset();
  outputs_.clear();
}

void FlutterGpuTextureRendererPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::lock_guard<std::mutex> lock(mutex_);
  try {
    if (method_call.method_name().compare("registerTexture") == 0) {
      auto output =
          std::make_unique<D3D11Output>(registrar_->texture_registrar());
      if (!Check(output.get())) {
        return result->Error("make_unique", "Failed to create output.");
      }
      auto id = output->TextureId();
      outputs_.push_back(std::move(output));
      return result->Success(flutter::EncodableValue(id));
    } else if (method_call.method_name().compare("unregisterTexture") == 0) {
      auto args = std::get<flutter::EncodableMap>(*method_call.arguments());
      auto id = args.at(flutter::EncodableValue("id")).LongValue();
      auto new_end =
          std::remove_if(outputs_.begin(), outputs_.end(),
                         [id](const std::unique_ptr<D3D11Output> &output) {
                           return output->TextureId() == id;
                         });
      outputs_.erase(new_end, outputs_.end());
      return result->Success();
    } else if (method_call.method_name().compare("output") == 0) {
      auto args = std::get<flutter::EncodableMap>(*method_call.arguments());
      auto id = args.at(flutter::EncodableValue("id")).LongValue();
      auto it = std::find_if(outputs_.begin(), outputs_.end(),
                             [id](const std::unique_ptr<D3D11Output> &output) {
                               return output->TextureId() == id;
                             });
      if (it != outputs_.end()) {
        return result->Success(flutter::EncodableValue((int64_t)(*it).get()));
      }
    } else if (method_call.method_name().compare("fps") == 0) {
      auto args = std::get<flutter::EncodableMap>(*method_call.arguments());
      auto id = args.at(flutter::EncodableValue("id")).LongValue();
      auto it = std::find_if(outputs_.begin(), outputs_.end(),
                             [id](const std::unique_ptr<D3D11Output> &output) {
                               return output->TextureId() == id;
                             });
      if (it != outputs_.end()) {
        return result->Success(
            flutter::EncodableValue((int16_t)((*it)->Fps())));
      }
    } else {
      return result->NotImplemented();
    }
  } catch (std::exception &e) {
    std::cerr << e.what() << std::endl;
    return result->Error("", e.what());
  }

  return result->Error("", "");
}

} // namespace flutter_gpu_texture_renderer
