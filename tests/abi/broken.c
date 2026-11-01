/*
 * A shared library that intentionally depends on a second library which is
 * deleted after linking. Loading it at runtime must fail with a clear
 * "missing dependency" diagnosis.
 */

#include <stdint.h>

#ifdef _WIN32
#define MOONFMI_EXPORT __declspec(dllexport)
#else
#define MOONFMI_EXPORT __attribute__((visibility("default")))
#endif

extern int32_t moonfmi_dependency_value(void);

MOONFMI_EXPORT
int32_t moonfmi_broken_value(void) {
  return moonfmi_dependency_value() + 1;
}
