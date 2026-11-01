/*
 * Tiny shared library used by the P0 dynamic-loading spike.
 *
 * Build it with tests/abi/build-fixture.ps1 (Windows) or
 * tests/abi/build-fixture.sh (Linux). The results land in tests/abi/.cache/
 * and are intentionally not committed.
 */

#include <stdint.h>

#ifdef _WIN32
#define MOONFMI_EXPORT __declspec(dllexport)
#else
#define MOONFMI_EXPORT __attribute__((visibility("default")))
#endif

typedef struct moonfmi_point {
  double x;
  double y;
} moonfmi_point;

typedef void (*moonfmi_callback)(int32_t value, const char *text);

MOONFMI_EXPORT
int32_t moonfmi_add(int32_t a, int32_t b) {
  return a + b;
}

MOONFMI_EXPORT
double moonfmi_multiply(double a, double b) {
  return a * b;
}

MOONFMI_EXPORT
void moonfmi_fill_point(moonfmi_point *point, double x, double y) {
  if (point != 0) {
    point->x = x;
    point->y = y;
  }
}

MOONFMI_EXPORT
int32_t moonfmi_invoke(moonfmi_callback callback, int32_t value) {
  if (callback == 0) {
    return -1;
  }
  callback(value, "from fixture");
  return 0;
}
