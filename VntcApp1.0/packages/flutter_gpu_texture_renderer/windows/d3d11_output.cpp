#include "d3d11_output.h"

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")

#define MS_ENSURE(f, ...) MS_CHECK(f, return __VA_ARGS__;)
#define MS_WARN(f) MS_CHECK(f)
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

namespace flutter_gpu_texture_renderer {

D3D11Output::D3D11Output(flutter::TextureRegistrar *texture_registrar)
    : texture_registrar_(texture_registrar) {
  surface_desc_ = std::make_unique<FlutterDesktopGpuSurfaceDescriptor>();
  if (surface_desc_.get() == nullptr) {
    unusable_ = true;
  }

  variant_ = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
                                 [&](size_t width, size_t height) {
                                   std::lock_guard<std::mutex> lock(mutex_);
                                   rendering_ = true;
                                   return surface_desc_.get();
                                 }));

  if (texture_registrar_) {
    texture_id_ = texture_registrar_->RegisterTexture(variant_.get());
  } else {
    unusable_ = true;
  }
}

D3D11Output::~D3D11Output() {
  if (texture_id_)
    texture_registrar_->UnregisterTexture(texture_id_);
}

bool D3D11Output::SetTexture(void *texture) {
  if (unusable_) {
    return false;
  }
  if (!texture)
    return false;

  if (!EnsureTexture((ID3D11Texture2D *)texture))
    return false;

  return Present();
}

// https://api.flutter.dev/linux-embedder/flutter__texture__registrar_8h_source.html
bool D3D11Output::EnsureTexture(ID3D11Texture2D *texture) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (rendering_) {
    std::cout << __FILE__ << " rendering: " << rendering_ << std::endl;
  }
  tex_ = texture;
  D3D11_TEXTURE2D_DESC desc;
  tex_->GetDesc(&desc);
  ComPtr<ID3D11Device> dev = nullptr;
  tex_->GetDevice(dev.ReleaseAndGetAddressOf());
  if (!dev) {
    std::cout << __FILE__ << " GetDevice failed" << std::endl;
    return false;
  }
  if (dev_ != dev) {
    fail_counter_ = 0;
    if (dev_) {
      std::cout << __FILE__ << " d3d11 device changed" << std::endl;
    }
    dev_ = dev;
    dev_->GetImmediateContext(ctx_.ReleaseAndGetAddressOf());
    desc_ready_ = false;
  }
  if (!desc_ready_ || surface_desc_->width != desc.Width ||
      surface_desc_->height != desc.Height) {
    if (fail_counter_ > 10) {
      std::cout << __FILE__ << " fail_counter_ > 10" << std::endl;
      return false;
    }
    fail_counter_++;
    if (surface_desc_->width != 0)
      std::cout << __FILE__ << " reset desc" << std::endl;
    MS_ENSURE(dev_->CreateTexture2D(&desc, nullptr,
                                    tex_buffers_.ReleaseAndGetAddressOf()),
              false);
    ComPtr<IDXGIResource> resource = nullptr;
    MS_ENSURE(tex_buffers_.As(&resource), false);
    HANDLE shared_handle = nullptr;
    MS_ENSURE(resource->GetSharedHandle(&shared_handle), false);

    surface_desc_->struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    surface_desc_->handle = shared_handle;
    surface_desc_->width = surface_desc_->visible_width = desc.Width;
    surface_desc_->height = surface_desc_->visible_height = desc.Height;
    surface_desc_->format = kFlutterDesktopPixelFormatBGRA8888;
    surface_desc_->release_context = this;
    surface_desc_->release_callback = [](void *release_context) {
      D3D11Output *self = (D3D11Output *)release_context;
      // self->SetFPS();
      self->rendering_ = false;
    };
    desc_ready_ = true;
  }
  ctx_->CopyResource(tex_buffers_.Get(), tex_.Get());
  ctx_->Flush();
  fail_counter_ = 0;

  return true;
}

bool D3D11Output::Present() {
  return texture_registrar_->MarkTextureFrameAvailable(texture_id_);
}

void D3D11Output::SetFPS() {
  this_fps_++;
  auto now = std::chrono::steady_clock::now();
  auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                     now - fps_time_point_.load())
                     .count();
  if (elapsed >= 1) {
    fps_time_point_ = now;
    last_fps_.store(this_fps_);
    this_fps_ = 0;
    // std::cout << "fps:" << (int)last_fps_.load() << std::endl;
  }
}

} // namespace flutter_gpu_texture_renderer
