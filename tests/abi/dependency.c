#include <stdint.h>

#ifdef _WIN32
#define MOONFMI_EXPORT __declspec(dllexport)
#else
#define MOONFMI_EXPORT __attribute__((visibility("default")))
#endif

MOONFMI_EXPORT
int32_t moonfmi_dependency_value(void) {
  return 41;
}
