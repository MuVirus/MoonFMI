/*
 * Minimal dynamic-library shim for the P0 native backend.
 *
 * MoonBit's FFI can pass `Bytes` and pointers across the boundary, but the
 * platform APIs differ: Windows uses LoadLibraryExW/GetProcAddress/FreeLibrary,
 * POSIX uses dlopen/dlsym/dlclose. Keeping both in one C file means the
 * MoonBit side stays target-independent.
 */

#include "moonbit.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

static char *moonfmi_copy_bytes(moonbit_bytes_t bytes) {
  int32_t len = Moonbit_array_length(bytes);
  char *copy = (char *)malloc((size_t)len + 1);
  if (copy == NULL) {
    return NULL;
  }
  memcpy(copy, bytes, (size_t)len);
  copy[len] = '\0';
  return copy;
}

static moonbit_bytes_t moonfmi_bytes_from_string(const char *text) {
  size_t len = text == NULL ? 0 : strlen(text);
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) {
    memcpy(bytes, text, len);
  }
  return bytes;
}

#ifdef _WIN32

static char *moonfmi_utf8_from_wide(const wchar_t *text) {
  int len = WideCharToMultiByte(
    CP_UTF8,
    0,
    text,
    -1,
    NULL,
    0,
    NULL,
    NULL
  );
  if (len <= 0) {
    return NULL;
  }
  char *result = (char *)malloc((size_t)len);
  if (result == NULL) {
    return NULL;
  }
  if (WideCharToMultiByte(
        CP_UTF8,
        0,
        text,
        -1,
        result,
        len,
        NULL,
        NULL
      ) <= 0) {
    free(result);
    return NULL;
  }
  return result;
}

static char *moonfmi_windows_error(DWORD code) {
  wchar_t *wide = NULL;
  DWORD len = FormatMessageW(
    FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
    FORMAT_MESSAGE_IGNORE_INSERTS,
    NULL,
    code,
    MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
    (LPWSTR)&wide,
    0,
    NULL
  );
  if (len == 0 || wide == NULL) {
    char fallback[64];
    snprintf(fallback, sizeof(fallback), "Windows error %lu", (unsigned long)code);
    return _strdup(fallback);
  }
  char *utf8 = moonfmi_utf8_from_wide(wide);
  LocalFree(wide);
  if (utf8 == NULL) {
    char fallback[64];
    snprintf(fallback, sizeof(fallback), "Windows error %lu", (unsigned long)code);
    return _strdup(fallback);
  }
  // Drop the trailing CR/LF that FormatMessage appends.
  size_t n = strlen(utf8);
  while (n > 0 && (utf8[n - 1] == '\r' || utf8[n - 1] == '\n')) {
    utf8[--n] = '\0';
  }
  return utf8;
}

static char *moonfmi_last_error_text(void) {
  return moonfmi_windows_error(GetLastError());
}

MOONBIT_FFI_EXPORT
void *
moonfmi_dl_open(moonbit_bytes_t path) {
  char *utf8 = moonfmi_copy_bytes(path);
  if (utf8 == NULL) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  if (wide_len <= 0) {
    free(utf8);
    SetLastError(ERROR_INVALID_NAME);
    return NULL;
  }
  wchar_t *wide = (wchar_t *)malloc((size_t)wide_len * sizeof(wchar_t));
  if (wide == NULL) {
    free(utf8);
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, wide_len);
  free(utf8);
  HMODULE handle = LoadLibraryExW(wide, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
  free(wide);
  return (void *)handle;
}

MOONBIT_FFI_EXPORT
void *
moonfmi_dl_sym(void *handle, moonbit_bytes_t symbol) {
  char *name = moonfmi_copy_bytes(symbol);
  if (name == NULL) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  FARPROC address = GetProcAddress((HMODULE)handle, name);
  free(name);
  return (void *)address;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_dl_close(void *handle) {
  return FreeLibrary((HMODULE)handle) ? 0 : -1;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_dl_last_error_code(void) {
  return (int32_t)GetLastError();
}

#else

MOONBIT_FFI_EXPORT
int32_t
moonfmi_dl_last_error_code(void) {
  return 0;
}

static char *moonfmi_last_error_text(void) {
  const char *error = dlerror();
  return strdup(error == NULL ? "unknown dynamic-loader error" : error);
}

MOONBIT_FFI_EXPORT
void *
moonfmi_dl_open(moonbit_bytes_t path) {
  char *name = moonfmi_copy_bytes(path);
  if (name == NULL) {
    return NULL;
  }
  // Clear any stale error before the call so the message belongs to this load.
  dlerror();
  void *handle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
  free(name);
  return handle;
}

MOONBIT_FFI_EXPORT
void *
moonfmi_dl_sym(void *handle, moonbit_bytes_t symbol) {
  char *name = moonfmi_copy_bytes(symbol);
  if (name == NULL) {
    return NULL;
  }
  dlerror();
  void *address = dlsym(handle, name);
  free(name);
  return address;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_dl_close(void *handle) {
  return dlclose(handle);
}

#endif

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonfmi_dl_last_error(void) {
  char *text = moonfmi_last_error_text();
  moonbit_bytes_t bytes = moonfmi_bytes_from_string(text);
  free(text);
  return bytes;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonfmi_dl_host_platform(void) {
#if defined(_WIN32) || defined(_WIN64)
#if defined(_M_ARM64) || defined(__aarch64__)
  return moonfmi_bytes_from_string("windows-arm64");
#else
  return moonfmi_bytes_from_string("windows-x64");
#endif
#elif defined(__APPLE__)
#if defined(__aarch64__) || defined(__ARM64ARCH__)
  return moonfmi_bytes_from_string("darwin-arm64");
#else
  return moonfmi_bytes_from_string("darwin-x64");
#endif
#elif defined(__linux__) || defined(__unix__)
#if defined(__aarch64__) || defined(__ARM_ARCH_8__)
  return moonfmi_bytes_from_string("linux-arm64");
#else
  return moonfmi_bytes_from_string("linux-x64");
#endif
#else
  return moonfmi_bytes_from_string("unknown");
#endif
}
