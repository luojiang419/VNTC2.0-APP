#ifndef FFI_H
#define FFI_H

typedef void (*DuplicateCallback)(void *output, void* texture);

void StartDuplicateThread(long long luid) {};

void StopDuplicateThread() {};

void AddOutput(void *output) {};

void RemoveOutput(void *output) {};

long long FlutterGpuTextureRendererPluginCApiGetAdapterLuid() {};

#endif