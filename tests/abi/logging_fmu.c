/*
 * A fake FMI 2.0.4 Co-Simulation FMU used to exercise the log path.
 *
 * It is not a real model: every `fmi2DoStep` emits `count` log messages of the
 * configured `kind`, so the tests can drive long, wide and non-ASCII messages
 * deterministically. Value reference 0 sets the count, value reference 1 sets
 * the kind.
 *
 * Kinds:
 *   0  short "step N" message
 *   1  8192 ASCII bytes (must be truncated to 4096)
 *   2  Chinese and emoji text (must survive unchanged)
 *   3  4094 ASCII bytes followed by a 3-byte character (cut inside it)
 *   4  4093 ASCII bytes followed by a 4-byte character (cut inside it)
 *   5  exactly 4096 ASCII bytes (must not be truncated)
 *   6  one message from a second thread
 *
 * Build it with tests/abi/build-fixture.ps1 or build-fixture.sh.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../docs/standards/headers/fmi2/fmi2Functions.h"

#ifdef _WIN32
#define MOONFMI_EXPORT __declspec(dllexport)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#define MOONFMI_EXPORT __attribute__((visibility("default")))
#include <pthread.h>
#endif

typedef struct moonfmi_fake_fmu {
  fmi2CallbackFunctions callbacks;
  fmi2Boolean logging_on;
  double time;
  int count;
  int kind;
  int step;
} moonfmi_fake_fmu;

static void emit(moonfmi_fake_fmu *fmu,
                 fmi2Status status,
                 const char *category,
                 const char *message) {
  if (fmu == NULL || !fmu->logging_on || fmu->callbacks.logger == NULL) {
    return;
  }
  fmu->callbacks.logger(fmu->callbacks.componentEnvironment, "fake", status,
                        category, message);
}

#ifdef _WIN32
static DWORD WINAPI emit_from_thread_body(LPVOID argument) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)argument;
  emit(fmu, fmi2OK, "thread", "from the FMU thread");
  return 0;
}
static void emit_from_thread(moonfmi_fake_fmu *fmu) {
  HANDLE thread =
      CreateThread(NULL, 0, emit_from_thread_body, fmu, 0, NULL);
  if (thread != NULL) {
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
  }
}
#else
static void *emit_from_thread_body(void *argument) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)argument;
  emit(fmu, fmi2OK, "thread", "from the FMU thread");
  return NULL;
}
static void emit_from_thread(moonfmi_fake_fmu *fmu) {
  pthread_t thread;
  if (pthread_create(&thread, NULL, emit_from_thread_body, fmu) == 0) {
    pthread_join(thread, NULL);
  }
}
#endif

static void emit_kind(moonfmi_fake_fmu *fmu, int kind, int step) {
  char short_message[64];
  switch (kind) {
    case 1: {
      char *message = (char *)malloc(8193);
      if (message == NULL) {
        return;
      }
      memset(message, 'a', 8192);
      message[8192] = '\0';
      emit(fmu, fmi2OK, "long", message);
      free(message);
      break;
    }
    case 2:
      emit(fmu, fmi2OK, "unicode", "中文🙂 你好，世界 — Ünïcode");
      break;
    case 3: {
      char message[4094 + 4] = {0};
      memset(message, 'a', 4094);
      memcpy(message + 4094, "\xE4\xB8\xAD", 3); /* 中 */
      emit(fmu, fmi2OK, "boundary3", message);
      break;
    }
    case 4: {
      char message[4093 + 5] = {0};
      memset(message, 'a', 4093);
      memcpy(message + 4093, "\xF0\x9F\x99\x82", 4); /* 🙂 */
      emit(fmu, fmi2OK, "boundary4", message);
      break;
    }
    case 5: {
      char *message = (char *)malloc(4097);
      if (message == NULL) {
        return;
      }
      memset(message, 'b', 4096);
      message[4096] = '\0';
      emit(fmu, fmi2OK, "exact", message);
      free(message);
      break;
    }
    case 6:
      emit_from_thread(fmu);
      break;
    default:
      snprintf(short_message, sizeof(short_message), "step %d", step);
      emit(fmu, fmi2OK, "step", short_message);
      break;
  }
}

MOONFMI_EXPORT
const char *fmi2GetTypesPlatform(void) { return fmi2TypesPlatform; }

MOONFMI_EXPORT
const char *fmi2GetVersion(void) { return "2.0"; }

MOONFMI_EXPORT
fmi2Status fmi2SetDebugLogging(fmi2Component component,
                               fmi2Boolean loggingOn,
                               size_t categoriesCount,
                               const fmi2String categories[]) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  (void)categoriesCount;
  (void)categories;
  if (fmu == NULL) {
    return fmi2Error;
  }
  fmu->logging_on = loggingOn;
  return fmi2OK;
}

MOONFMI_EXPORT
fmi2Component fmi2Instantiate(fmi2String instanceName,
                              fmi2Type fmuType,
                              fmi2String fmuGUID,
                              fmi2String fmuResourceLocation,
                              const fmi2CallbackFunctions *functions,
                              fmi2Boolean visible,
                              fmi2Boolean loggingOn) {
  (void)fmuType;
  (void)fmuGUID;
  (void)fmuResourceLocation;
  (void)visible;
  if (functions == NULL) {
    return NULL;
  }
  moonfmi_fake_fmu *fmu =
      (moonfmi_fake_fmu *)calloc(1, sizeof(moonfmi_fake_fmu));
  if (fmu == NULL) {
    return NULL;
  }
  fmu->callbacks = *functions;
  fmu->logging_on = loggingOn;
  fmu->count = 1;
  fmu->kind = 0;
  emit(fmu, fmi2OK, "init", "instantiated");
  return (fmi2Component)fmu;
}

MOONFMI_EXPORT
void fmi2FreeInstance(fmi2Component component) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  if (fmu == NULL) {
    return;
  }
  /* Logging after the host asked for release must not reach user code. */
  emit(fmu, fmi2OK, "free", "freeing the instance");
  free(fmu);
}

MOONFMI_EXPORT
fmi2Status fmi2SetupExperiment(fmi2Component component,
                               fmi2Boolean toleranceDefined,
                               fmi2Real tolerance,
                               fmi2Real startTime,
                               fmi2Boolean stopTimeDefined,
                               fmi2Real stopTime) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  (void)toleranceDefined;
  (void)tolerance;
  (void)stopTimeDefined;
  (void)stopTime;
  if (fmu == NULL) {
    return fmi2Error;
  }
  fmu->time = startTime;
  return fmi2OK;
}

MOONFMI_EXPORT
fmi2Status fmi2EnterInitializationMode(fmi2Component component) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  return fmu == NULL ? fmi2Error : fmi2OK;
}

MOONFMI_EXPORT
fmi2Status fmi2ExitInitializationMode(fmi2Component component) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  if (fmu == NULL) {
    return fmi2Error;
  }
  emit(fmu, fmi2OK, "init", "initialized");
  return fmi2OK;
}

MOONFMI_EXPORT
fmi2Status fmi2Terminate(fmi2Component component) {
  return component == NULL ? fmi2Error : fmi2OK;
}

MOONFMI_EXPORT
fmi2Status fmi2Reset(fmi2Component component) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  if (fmu == NULL) {
    return fmi2Error;
  }
  fmu->count = 1;
  fmu->kind = 0;
  fmu->step = 0;
  fmu->time = 0.0;
  return fmi2OK;
}

MOONFMI_EXPORT
fmi2Status fmi2DoStep(fmi2Component component,
                      fmi2Real currentCommunicationPoint,
                      fmi2Real communicationStepSize,
                      fmi2Boolean noSetFMUStatePriorToCurrentPoint) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  (void)noSetFMUStatePriorToCurrentPoint;
  if (fmu == NULL) {
    return fmi2Error;
  }
  fmu->time = currentCommunicationPoint + communicationStepSize;
  fmu->step++;
  for (int index = 0; index < fmu->count; index++) {
    emit_kind(fmu, fmu->kind, fmu->step);
  }
  return fmi2OK;
}

MOONFMI_EXPORT
fmi2Status fmi2GetReal(fmi2Component component,
                       const fmi2ValueReference valueReferences[],
                       size_t numberOfValueReferences,
                       fmi2Real values[]) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  if (fmu == NULL) {
    return fmi2Error;
  }
  for (size_t index = 0; index < numberOfValueReferences; index++) {
    switch (valueReferences[index]) {
      case 0:
        values[index] = (fmi2Real)fmu->count;
        break;
      case 1:
        values[index] = (fmi2Real)fmu->kind;
        break;
      case 2:
        values[index] = fmu->time;
        break;
      default:
        values[index] = 0.0;
        break;
    }
  }
  return fmi2OK;
}

MOONFMI_EXPORT
fmi2Status fmi2SetReal(fmi2Component component,
                       const fmi2ValueReference valueReferences[],
                       size_t numberOfValueReferences,
                       const fmi2Real values[]) {
  moonfmi_fake_fmu *fmu = (moonfmi_fake_fmu *)component;
  if (fmu == NULL) {
    return fmi2Error;
  }
  for (size_t index = 0; index < numberOfValueReferences; index++) {
    switch (valueReferences[index]) {
      case 0:
        fmu->count = (int)values[index];
        if (fmu->count < 0) {
          fmu->count = 0;
        }
        if (fmu->count > 100000) {
          fmu->count = 100000;
        }
        break;
      case 1:
        fmu->kind = (int)values[index];
        break;
      default:
        break;
    }
  }
  return fmi2OK;
}

MOONFMI_EXPORT
fmi2Status fmi2GetStatus(fmi2Component component,
                         const fmi2StatusKind statusKind,
                         fmi2Status *value) {
  (void)component;
  (void)statusKind;
  (void)value;
  return fmi2Error;
}

MOONFMI_EXPORT
fmi2Status fmi2GetDirectionalDerivative(
    fmi2Component component,
    const fmi2ValueReference unknownValueReferences[],
    size_t numberOfUnknowns,
    const fmi2ValueReference knownValueReferences[],
    size_t numberOfKnowns,
    const fmi2Real seeds[],
    fmi2Real sensitivities[]) {
  (void)component;
  (void)unknownValueReferences;
  (void)numberOfUnknowns;
  (void)knownValueReferences;
  (void)numberOfKnowns;
  (void)seeds;
  (void)sensitivities;
  return fmi2Error;
}
