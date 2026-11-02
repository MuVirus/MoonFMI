/*
 * Minimal FMI 2.0.4 Co-Simulation reference host.
 *
 * This is deliberately not part of MoonFMI: it is an independent C program
 * that runs the same model as the MoonBit backend, so the two results can be
 * compared. It uses nothing but the official headers and the platform loader.
 *
 * Usage: fmi2_host <path-to-fmu-binary> <resources-uri>
 *
 * The BouncingBall model is simulated from t=0 to t=3 with a fixed 10 ms step.
 * Height and velocity are sampled every 0.5 s and printed as JSON so the
 * reference covers the trajectory, not just the final state.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../docs/standards/headers/fmi2/fmi2Functions.h"

#ifdef _WIN32
#include <windows.h>
static void *open_library(const char *path) {
  int length = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
  if (length <= 0) {
    return NULL;
  }
  wchar_t *wide = (wchar_t *)malloc((size_t)length * sizeof(wchar_t));
  if (wide == NULL) {
    return NULL;
  }
  MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, length);
  HMODULE handle = LoadLibraryExW(wide, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
  free(wide);
  return (void *)handle;
}
static void close_library(void *handle) { FreeLibrary((HMODULE)handle); }
static void *library_symbol(void *handle, const char *name) {
  return (void *)GetProcAddress((HMODULE)handle, name);
}
#else
#include <dlfcn.h>
static void *open_library(const char *path) {
  return dlopen(path, RTLD_NOW | RTLD_LOCAL);
}
static void close_library(void *handle) { dlclose(handle); }
static void *library_symbol(void *handle, const char *name) {
  return dlsym(handle, name);
}
#endif

static void host_logger(fmi2ComponentEnvironment environment,
                        fmi2String instance_name,
                        fmi2Status status,
                        fmi2String category,
                        fmi2String message,
                        ...) {
  (void)environment;
  fprintf(stderr, "[%s] %s: %s\n", instance_name, category, message);
}

static int load_symbol(void *handle, const char *name, void **slot) {
  void *address = library_symbol(handle, name);
  if (address == NULL) {
    fprintf(stderr, "missing symbol: %s\n", name);
    return 0;
  }
  *slot = address;
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <fmu-binary> <resources-directory>\n", argv[0]);
    return 2;
  }
  const char *GUID = "{1AE5E10D-9521-4DE3-80B9-D0EAAA7D5AF1}";
  const double step_size = 0.01;
  const double stop_time = 3.0;
  const int steps = 300;

  void *handle = open_library(argv[1]);
  if (handle == NULL) {
    fprintf(stderr, "could not load %s\n", argv[1]);
    return 1;
  }

  fmi2GetTypesPlatformTYPE *get_types_platform = NULL;
  fmi2InstantiateTYPE *instantiate = NULL;
  fmi2FreeInstanceTYPE *free_instance = NULL;
  fmi2SetupExperimentTYPE *setup_experiment = NULL;
  fmi2EnterInitializationModeTYPE *enter_initialization_mode = NULL;
  fmi2ExitInitializationModeTYPE *exit_initialization_mode = NULL;
  fmi2TerminateTYPE *terminate = NULL;
  fmi2DoStepTYPE *do_step = NULL;
  fmi2GetRealTYPE *get_real = NULL;

  if (!load_symbol(handle, "fmi2GetTypesPlatform", (void *)&get_types_platform) ||
      !load_symbol(handle, "fmi2Instantiate", (void *)&instantiate) ||
      !load_symbol(handle, "fmi2FreeInstance", (void *)&free_instance) ||
      !load_symbol(handle, "fmi2SetupExperiment", (void *)&setup_experiment) ||
      !load_symbol(handle, "fmi2EnterInitializationMode",
                   (void *)&enter_initialization_mode) ||
      !load_symbol(handle, "fmi2ExitInitializationMode",
                   (void *)&exit_initialization_mode) ||
      !load_symbol(handle, "fmi2Terminate", (void *)&terminate) ||
      !load_symbol(handle, "fmi2DoStep", (void *)&do_step) ||
      !load_symbol(handle, "fmi2GetReal", (void *)&get_real)) {
    close_library(handle);
    return 1;
  }

  if (strcmp(get_types_platform(), "default") != 0) {
    fprintf(stderr, "unsupported type platform: %s\n", get_types_platform());
    close_library(handle);
    return 1;
  }

  fmi2CallbackFunctions callbacks = {
      host_logger, calloc, free, NULL, NULL,
  };
  fmi2Component component = instantiate("bouncingball", fmi2CoSimulation, GUID,
                                        argv[2], &callbacks, fmi2False, fmi2True);
  if (component == NULL) {
    fprintf(stderr, "fmi2Instantiate failed\n");
    close_library(handle);
    return 1;
  }

  fmi2Status status = setup_experiment(component, fmi2False, 0.0, 0.0, fmi2True,
                                       stop_time);
  if (status != fmi2OK) {
    fprintf(stderr, "fmi2SetupExperiment returned %d\n", (int)status);
    free_instance(component);
    close_library(handle);
    return 1;
  }
  if (enter_initialization_mode(component) != fmi2OK ||
      exit_initialization_mode(component) != fmi2OK) {
    fprintf(stderr, "initialization failed\n");
    free_instance(component);
    close_library(handle);
    return 1;
  }

  double time = 0.0;
  int sample = 0;
  printf("{\"samples\": [");
  for (int step = 0; step < steps; step++) {
    status = do_step(component, time, step_size, fmi2True);
    if (status != fmi2OK && status != fmi2Warning) {
      fprintf(stderr, "fmi2DoStep returned %d at t=%f\n", (int)status, time);
      free_instance(component);
      close_library(handle);
      return 1;
    }
    time += step_size;
    if ((step + 1) % 50 == 0) {
      const fmi2ValueReference references[2] = {1, 3};
      double values[2] = {0.0, 0.0};
      status = get_real(component, references, 2, values);
      if (status != fmi2OK && status != fmi2Warning) {
        fprintf(stderr, "fmi2GetReal returned %d\n", (int)status);
        free_instance(component);
        close_library(handle);
        return 1;
      }
      printf("%s\n    [%.17g, %.17g, %.17g]", sample == 0 ? "" : ",", time,
             values[0], values[1]);
      sample++;
    }
  }
  printf("\n  ]}\n");

  terminate(component);
  free_instance(component);
  close_library(handle);
  return 0;
}
