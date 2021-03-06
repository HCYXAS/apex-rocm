#include <ATen/ATen.h>
#include <ATen/hip/HIPContext.h>
#include <THH/THHNumerics.cuh>

#include "THH/THH.h"

#include <hip/hip_runtime.h>

#include "compat.h"


#define cudaCheckErrors(msg) \
    do { \
        hipError_t __err = hipGetLastError(); \
        if (__err != hipSuccess) { \
            fprintf(stderr, "Fatal error: %s (%s at %s:%d)\n", \
                msg, hipGetErrorString(__err), \
                __FILE__, __LINE__); \
            fprintf(stderr, "*** FAILED - ABORTING\n"); \
            exit(1); \
        } \
    } while (0)

template<>
struct std::hash<hipIpcMemHandle_t> {
  size_t operator() (const hipIpcMemHandle_t& handle) const {
    size_t hash = 0;
    uint8_t* ptr = (uint8_t*)&handle;
    assert(sizeof(uint8_t) == 1);
    for (int i=0; i<sizeof(hipIpcMemHandle_t); i++) {
      hash += *ptr;
      ptr++;
    }
    return hash;
  }
};

template<>
struct std::equal_to<hipIpcMemHandle_t> {
  bool operator() (const hipIpcMemHandle_t &lhs,
                             const hipIpcMemHandle_t &rhs) const {
    return (std::memcmp((void*) &lhs,
                        (void*) &rhs,
                        sizeof(hipIpcMemHandle_t)) == 0);
  }
};

namespace {

namespace gpuipc {
//from: src/operator/nn/cudnn/nhwc_batch_norm_kernel.h
// The number of threads per pixel.
const int THREADS_PER_PIXEL = 16;
// The number of elements per ldg.
const int ELEMENTS_PER_LDG = 4;
// The number of reducing ops, each uses its own space : mean, var, dscale, dbias
const int REDUCE_OPS = 4;
// Maximum block.y supported - limited due to buffer allocation
const int MAX_BLOCK_Y = 256;
const int MAX_OFFSET = REDUCE_OPS*MAX_BLOCK_Y;
const int BYTES_PER_ELEM = 4;
// Buffer size per sync step
const int SINGLE_SYNC_BUFFER_BYTES = MAX_OFFSET*THREADS_PER_PIXEL*2*ELEMENTS_PER_LDG*BYTES_PER_ELEM;
};

class IpcMemHandleRegistry {
public:
  void* getPtr(const hipIpcMemHandle_t& handle, int64_t offset) {
    if (registry_.count(handle) == 0) {
      registry_.insert(std::make_pair(handle, RegistryEntry()));
      registry_[handle].dev_ptr = ipcOpenMem(handle);
    }
    registry_[handle].ref_count++;
    return (((uint8_t*)registry_[handle].dev_ptr) + offset);
  }

  void releasePtr(const hipIpcMemHandle_t& handle) {
    if (registry_.count(handle) == 0) {
    }
    if (--registry_[handle].ref_count == 0) {
      ipcCloseMem(registry_[handle].dev_ptr);
      registry_.erase(handle);
    }
  }

  struct RegistryEntry {
    void* dev_ptr;
    int   ref_count;
    RegistryEntry() : dev_ptr(NULL) , ref_count(0) {}
  };

protected:
  std::unordered_map<hipIpcMemHandle_t, RegistryEntry> registry_;

  void* ipcOpenMem(const hipIpcMemHandle_t& handle) {
    void *data;
    hipIpcOpenMemHandle(&data, handle, hipIpcMemLazyEnablePeerAccess);
    cudaCheckErrors("ipc init");
    return data;
  }

  void ipcCloseMem(void* dev_ptr) {
    hipIpcCloseMemHandle(dev_ptr);
    cudaCheckErrors("ipc close");
  }

};

}

static IpcMemHandleRegistry ipc_mem_registry;

int64_t get_buffer_size(const int bn_sync_steps) {
  return bn_sync_steps * gpuipc::SINGLE_SYNC_BUFFER_BYTES;
}

void* get_remote_data_ptr(const at::Tensor& handle, const int64_t offset) {
  hipIpcMemHandle_t my_handle;
  memcpy((unsigned char *)(&my_handle), handle.DATA_PTR<uint8_t>(), sizeof(my_handle));
  return ipc_mem_registry.getPtr(my_handle, offset);
}

void close_remote_data(const at::Tensor& handle) {
    hipIpcMemHandle_t my_handle;
    memcpy((unsigned char *)(&my_handle), handle.DATA_PTR<uint8_t>(), sizeof(my_handle));
  ipc_mem_registry.releasePtr(my_handle);
}

void* get_data_ptr(
                   const at::Tensor& data) {
  return data.DATA_PTR<uint8_t>();
}
