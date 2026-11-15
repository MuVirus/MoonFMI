/*
 * FMI 3.0.2 C shim.
 *
 * Same ownership story as the FMI 2 shim: MoonBit cannot express the FMI 3
 * callback signatures, the 1-byte `fmi3Boolean`/`fmi3Clock`, `size_t`
 * lengths and string lifetimes, so this file owns all of that. The only
 * source of truth for the FMI types is the official header below.
 */

#include "moonbit.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../../docs/standards/headers/fmi3/fmi3Functions.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

/* Messages are truncated to 4 KiB, measured in bytes before UTF-8 decoding. */
#define MOONFMI_FMI3_LOG_LIMIT 4096
#define MOONFMI_FMI3_ERROR_LIMIT 512

/* These are the assumptions the rest of the host is allowed to make. */
typedef char moonfmi_fmi3_assert_boolean_is_one_byte[
  sizeof(fmi3Boolean) == 1 ? 1 : -1];
typedef char moonfmi_fmi3_assert_clock_is_one_byte[
  sizeof(fmi3Clock) == 1 ? 1 : -1];
typedef char moonfmi_fmi3_assert_value_reference_is_int[
  sizeof(fmi3ValueReference) == 4 ? 1 : -1];
typedef char moonfmi_fmi3_assert_float32_is_float[
  sizeof(fmi3Float32) == 4 ? 1 : -1];

#if defined(_MSC_VER)
#define MOONFMI_THREAD_LOCAL __declspec(thread)
#else
#define MOONFMI_THREAD_LOCAL _Thread_local
#endif

static MOONFMI_THREAD_LOCAL char moonfmi_fmi3_error[MOONFMI_FMI3_ERROR_LIMIT];

static void moonfmi_fmi3_set_error(const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(moonfmi_fmi3_error, sizeof(moonfmi_fmi3_error), format, arguments);
  va_end(arguments);
  moonfmi_fmi3_error[sizeof(moonfmi_fmi3_error) - 1] = '\0';
}

static char *moonfmi_fmi3_copy_bytes(moonbit_bytes_t bytes) {
  if (bytes == NULL) {
    return NULL;
  }
  int32_t length = Moonbit_array_length(bytes);
  char *copy = (char *)malloc((size_t)length + 1);
  if (copy == NULL) {
    moonfmi_fmi3_set_error("out of memory while copying %d bytes", (int)length);
    return NULL;
  }
  if (length > 0) {
    memcpy(copy, bytes, (size_t)length);
  }
  copy[length] = '\0';
  return copy;
}

static moonbit_bytes_t moonfmi_fmi3_bytes_from_text(const char *text) {
  size_t length = text == NULL ? 0 : strlen(text);
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)length, 0);
  if (length > 0) {
    memcpy(bytes, text, length);
  }
  return bytes;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonfmi_fmi3_last_error(void) {
  return moonfmi_fmi3_bytes_from_text(moonfmi_fmi3_error);
}

/* Log payloads arrive as borrowed C strings owned by the FMU. They are
   copied into MoonBit-owned bytes like in the FMI 2 shim. */
static moonbit_bytes_t moonfmi_fmi3_log_bytes(const char *text) {
  size_t length = text == NULL ? 0 : strlen(text);
  if (length > MOONFMI_FMI3_LOG_LIMIT) {
    length = MOONFMI_FMI3_LOG_LIMIT;
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

typedef struct moonfmi_fmi3_instance moonfmi_fmi3_instance;
typedef void (*moonfmi_fmi3_log_thunk)(void *closure,
                                       int32_t status,
                                       moonbit_bytes_t category,
                                       moonbit_bytes_t message);

typedef struct moonfmi_fmi3_library {
  void *handle;
  fmi3GetVersionTYPE *get_version;
  fmi3FreeInstanceTYPE *free_instance;
  fmi3EnterInitializationModeTYPE *enter_initialization_mode;
  fmi3ExitInitializationModeTYPE *exit_initialization_mode;
  fmi3TerminateTYPE *terminate;
  /* Co-Simulation group. */
  fmi3InstantiateCoSimulationTYPE *instantiate_co_simulation;
  fmi3DoStepTYPE *do_step;
  fmi3EnterStepModeTYPE *enter_step_mode;
  fmi3EnterEventModeTYPE *enter_event_mode;
  fmi3UpdateDiscreteStatesTYPE *update_discrete_states;
  /* Model Exchange group. */
  fmi3InstantiateModelExchangeTYPE *instantiate_model_exchange;
  fmi3SetTimeTYPE *set_time;
  fmi3SetContinuousStatesTYPE *set_continuous_states;
  fmi3GetContinuousStatesTYPE *get_continuous_states;
  fmi3GetContinuousStateDerivativesTYPE *get_continuous_state_derivatives;
  fmi3GetEventIndicatorsTYPE *get_event_indicators;
  fmi3GetNominalsOfContinuousStatesTYPE *get_nominals_of_continuous_states;
  fmi3EnterContinuousTimeModeTYPE *enter_continuous_time_mode;
  fmi3CompletedIntegratorStepTYPE *completed_integrator_step;
  /* Per-type value access; each group resolves together. */
  fmi3GetFloat32TYPE *get_float32;
  fmi3SetFloat32TYPE *set_float32;
  fmi3GetFloat64TYPE *get_float64;
  fmi3SetFloat64TYPE *set_float64;
  fmi3GetInt8TYPE *get_int8;
  fmi3SetInt8TYPE *set_int8;
  fmi3GetUInt8TYPE *get_uint8;
  fmi3SetUInt8TYPE *set_uint8;
  fmi3GetInt16TYPE *get_int16;
  fmi3SetInt16TYPE *set_int16;
  fmi3GetUInt16TYPE *get_uint16;
  fmi3SetUInt16TYPE *set_uint16;
  fmi3GetInt32TYPE *get_int32;
  fmi3SetInt32TYPE *set_int32;
  fmi3GetUInt32TYPE *get_uint32;
  fmi3SetUInt32TYPE *set_uint32;
  fmi3GetInt64TYPE *get_int64;
  fmi3SetInt64TYPE *set_int64;
  fmi3GetUInt64TYPE *get_uint64;
  fmi3SetUInt64TYPE *set_uint64;
  fmi3GetBooleanTYPE *get_boolean;
  fmi3SetBooleanTYPE *set_boolean;
  fmi3GetStringTYPE *get_string;
  fmi3SetStringTYPE *set_string;
  fmi3GetBinaryTYPE *get_binary;
  fmi3SetBinaryTYPE *set_binary;
  fmi3GetClockTYPE *get_clock;
  fmi3SetClockTYPE *set_clock;
  /* Optional FMU state group. */
  fmi3GetFMUStateTYPE *get_fmu_state;
  fmi3SetFMUStateTYPE *set_fmu_state;
  fmi3FreeFMUStateTYPE *free_fmu_state;
  int32_t has_co_simulation;
  int32_t has_model_exchange;
  int32_t has_float32;
  int32_t has_float64;
  int32_t has_int8;
  int32_t has_uint8;
  int32_t has_int16;
  int32_t has_uint16;
  int32_t has_int32;
  int32_t has_uint32;
  int32_t has_int64;
  int32_t has_uint64;
  int32_t has_boolean;
  int32_t has_string;
  int32_t has_binary;
  int32_t has_clock;
  int32_t has_fmu_state;
  /* Retired instances keep their context alive until the library is
     released, so a callback from a buggy FMU cannot touch freed memory. */
  moonfmi_fmi3_instance *retired;
} moonfmi_fmi3_library;

struct moonfmi_fmi3_instance {
  moonfmi_fmi3_library *library;
  fmi3Instance component;
  char *instance_name;
  char *resource_path;
  void *log_closure;
  moonfmi_fmi3_log_thunk log_thunk;
  uint64_t log_count;
  uint64_t intermediate_updates;
  int32_t logging_enabled;
  int32_t freed;
  moonfmi_fmi3_instance *next_retired;
};

static void *moonfmi_fmi3_resolve(void *handle, const char *name) {
#ifdef _WIN32
  return (void *)GetProcAddress((HMODULE)handle, name);
#else
  return dlsym(handle, name);
#endif
}

static int moonfmi_fmi3_resolve_into(void *handle,
                                     const char *name,
                                     void **slot) {
  void *address = moonfmi_fmi3_resolve(handle, name);
  if (address == NULL) {
    moonfmi_fmi3_set_error("the shared library does not export %s", name);
    return 0;
  }
  *slot = address;
  return 1;
}

/* Resolves a get/set pair; returns 1 only when both symbols exist. */
static int moonfmi_fmi3_resolve_pair(void *handle,
                                     const char *get_name,
                                     void *get_slot,
                                     const char *set_name,
                                     void *set_slot) {
  return moonfmi_fmi3_resolve_into(handle, get_name, get_slot) &&
         moonfmi_fmi3_resolve_into(handle, set_name, set_slot);
}

MOONBIT_FFI_EXPORT
void *
moonfmi_fmi3_library_new(void *handle) {
  if (handle == NULL) {
    moonfmi_fmi3_set_error("the dynamic library handle is null");
    return NULL;
  }
  moonfmi_fmi3_library *library =
      (moonfmi_fmi3_library *)calloc(1, sizeof(moonfmi_fmi3_library));
  if (library == NULL) {
    moonfmi_fmi3_set_error("out of memory while creating the FMI 3 library");
    return NULL;
  }
  library->handle = handle;
  if (!moonfmi_fmi3_resolve_into(handle, "fmi3GetVersion",
                                 (void *)&library->get_version) ||
      !moonfmi_fmi3_resolve_into(handle, "fmi3FreeInstance",
                                 (void *)&library->free_instance) ||
      !moonfmi_fmi3_resolve_into(handle, "fmi3EnterInitializationMode",
                                 (void *)&library->enter_initialization_mode) ||
      !moonfmi_fmi3_resolve_into(handle, "fmi3ExitInitializationMode",
                                 (void *)&library->exit_initialization_mode) ||
      !moonfmi_fmi3_resolve_into(handle, "fmi3Terminate",
                                 (void *)&library->terminate)) {
    free(library);
    return NULL;
  }
  /* Interface groups: each resolves as a unit. */
  library->has_co_simulation =
      moonfmi_fmi3_resolve_into(handle, "fmi3InstantiateCoSimulation",
                                (void *)&library->instantiate_co_simulation) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3DoStep",
                                (void *)&library->do_step) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3EnterStepMode",
                                (void *)&library->enter_step_mode) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3EnterEventMode",
                                (void *)&library->enter_event_mode) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3UpdateDiscreteStates",
                                (void *)&library->update_discrete_states);
  library->has_model_exchange =
      moonfmi_fmi3_resolve_into(handle, "fmi3InstantiateModelExchange",
                                (void *)&library->instantiate_model_exchange) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3SetTime",
                                (void *)&library->set_time) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3SetContinuousStates",
                                (void *)&library->set_continuous_states) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3GetContinuousStates",
                                (void *)&library->get_continuous_states) &&
      moonfmi_fmi3_resolve_into(
          handle, "fmi3GetContinuousStateDerivatives",
          (void *)&library->get_continuous_state_derivatives) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3GetEventIndicators",
                                (void *)&library->get_event_indicators) &&
      moonfmi_fmi3_resolve_into(
          handle, "fmi3GetNominalsOfContinuousStates",
          (void *)&library->get_nominals_of_continuous_states) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3EnterContinuousTimeMode",
                                (void *)&library->enter_continuous_time_mode) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3CompletedIntegratorStep",
                                (void *)&library->completed_integrator_step);
  if (!library->has_co_simulation && !library->has_model_exchange) {
    moonfmi_fmi3_set_error(
        "the shared library exports neither fmi3InstantiateCoSimulation nor "
        "fmi3InstantiateModelExchange");
    free(library);
    return NULL;
  }
  /* Value access groups. */
  library->has_float32 =
      moonfmi_fmi3_resolve_pair(handle, "fmi3GetFloat32",
                                (void *)&library->get_float32, "fmi3SetFloat32",
                                (void *)&library->set_float32);
  library->has_float64 =
      moonfmi_fmi3_resolve_pair(handle, "fmi3GetFloat64",
                                (void *)&library->get_float64, "fmi3SetFloat64",
                                (void *)&library->set_float64);
  library->has_int8 = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetInt8", (void *)&library->get_int8, "fmi3SetInt8",
      (void *)&library->set_int8);
  library->has_uint8 = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetUInt8", (void *)&library->get_uint8, "fmi3SetUInt8",
      (void *)&library->set_uint8);
  library->has_int16 = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetInt16", (void *)&library->get_int16, "fmi3SetInt16",
      (void *)&library->set_int16);
  library->has_uint16 = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetUInt16", (void *)&library->get_uint16, "fmi3SetUInt16",
      (void *)&library->set_uint16);
  library->has_int32 = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetInt32", (void *)&library->get_int32, "fmi3SetInt32",
      (void *)&library->set_int32);
  library->has_uint32 = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetUInt32", (void *)&library->get_uint32, "fmi3SetUInt32",
      (void *)&library->set_uint32);
  library->has_int64 = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetInt64", (void *)&library->get_int64, "fmi3SetInt64",
      (void *)&library->set_int64);
  library->has_uint64 = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetUInt64", (void *)&library->get_uint64, "fmi3SetUInt64",
      (void *)&library->set_uint64);
  library->has_boolean = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetBoolean", (void *)&library->get_boolean,
      "fmi3SetBoolean", (void *)&library->set_boolean);
  library->has_string = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetString", (void *)&library->get_string, "fmi3SetString",
      (void *)&library->set_string);
  library->has_binary = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetBinary", (void *)&library->get_binary, "fmi3SetBinary",
      (void *)&library->set_binary);
  library->has_clock = moonfmi_fmi3_resolve_pair(
      handle, "fmi3GetClock", (void *)&library->get_clock, "fmi3SetClock",
      (void *)&library->set_clock);
  library->has_fmu_state =
      moonfmi_fmi3_resolve_into(handle, "fmi3GetFMUState",
                                (void *)&library->get_fmu_state) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3SetFMUState",
                                (void *)&library->set_fmu_state) &&
      moonfmi_fmi3_resolve_into(handle, "fmi3FreeFMUState",
                                (void *)&library->free_fmu_state);
  const char *version = library->get_version();
  if (version == NULL || version[0] != '3') {
    moonfmi_fmi3_set_error(
        "the FMU reports fmi3GetVersion='%s', expected 3.0",
        version == NULL ? "(null)" : version);
    free(library);
    return NULL;
  }
  return library;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonfmi_fmi3_library_version(void *handle) {
  moonfmi_fmi3_library *library = (moonfmi_fmi3_library *)handle;
  if (library == NULL) {
    return moonfmi_fmi3_bytes_from_text("");
  }
  return moonfmi_fmi3_bytes_from_text(library->get_version());
}

/* Capability flag ids, mirrored by the MoonBit side. */
enum {
  moonfmi_fmi3_flag_co_simulation = 0,
  moonfmi_fmi3_flag_model_exchange = 1,
  moonfmi_fmi3_flag_float32 = 2,
  moonfmi_fmi3_flag_float64 = 3,
  moonfmi_fmi3_flag_int8 = 4,
  moonfmi_fmi3_flag_uint8 = 5,
  moonfmi_fmi3_flag_int16 = 6,
  moonfmi_fmi3_flag_uint16 = 7,
  moonfmi_fmi3_flag_int32 = 8,
  moonfmi_fmi3_flag_uint32 = 9,
  moonfmi_fmi3_flag_int64 = 10,
  moonfmi_fmi3_flag_uint64 = 11,
  moonfmi_fmi3_flag_boolean = 12,
  moonfmi_fmi3_flag_string = 13,
  moonfmi_fmi3_flag_binary = 14,
  moonfmi_fmi3_flag_clock = 15,
  moonfmi_fmi3_flag_fmu_state = 16
};

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_library_has_flag(void *handle, int32_t flag) {
  moonfmi_fmi3_library *library = (moonfmi_fmi3_library *)handle;
  if (library == NULL) {
    return 0;
  }
  switch (flag) {
  case moonfmi_fmi3_flag_co_simulation:
    return library->has_co_simulation;
  case moonfmi_fmi3_flag_model_exchange:
    return library->has_model_exchange;
  case moonfmi_fmi3_flag_float32:
    return library->has_float32;
  case moonfmi_fmi3_flag_float64:
    return library->has_float64;
  case moonfmi_fmi3_flag_int8:
    return library->has_int8;
  case moonfmi_fmi3_flag_uint8:
    return library->has_uint8;
  case moonfmi_fmi3_flag_int16:
    return library->has_int16;
  case moonfmi_fmi3_flag_uint16:
    return library->has_uint16;
  case moonfmi_fmi3_flag_int32:
    return library->has_int32;
  case moonfmi_fmi3_flag_uint32:
    return library->has_uint32;
  case moonfmi_fmi3_flag_int64:
    return library->has_int64;
  case moonfmi_fmi3_flag_uint64:
    return library->has_uint64;
  case moonfmi_fmi3_flag_boolean:
    return library->has_boolean;
  case moonfmi_fmi3_flag_string:
    return library->has_string;
  case moonfmi_fmi3_flag_binary:
    return library->has_binary;
  case moonfmi_fmi3_flag_clock:
    return library->has_clock;
  case moonfmi_fmi3_flag_fmu_state:
    return library->has_fmu_state;
  default:
    return 0;
  }
}

MOONBIT_FFI_EXPORT
void
moonfmi_fmi3_library_free(void *handle) {
  moonfmi_fmi3_library *library = (moonfmi_fmi3_library *)handle;
  if (library == NULL) {
    return;
  }
  moonfmi_fmi3_instance *instance = library->retired;
  while (instance != NULL) {
    moonfmi_fmi3_instance *next = instance->next_retired;
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

static void moonfmi_fmi3_log_message(fmi3InstanceEnvironment environment,
                                     fmi3Status status,
                                     fmi3String category,
                                     fmi3String message) {
  moonfmi_fmi3_instance *instance = (moonfmi_fmi3_instance *)environment;
  if (instance == NULL || instance->freed || !instance->logging_enabled ||
      instance->log_thunk == NULL || instance->log_closure == NULL) {
    return;
  }
  instance->log_count++;
  moonbit_bytes_t kind = moonfmi_fmi3_log_bytes(category);
  moonbit_bytes_t text = moonfmi_fmi3_log_bytes(message);
  instance->log_thunk(instance->log_closure, (int32_t)status, kind, text);
  moonbit_decref(kind);
  moonbit_decref(text);
}

/* The host declines every intermediate update: no variable access, no early
   return. This keeps `eventModeUsed = true` instantiations legal without
   exposing the intermediate-update machinery in the MoonBit API. */
static void moonfmi_fmi3_intermediate_update(
    fmi3InstanceEnvironment environment,
    fmi3Float64 intermediateUpdateTime,
    fmi3Boolean intermediateVariableSetRequested,
    fmi3Boolean intermediateVariableGetAllowed,
    fmi3Boolean intermediateStepFinished,
    fmi3Boolean canReturnEarly,
    fmi3Boolean *earlyReturnRequested,
    fmi3Float64 *earlyReturnTime) {
  moonfmi_fmi3_instance *instance = (moonfmi_fmi3_instance *)environment;
  if (instance != NULL) {
    instance->intermediate_updates++;
  }
  (void)intermediateUpdateTime;
  (void)intermediateVariableSetRequested;
  (void)intermediateVariableGetAllowed;
  (void)intermediateStepFinished;
  (void)canReturnEarly;
  (void)earlyReturnTime;
  *earlyReturnRequested = fmi3False;
}

MOONBIT_FFI_EXPORT
void *
moonfmi_fmi3_instance_new(void *library_handle,
                          moonbit_bytes_t instance_name,
                          moonbit_bytes_t instantiation_token,
                          moonbit_bytes_t resource_path,
                          int32_t interface_kind,
                          int32_t logging_on,
                          void *log_closure,
                          moonfmi_fmi3_log_thunk log_thunk) {
  moonfmi_fmi3_library *library = (moonfmi_fmi3_library *)library_handle;
  if (library == NULL) {
    moonfmi_fmi3_set_error("the FMI 3 library has already been released");
    return NULL;
  }
  moonfmi_fmi3_instance *instance =
      (moonfmi_fmi3_instance *)calloc(1, sizeof(moonfmi_fmi3_instance));
  if (instance == NULL) {
    moonfmi_fmi3_set_error("out of memory while creating an FMI 3 instance");
    return NULL;
  }
  instance->library = library;
  instance->log_closure = log_closure;
  instance->log_thunk = log_thunk;
  instance->logging_enabled = logging_on != 0;
  instance->instance_name = moonfmi_fmi3_copy_bytes(instance_name);
  instance->resource_path = moonfmi_fmi3_copy_bytes(resource_path);
  char *token_text = moonfmi_fmi3_copy_bytes(instantiation_token);
  if (instance->instance_name == NULL || instance->resource_path == NULL ||
      token_text == NULL) {
    free(instance->instance_name);
    free(instance->resource_path);
    free(token_text);
    free(instance);
    return NULL;
  }
  if (interface_kind == 0) {
    if (!library->has_co_simulation) {
      moonfmi_fmi3_set_error(
          "the FMU does not export the Co-Simulation functions");
      free(instance->instance_name);
      free(instance->resource_path);
      free(token_text);
      free(instance);
      return NULL;
    }
    instance->component = library->instantiate_co_simulation(
        instance->instance_name, token_text, instance->resource_path,
        fmi3False, logging_on != 0 ? fmi3True : fmi3False,
        /* eventModeUsed = true: the master handles events via
           EnterEventMode/UpdateDiscreteStates/EnterStepMode. */
        fmi3True,
        /* earlyReturnAllowed = false: the host declines intermediate
           updates, so early return is never requested. */
        fmi3False,
        /* requiredIntermediateVariables = none. */
        NULL, 0, instance, moonfmi_fmi3_log_message,
        moonfmi_fmi3_intermediate_update);
  } else {
    if (!library->has_model_exchange) {
      moonfmi_fmi3_set_error(
          "the FMU does not export the Model Exchange functions");
      free(instance->instance_name);
      free(instance->resource_path);
      free(token_text);
      free(instance);
      return NULL;
    }
    instance->component = library->instantiate_model_exchange(
        instance->instance_name, token_text, instance->resource_path,
        fmi3False, logging_on != 0 ? fmi3True : fmi3False, instance,
        moonfmi_fmi3_log_message);
  }
  free(token_text);
  if (instance->component == NULL) {
    moonfmi_fmi3_set_error(
        "fmi3Instantiate returned no component for instance '%s'",
        instance->instance_name);
    free(instance->instance_name);
    free(instance->resource_path);
    free(instance);
    return NULL;
  }
  return instance;
}

MOONBIT_FFI_EXPORT
void
moonfmi_fmi3_instance_free(void *handle) {
  moonfmi_fmi3_instance *instance = (moonfmi_fmi3_instance *)handle;
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
moonfmi_fmi3_instance_log_count(void *handle) {
  moonfmi_fmi3_instance *instance = (moonfmi_fmi3_instance *)handle;
  return instance == NULL ? 0 : instance->log_count;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_instance_is_freed(void *handle) {
  moonfmi_fmi3_instance *instance = (moonfmi_fmi3_instance *)handle;
  return instance == NULL || instance->freed;
}

static moonfmi_fmi3_instance *moonfmi_fmi3_live(void *handle) {
  moonfmi_fmi3_instance *instance = (moonfmi_fmi3_instance *)handle;
  if (instance == NULL || instance->freed || instance->component == NULL) {
    return NULL;
  }
  return instance;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_enter_initialization_mode(void *handle,
                                       int32_t tolerance_defined,
                                       double tolerance,
                                       double start_time,
                                       int32_t stop_time_defined,
                                       double stop_time) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->enter_initialization_mode(
      instance->component, tolerance_defined ? fmi3True : fmi3False, tolerance,
      start_time, stop_time_defined ? fmi3True : fmi3False, stop_time);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_exit_initialization_mode(void *handle) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->exit_initialization_mode(
      instance->component);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_terminate(void *handle) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->terminate(instance->component);
}

/* ------------------------------------------------------------------------- */
/* Co-Simulation                                                             */
/* ------------------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_do_step(void *handle,
                     double current_time,
                     double step_size,
                     int32_t no_set_fmu_state_prior,
                     int32_t *event_handling_needed,
                     int32_t *terminate_simulation,
                     int32_t *early_return,
                     double *last_successful_time) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  fmi3Boolean event_needed = fmi3False;
  fmi3Boolean terminate = fmi3False;
  fmi3Boolean early = fmi3False;
  fmi3Float64 successful_time = 0.0;
  fmi3Status status = instance->library->do_step(
      instance->component, current_time, step_size,
      no_set_fmu_state_prior ? fmi3True : fmi3False, &event_needed, &terminate,
      &early, &successful_time);
  *event_handling_needed = (int32_t)event_needed;
  *terminate_simulation = (int32_t)terminate;
  *early_return = (int32_t)early;
  *last_successful_time = successful_time;
  return (int32_t)status;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_enter_step_mode(void *handle) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->enter_step_mode(instance->component);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_enter_event_mode(void *handle) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->enter_event_mode(instance->component);
}

/* The `UpdateDiscreteStates` outs are flattened like in FMI 2. */
MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_update_discrete_states(
    void *handle,
    int32_t *discrete_states_need_update,
    int32_t *terminate_simulation,
    int32_t *nominals_of_continuous_states_changed,
    int32_t *values_of_continuous_states_changed,
    int32_t *next_event_time_defined,
    double *next_event_time) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  fmi3Boolean need_update = fmi3False;
  fmi3Boolean terminate = fmi3False;
  fmi3Boolean nominals_changed = fmi3False;
  fmi3Boolean states_changed = fmi3False;
  fmi3Boolean time_defined = fmi3False;
  fmi3Float64 event_time = 0.0;
  fmi3Status status = instance->library->update_discrete_states(
      instance->component, &need_update, &terminate, &nominals_changed,
      &states_changed, &time_defined, &event_time);
  *discrete_states_need_update = (int32_t)need_update;
  *terminate_simulation = (int32_t)terminate;
  *nominals_of_continuous_states_changed = (int32_t)nominals_changed;
  *values_of_continuous_states_changed = (int32_t)states_changed;
  *next_event_time_defined = (int32_t)time_defined;
  *next_event_time = event_time;
  return (int32_t)status;
}

/* ------------------------------------------------------------------------- */
/* Model Exchange                                                            */
/* ------------------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_set_time(void *handle, double time) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->set_time(instance->component, time);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_set_continuous_states(void *handle,
                                   const double *states,
                                   int32_t count) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || count < 0) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->set_continuous_states(
      instance->component, (const fmi3Float64 *)states, (size_t)count);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_get_continuous_states(void *handle,
                                   double *states,
                                   int32_t count) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || count < 0) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->get_continuous_states(
      instance->component, (fmi3Float64 *)states, (size_t)count);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_get_continuous_state_derivatives(void *handle,
                                              double *derivatives,
                                              int32_t count) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || count < 0) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->get_continuous_state_derivatives(
      instance->component, (fmi3Float64 *)derivatives, (size_t)count);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_get_event_indicators(void *handle,
                                  double *indicators,
                                  int32_t count) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || count < 0) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->get_event_indicators(
      instance->component, (fmi3Float64 *)indicators, (size_t)count);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_get_nominals_of_continuous_states(void *handle,
                                               double *nominals,
                                               int32_t count) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || count < 0) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->get_nominals_of_continuous_states(
      instance->component, (fmi3Float64 *)nominals, (size_t)count);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_enter_continuous_time_mode(void *handle) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->enter_continuous_time_mode(
      instance->component);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_completed_integrator_step(void *handle,
                                       int32_t no_set_fmu_state_prior,
                                       int32_t *enter_event_mode,
                                       int32_t *terminate_simulation) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  fmi3Boolean enter = fmi3False;
  fmi3Boolean terminate = fmi3False;
  fmi3Status status = instance->library->completed_integrator_step(
      instance->component,
      no_set_fmu_state_prior ? fmi3True : fmi3False, &enter, &terminate);
  *enter_event_mode = (int32_t)enter;
  *terminate_simulation = (int32_t)terminate;
  return (int32_t)status;
}

/* ------------------------------------------------------------------------- */
/* Value access: numeric arrays                                              */
/* ------------------------------------------------------------------------- */

/* One macro per type keeps the get/set exports in sync; each takes the
   value references, the caller's buffer and two counts (references and
   values, which differ for arrays). */
#define MOONFMI_FMI3_VALUE_GROUP(cname, ctype, getter, setter)                \
  MOONBIT_FFI_EXPORT int32_t moonfmi_fmi3_get_##cname(                        \
      void *handle, const uint32_t *references, ctype *values,                \
      int32_t n_references, int32_t n_values) {                               \
    moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);              \
    if (instance == NULL || n_references < 0 || n_values < 0) {               \
      return (int32_t)fmi3Error;                                              \
    }                                                                         \
    return (int32_t)instance->library->getter(                                \
        instance->component, (const fmi3ValueReference *)references,          \
        (size_t)n_references, (ctype *)values, (size_t)n_values);             \
  }                                                                           \
  MOONBIT_FFI_EXPORT int32_t moonfmi_fmi3_set_##cname(                        \
      void *handle, const uint32_t *references, const ctype *values,          \
      int32_t n_references, int32_t n_values) {                               \
    moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);              \
    if (instance == NULL || n_references < 0 || n_values < 0) {               \
      return (int32_t)fmi3Error;                                              \
    }                                                                         \
    return (int32_t)instance->library->setter(                                \
        instance->component, (const fmi3ValueReference *)references,          \
        (size_t)n_references, (const ctype *)values, (size_t)n_values);       \
  }

MOONFMI_FMI3_VALUE_GROUP(float64, double, get_float64, set_float64)
MOONFMI_FMI3_VALUE_GROUP(int32, int32_t, get_int32, set_int32)
MOONFMI_FMI3_VALUE_GROUP(uint32, uint32_t, get_uint32, set_uint32)
MOONFMI_FMI3_VALUE_GROUP(int64, int64_t, get_int64, set_int64)
MOONFMI_FMI3_VALUE_GROUP(uint64, uint64_t, get_uint64, set_uint64)
/* fmi3Boolean is a 1-byte bool; the MoonBit side passes a Byte buffer. */
MOONFMI_FMI3_VALUE_GROUP(boolean, uint8_t, get_boolean, set_boolean)

/* Float32/Int8/UInt8/Int16/UInt16 have no MoonBit counterparts, so the shim
   converts them: Float32 widens to double (exact), the small integers
   widen to Int32 (sign-extended where signed) and narrow back on set. */

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_get_float32_as_double(void *handle,
                                   const uint32_t *references,
                                   double *values,
                                   int32_t n_references,
                                   int32_t n_values) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || n_references < 0 || n_values < 0) {
    return (int32_t)fmi3Error;
  }
  float narrow[64];
  int32_t status = (int32_t)fmi3Error;
  int32_t done = 0;
  while (done < n_values) {
    int32_t batch = n_values - done > 64 ? 64 : n_values - done;
    status = (int32_t)instance->library->get_float32(
        instance->component, (const fmi3ValueReference *)references,
        (size_t)n_references, narrow, (size_t)batch);
    if (status != (int32_t)fmi3OK) {
      return status;
    }
    for (int32_t i = 0; i < batch; i++) {
      values[done + i] = (double)narrow[i];
    }
    done += batch;
  }
  return status;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_set_float32_from_double(void *handle,
                                     const uint32_t *references,
                                     const double *values,
                                     int32_t n_references,
                                     int32_t n_values) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || n_references < 0 || n_values < 0) {
    return (int32_t)fmi3Error;
  }
  float narrow[64];
  int32_t done = 0;
  while (done < n_values) {
    int32_t batch = n_values - done > 64 ? 64 : n_values - done;
    for (int32_t i = 0; i < batch; i++) {
      narrow[i] = (float)values[done + i];
    }
    fmi3Status status = instance->library->set_float32(
        instance->component, (const fmi3ValueReference *)references,
        (size_t)n_references, narrow, (size_t)batch);
    if (status != fmi3OK) {
      return (int32_t)status;
    }
    done += batch;
  }
  return (int32_t)fmi3OK;
}

/* One macro for the small integer groups: widen to Int32 on get, narrow
   on set (two's complement makes the cast exact for in-range values). */
#define MOONFMI_FMI3_INT_NARROW_GROUP(cname, ctype, getter, setter)           \
  MOONBIT_FFI_EXPORT int32_t moonfmi_fmi3_get_##cname##_as_int32(             \
      void *handle, const uint32_t *references, int32_t *values,              \
      int32_t n_references, int32_t n_values) {                               \
    moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);              \
    if (instance == NULL || n_references < 0 || n_values < 0) {               \
      return (int32_t)fmi3Error;                                              \
    }                                                                         \
    ctype narrow[64];                                                         \
    int32_t status = (int32_t)fmi3Error;                                      \
    int32_t done = 0;                                                         \
    while (done < n_values) {                                                 \
      int32_t batch = n_values - done > 64 ? 64 : n_values - done;            \
      status = (int32_t)instance->library->getter(                            \
          instance->component, (const fmi3ValueReference *)references,        \
          (size_t)n_references, narrow, (size_t)batch);                       \
      if (status != (int32_t)fmi3OK) {                                        \
        return status;                                                        \
      }                                                                       \
      for (int32_t i = 0; i < batch; i++) {                                   \
        values[done + i] = (int32_t)narrow[i];                                \
      }                                                                       \
      done += batch;                                                          \
    }                                                                         \
    return status;                                                            \
  }                                                                           \
  MOONBIT_FFI_EXPORT int32_t moonfmi_fmi3_set_##cname##_from_int32(           \
      void *handle, const uint32_t *references, const int32_t *values,        \
      int32_t n_references, int32_t n_values) {                               \
    moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);              \
    if (instance == NULL || n_references < 0 || n_values < 0) {               \
      return (int32_t)fmi3Error;                                              \
    }                                                                         \
    ctype narrow[64];                                                         \
    int32_t done = 0;                                                         \
    while (done < n_values) {                                                 \
      int32_t batch = n_values - done > 64 ? 64 : n_values - done;            \
      for (int32_t i = 0; i < batch; i++) {                                   \
        narrow[i] = (ctype)values[done + i];                                  \
      }                                                                       \
      fmi3Status status = instance->library->setter(                          \
          instance->component, (const fmi3ValueReference *)references,        \
          (size_t)n_references, narrow, (size_t)batch);                       \
      if (status != fmi3OK) {                                                 \
        return (int32_t)status;                                               \
      }                                                                       \
      done += batch;                                                          \
    }                                                                         \
    return (int32_t)fmi3OK;                                                   \
  }

MOONFMI_FMI3_INT_NARROW_GROUP(int8, int8_t, get_int8, set_int8)
MOONFMI_FMI3_INT_NARROW_GROUP(uint8, uint8_t, get_uint8, set_uint8)
MOONFMI_FMI3_INT_NARROW_GROUP(int16, int16_t, get_int16, set_int16)
MOONFMI_FMI3_INT_NARROW_GROUP(uint16, uint16_t, get_uint16, set_uint16)

/* Clocks have no nValues parameter. */
MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_get_clock(void *handle,
                       const uint32_t *references,
                       uint8_t *values,
                       int32_t n_references) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || n_references < 0) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->get_clock(
      instance->component, (const fmi3ValueReference *)references,
      (size_t)n_references, (fmi3Clock *)values);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_set_clock(void *handle,
                       const uint32_t *references,
                       const uint8_t *values,
                       int32_t n_references) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL || n_references < 0) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->set_clock(
      instance->component, (const fmi3ValueReference *)references,
      (size_t)n_references, (const fmi3Clock *)values);
}

/* ------------------------------------------------------------------------- */
/* Value access: strings and binaries (single variable)                      */
/* ------------------------------------------------------------------------- */

/* Strings and binaries are exposed one variable at a time: the shim owns
   the NUL-termination and the copy into MoonBit bytes, which keeps the
   MoonBit side free of pointer arrays. Array-of-string variables are a
   documented limitation. */
MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonfmi_fmi3_get_string(void *handle,
                        uint32_t reference,
                        int32_t *status_out) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    *status_out = (int32_t)fmi3Error;
    return moonfmi_fmi3_bytes_from_text("");
  }
  fmi3ValueReference refs[1] = { (fmi3ValueReference)reference };
  fmi3String strings[1] = { NULL };
  fmi3Status status = instance->library->get_string(
      instance->component, refs, 1, strings, 1);
  *status_out = (int32_t)status;
  return moonfmi_fmi3_bytes_from_text(strings[0]);
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_set_string(void *handle,
                        uint32_t reference,
                        moonbit_bytes_t value) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  char *copy = moonfmi_fmi3_copy_bytes(value);
  if (copy == NULL) {
    return (int32_t)fmi3Error;
  }
  fmi3ValueReference refs[1] = { (fmi3ValueReference)reference };
  fmi3String strings[1] = { copy };
  fmi3Status status = instance->library->set_string(
      instance->component, refs, 1, strings, 1);
  free(copy);
  return (int32_t)status;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonfmi_fmi3_get_binary(void *handle,
                        uint32_t reference,
                        int32_t *status_out) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    *status_out = (int32_t)fmi3Error;
    return moonbit_make_bytes(0, 0);
  }
  fmi3ValueReference refs[1] = { (fmi3ValueReference)reference };
  size_t sizes[1] = { 0 };
  fmi3Binary binaries[1] = { NULL };
  fmi3Status status = instance->library->get_binary(
      instance->component, refs, 1, sizes, binaries, 1);
  *status_out = (int32_t)status;
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)sizes[0], 0);
  if (sizes[0] > 0 && binaries[0] != NULL) {
    memcpy(bytes, binaries[0], sizes[0]);
  }
  return bytes;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_set_binary(void *handle,
                        uint32_t reference,
                        moonbit_bytes_t value) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  int32_t length = value == NULL ? 0 : Moonbit_array_length(value);
  fmi3ValueReference refs[1] = { (fmi3ValueReference)reference };
  size_t sizes[1] = { (size_t)length };
  fmi3Binary binaries[1] = { (fmi3Binary)value };
  return (int32_t)instance->library->set_binary(
      instance->component, refs, 1, sizes, binaries, 1);
}

/* ------------------------------------------------------------------------- */
/* FMU state (optional capability)                                           */
/* ------------------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
void *
moonfmi_fmi3_get_fmu_state(void *handle, int32_t *status_out) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    *status_out = (int32_t)fmi3Error;
    return NULL;
  }
  void *state = NULL;
  *status_out = (int32_t)instance->library->get_fmu_state(
      instance->component, &state);
  return state;
}

MOONBIT_FFI_EXPORT
int32_t
moonfmi_fmi3_set_fmu_state(void *handle, void *state) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return (int32_t)fmi3Error;
  }
  return (int32_t)instance->library->set_fmu_state(instance->component, state);
}

MOONBIT_FFI_EXPORT
void
moonfmi_fmi3_free_fmu_state(void *handle, void *state) {
  moonfmi_fmi3_instance *instance = moonfmi_fmi3_live(handle);
  if (instance == NULL) {
    return;
  }
  instance->library->free_fmu_state(instance->component, state);
}
