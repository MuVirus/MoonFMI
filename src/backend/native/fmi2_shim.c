/*
 * FMI 2.0.4 Co-Simulation C shim.
 *
 * MoonBit cannot express the parts of the FMI 2 C API that matter most for
 * safety: the callback struct with its variadic logger, `int`-sized booleans,
 * `size_t` lengths and string lifetimes. This file owns all of that.
 *
 * The only source of truth for the FMI types is the official header below.
 * Nothing here redefines a struct or an enum, so a header update cannot make
 * the shim and the FMUs disagree silently.
 */

#include "moonbit.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../../docs/standards/headers/fmi2/fmi2Functions.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

/* Messages are truncated to 4 KiB, measured in bytes before UTF-8 decoding. */
#define MOONFMI_FMI2_LOG_LIMIT 4096
#define MOONFMI_FMI2_ERROR_LIMIT 512

/* These are the assumptions the rest of the host is allowed to make. */
typedef char moonfmi_assert_boolean_is_int[
  sizeof(fmi2Boolean) == 4 ? 1 : -1];
typedef char moonfmi_assert_value_reference_is_int[
  sizeof(fmi2ValueReference) == 4 ? 1 : -1];
typedef char moonfmi_assert_real_is_double[sizeof(fmi2Real) == 8 ? 1 : -1];
typedef char moonfmi_assert_logger_is_first[
  offsetof(fmi2CallbackFunctions, logger) == 0 ? 1 : -1];

#if defined(_MSC_VER)
#define MOONFMI_THREAD_LOCAL __declspec(thread)
#else
#define MOONFMI_THREAD_LOCAL _Thread_local
#endif

static MOONFMI_THREAD_LOCAL char moonfmi_error[MOONFMI_FMI2_ERROR_LIMIT];

static void moonfmi_set_error(const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(moonfmi_error, sizeof(moonfmi_error), format, arguments);
  va_end(arguments);
  moonfmi_error[sizeof(moonfmi_error) - 1] = '\0';
}

static char *moonfmi_copy_bytes(moonbit_bytes_t bytes) {
  if (bytes == NULL) {
    return NULL;
  }
  int32_t length = Moonbit_array_length(bytes);
  char *copy = (char *)malloc((size_t)length + 1);
  if (copy == NULL) {
    moonfmi_set_error("out of memory while copying %d bytes", (int)length);
    return NULL;
  }
  if (length > 0) {
    memcpy(copy, bytes, (size_t)length);
  }
  copy[length] = '\0';
  return copy;
}

static moonbit_bytes_t moonfmi_bytes_from_text(const char *text) {
  size_t length = text == NULL ? 0 : strlen(text);
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)length, 0);
  if (length > 0) {
    memcpy(bytes, text, length);
  }
  return bytes;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonfmi_fmi2_last_error(void) {
  return moonfmi_bytes_from_text(moonfmi_error);
}

/*
 * Log payloads arrive as borrowed C strings owned by the FMU. They are copied
 * into MoonBit-owned bytes, truncated on a character boundary so the receiver
 * never sees half a UTF-8 sequence.
 */
static moonbit_bytes_t moonfmi_log_bytes(const char *text) {
  size_t length = text == NULL ? 0 : strlen(text);
  if (length > MOONFMI_FMI2_LOG_LIMIT) {
    length = MOONFMI_FMI2_LOG_LIMIT;
    while (length > 0 && ((unsigned char)text[length] & 0xC0) == 0x80) {
      length--;
    }
  }
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)length, 0);
  if (length > 0) {
    memcpy(bytes, text, length);
  }
  return bytes;
}

/* ------------------------------------------------------------------------- */
/* Library                                                                   */
/* ------------------------------------------------------------------------- */

typedef struct moonfmi_fmi2_library {
  void *handle;
  fmi2GetTypesPlatformTYPE *get_types_platform;
  fmi2GetVersionTYPE *get_version;
  fmi2InstantiateTYPE *instantiate;
  fmi2FreeInstanceTYPE *free_instance;
  fmi2SetupExperimentTYPE *setup_experiment;
  fmi2EnterInitializationModeTYPE *enter_initialization_mode;
  fmi2ExitInitializationModeTYPE *exit_initialization_mode;
  fmi2TerminateTYPE *terminate;
  fmi2DoStepTYPE *do_step;
  fmi2GetRealTYPE *get_real;
  fmi2SetRealTYPE *set_real;
  /* Retired instances keep their context alive until the library is released,
     so a callback from a buggy FMU cannot touch freed memory. */
  struct moonfmi_fmi2_instance *retired;
} moonfmi_fmi2_library;

typedef struct moonfmi_fmi2_instance moonfmi_fmi2_instance;
typedef void (*moonfmi_log_thunk)(void *closure,
                                  int32_t status,
                                  moonbit_bytes_t instance_name,
                                  moonbit_bytes_t category,
                                  moonbit_bytes_t message);

struct moonfmi_fmi2_instance {
  moonfmi_fmi2_library *library;
  fmi2Component component;
  char *instance_name;
  char *resource_path;
  void *log_closure;
  moonfmi_log_thunk log_thunk;
  uint64_t log_count;
  int32_t logging_enabled;
  int32_t freed;
  fmi2CallbackFunctions callbacks;
  moonfmi_fmi2_instance *next_retired;
};

static void *moonfmi_resolve(void *handle, const char *name) {
#ifdef _WIN32
  return (void *)GetProcAddress((HMODULE)handle, name);
#else
  return dlsym(handle, name);
#endif
}

static int moonfmi_resolve_into(void *handle, const char *name, void **slot) {
  void *address = moonfmi_resolve(handle, name);
  if (address == NULL) {
    moonfmi_set_error("the shared library does not export %s", name);
    return 0;
  }
  *slot = address;
  return 1;
}

MOONBIT_FFI_EXPORT
void *
moonfmi_fmi2_library_new(void *handle) {
  if (handle == NULL) {
    moonfmi_set_error("the dynamic library handle is null");
    return NULL;
  }
  moonfmi_fmi2_library *library =
      (moonfmi_fmi2_library *)calloc(1, sizeof(moonfmi_fmi2_library));
  if (library == NULL) {
    moonfmi_set_error("out of memory while creating the FMI 2 library");
    return NULL;
  }
  library->handle = handle;
  if (!moonfmi_resolve_into(handle, "fmi2GetTypesPlatform",
                            (void *)&library->get_types_platform) ||
      !moonfmi_resolve_into(handle, "fmi2GetVersion",
                            (void *)&library->get_version) ||
      !moonfmi_resolve_into(handle, "fmi2Instantiate",
                            (void *)&library->instantiate) ||
      !moonfmi_resolve_into(handle, "fmi2FreeInstance",
                            (void *)&library->free_instance) ||
      !moonfmi_resolve_into(handle, "fmi2SetupExperiment",
                            (void *)&library->setup_experiment) ||
      !moonfmi_resolve_into(handle, "fmi2EnterInitializationMode",
                            (void *)&library->enter_initialization_mode) ||
      !moonfmi_resolve_into(handle, "fmi2ExitInitializationMode",
                            (void *)&library->exit_initialization_mode) ||
      !moonfmi_resolve_into(handle, "fmi2Terminate",
                            (void *)&library->terminate) ||
      !moonfmi_resolve_into(handle, "fmi2DoStep",
                            (void *)&library->do_step) ||
      !moonfmi_resolve_into(handle, "fmi2GetReal",
                            (void *)&library->get_real) ||
      !moonfmi_resolve_into(handle, "fmi2SetReal",
                            (void *)&library->set_real)) {
    free(library);
    return NULL;
  }
  const char *platform = library->get_types_platform();
  if (platform == NULL || strcmp(platform, fmi2TypesPlatform) != 0) {
    moonfmi_set_error(
        "the FMU reports type platform '%s', the host requires '%s'",
        platform == NULL ? "(null)" : platform, fmi2TypesPlatform);
    free(library);
    return NULL;
  }
  return library;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonfmi_fmi2_library_version(void *handle) {
  moonfmi_fmi2_library *library = (moonfmi_fmi2_library *)handle;
  if (library == NULL) {
    return moonfmi_bytes_from_text("");
  }
  return moonfmi_bytes_from_text(library->get_version());
}

MOONBIT_FFI_EXPORT
void
moonfmi_fmi2_library_free(void *handle) {
  moonfmi_fmi2_library *library = (moonfmi_fmi2_library *)handle;
  if (library == NULL) {
    return;
  }
  moonfmi_fmi2_instance *instance = library->retired;
  while (instance != NULL) {
    moonfmi_fmi2_instance *next = instance->next_retired;
    free(instance->instance_name);
    free(instance->resource_path);
    free(instance);
    instance = next;
  }
  free(library);
}

/* ------------------------------------------------------------------------- */
/* Instance                                                                  */
/* ------------------------------------------------------------------------- */

static void *moonfmi_allocate_memory(size_t objects, size_t size) {
  return calloc(objects, size);
}

static void moonfmi_free_memory(void *memory) { free(memory); }

static void moonfmi_logger(fmi2ComponentEnvironment environment,
                           fmi2String instance_name,
                           fmi2Status status,
                           fmi2String category,
                           fmi2String message,
                           ...) {
  moonfmi_fmi2_instance *instance = (moonfmi_fmi2_instance *)environment;
  if (instance == NULL || instance->freed || !instance->logging_enabled ||
      instance->log_thunk == NULL || instance->log_closure == NULL) {
    return;
  }
  instance->log_count++;
  /* Ownership of the three byte arrays moves into MoonBit when the thunk is
     called; nothing here retains them. */
  moonbit_bytes_t name = moonfmi_log_bytes(instance_name);
  moonbit_bytes_t kind = moonfmi_log_bytes(category);
  moonbit_bytes_t text = moonfmi_log_bytes(message);
  instance->log_thunk(instance->log_closure, (int32_t)status, name, kind, text);
  /* The thunk borrows its arguments (MoonBit's native ABI does not hand
     ownership of an argument to a function it calls), so the shim stays the
     owner and releases them here. */
  moonbit_decref(name);
  moonbit_decref(kind);
  moonbit_decref(text);
}

MOONBIT_FFI_EXPORT
void *
moonfmi_fmi2_instance_new(void *library_handle,
                          moonbit_bytes_t instance_name,
                          moonbit_bytes_t guid,
                          moonbit_bytes_t resource_path,
                          int32_t logging_on,
                          void *log_closure,
                          moonfmi_log_thunk log_thunk) {
  moonfmi_fmi2_library *library = (moonfmi_fmi2_library *)library_handle;
  if (library == NULL) {
    moonfmi_set_error("the FMI 2 library has already been released");
    return NULL;
  }
  moonfmi_fmi2_instance *instance =
      (moonfmi_fmi2_instance *)calloc(1, sizeof(moonfmi_fmi2_instance));
  if (instance == NULL) {
    moonfmi_set_error("out of memory while creating an FMI 2 instance");
    return NULL;
  }
  instance->library = library;
  instance->log_closure = log_closure;
  instance->log_thunk = log_thunk;
  instance->logging_enabled = logging_on != 0;
  instance->instance_name = moonfmi_copy_bytes(instance_name);
  instance->resource_path = moonfmi_copy_bytes(resource_path);
  char *guid_text = moonfmi_copy_bytes(guid);
  if (instance->instance_name == NULL || instance->resource_path == NULL ||
      guid_text == NULL) {
    free(instance->instance_name);
    free(instance->resource_path);
    free(guid_text);
    free(instance);
    return NULL;
  }
  instance->callbacks.logger = moonfmi_logger;
  instance->callbacks.allocateMemory = moonfmi_allocate_memory;
  instance->callbacks.freeMemory = moonfmi_free_memory;
  instance->callbacks.stepFinished = NULL;
  instance->callbacks.componentEnvironment = instance;

  instance->component =
      library->instantiate(instance->instance_name, fmi2CoSimulation, guid_text,
                           instance->resource_path, &instance->callbacks,
                           fmi2False, logging_on != 0 ? fmi2True : fmi2False);
  free(guid_text);
  if (instance->component == NULL) {
    moonfmi_set_error(
        "fmi2Instantiate returned no component for instance '%s'",
        instance->instance_name);
    free(instance->instance_name);
    free(instance->resource_path);
    free(instance);
    return NULL;
  }
  return instance;
}

/* Marks the instance dead, retires its context and releases everything that
 * the FMU may still reach during `fmi2FreeInstance`. */
MOONBIT_FFI_EXPORT
void
moonfmi_fmi2_instance_free(void *handle) {
  moonfmi_fmi2_instance *instance = (moonfmi_fmi2_instance *)handle;
  if (instance == NULL || instance->freed) {
    return;
  }
  if (instance->component != NULL) {
    instance->library->free_instance(instance->component);
    instance->component = NULL;
  }
  instance->freed = 1;
  instance->logging_enabled = 0;
  if (instance->log_closure != NULL) {
    moonbit_decref(instance->log_closure);
    instance->log_closure = NULL;
  }
  instance->log_thunk = NULL;
  instance->next_retired = instance->library->retired;
  instance->library->retired = instance;
}

MOONBIT_FFI_EXPORT
uint64_t
moonfmi_fmi2_instance_log_count(void *handle) {
  moonfmi_fmi2_instance *instance = (moonfmi_fmi2_instance *)handle;
  return instance == NULL ? 0 : instance->log_count;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi2_instance_is_freed(void *handle) {
  moonfmi_fmi2_instance *instance = (moonfmi_fmi2_instance *)handle;
  return instance == NULL || instance->freed;
}

static moonfmi_fmi2_instance *moonfmi_live(void *handle) {
  moonfmi_fmi2_instance *instance = (moonfmi_fmi2_instance *)handle;
  if (instance == NULL || instance->freed || instance->component == NULL) {
    return NULL;
  }
  return instance;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi2_setup_experiment(void *handle,
                              int32_t tolerance_defined,
                              double tolerance,
                              double start_time,
                              int32_t stop_time_defined,
                              double stop_time) {
  moonfmi_fmi2_instance *instance = moonfmi_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi2Error;
  }
  return (int32_t)instance->library->setup_experiment(
      instance->component, tolerance_defined ? fmi2True : fmi2False, tolerance,
      start_time, stop_time_defined ? fmi2True : fmi2False, stop_time);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi2_enter_initialization_mode(void *handle) {
  moonfmi_fmi2_instance *instance = moonfmi_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi2Error;
  }
  return (int32_t)instance->library->enter_initialization_mode(
      instance->component);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi2_exit_initialization_mode(void *handle) {
  moonfmi_fmi2_instance *instance = moonfmi_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi2Error;
  }
  return (int32_t)instance->library->exit_initialization_mode(
      instance->component);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi2_terminate(void *handle) {
  moonfmi_fmi2_instance *instance = moonfmi_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi2Error;
  }
  return (int32_t)instance->library->terminate(instance->component);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi2_do_step(void *handle,
                     double current_time,
                     double step_size,
                     int32_t new_step) {
  moonfmi_fmi2_instance *instance = moonfmi_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi2Error;
  }
  return (int32_t)instance->library->do_step(
      instance->component, current_time, step_size,
      new_step ? fmi2True : fmi2False);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi2_get_real(void *handle,
                      const uint32_t *references,
                      double *values,
                      int32_t count) {
  moonfmi_fmi2_instance *instance = moonfmi_live(handle);
  if (instance == NULL || count < 0) {
    return (int32_t)fmi2Error;
  }
  return (int32_t)instance->library->get_real(
      instance->component, (const fmi2ValueReference *)references,
      (size_t)count, (fmi2Real *)values);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi2_set_real(void *handle,
                      const uint32_t *references,
                      const double *values,
                      int32_t count) {
  moonfmi_fmi2_instance *instance = moonfmi_live(handle);
  if (instance == NULL || count < 0) {
    return (int32_t)fmi2Error;
  }
  return (int32_t)instance->library->set_real(
      instance->component, (const fmi2ValueReference *)references,
      (size_t)count, (const fmi2Real *)values);
}
