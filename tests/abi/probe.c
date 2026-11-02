/*
 * ABI baseline probe.
 *
 * Prints the sizes, offsets and enum values that the FMI 2 and FMI 3 headers
 * actually produce on this platform. The output is compared with a checked-in
 * baseline so a compiler, header or platform change that silently shifts a
 * field is caught by CI.
 *
 * The official headers are used as-is from `docs/standards/headers`; this file
 * never restates a struct definition.
 *
 * Usage: probe            print JSON to stdout
 *        probe --header   print the baseline file name for this platform
 */

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../../docs/standards/headers/fmi2/fmi2Functions.h"
#include "../../docs/standards/headers/fmi3/fmi3Functions.h"

static int first = 1;

static void begin_entry(void) {
  printf("%s\n      ", first ? "" : ",");
  first = 0;
}

static void size_entry(const char *name, size_t value) {
  begin_entry();
  printf("\"%s\": %zu", name, value);
}

static void offset_entry(const char *name, size_t value) { size_entry(name, value); }

static void int_entry(const char *name, long value) {
  begin_entry();
  printf("\"%s\": %ld", name, value);
}

static void section(const char *name) {
  printf("\n    \"%s\": {", name);
  first = 1;
}

static void end_section(void) { printf("\n    }"); }

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--header") == 0) {
    const char *os =
#if defined(_WIN32)
        "windows";
#elif defined(__APPLE__)
        "darwin";
#else
        "linux";
#endif
    const char *arch =
#if defined(__x86_64__) || defined(_M_X64)
        "x86_64";
#elif defined(__aarch64__) || defined(_M_ARM64)
        "aarch64";
#else
        "unknown";
#endif
    printf("%s-%s.json\n", arch, os);
    return 0;
  }

  printf("{");

  printf("\n  \"fmi2\": {");
  section("sizeof");
  size_entry("fmi2Real", sizeof(fmi2Real));
  size_entry("fmi2Integer", sizeof(fmi2Integer));
  size_entry("fmi2Boolean", sizeof(fmi2Boolean));
  size_entry("fmi2Char", sizeof(fmi2Char));
  size_entry("fmi2Byte", sizeof(fmi2Byte));
  size_entry("fmi2String", sizeof(fmi2String));
  size_entry("fmi2ValueReference", sizeof(fmi2ValueReference));
  size_entry("fmi2Component", sizeof(fmi2Component));
  size_entry("fmi2ComponentEnvironment", sizeof(fmi2ComponentEnvironment));
  size_entry("fmi2FMUstate", sizeof(fmi2FMUstate));
  size_entry("fmi2Status", sizeof(fmi2Status));
  size_entry("fmi2CallbackFunctions", sizeof(fmi2CallbackFunctions));
  size_entry("fmi2CallbackLogger", sizeof(fmi2CallbackLogger));
  size_entry("fmi2InstantiateTYPE*", sizeof(fmi2InstantiateTYPE *));
  size_entry("fmi2DoStepTYPE*", sizeof(fmi2DoStepTYPE *));
  size_entry("fmi2GetRealTYPE*", sizeof(fmi2GetRealTYPE *));
  end_section();

  printf(",");
  section("offsetof");
  offset_entry("fmi2CallbackFunctions.logger",
               offsetof(fmi2CallbackFunctions, logger));
  offset_entry("fmi2CallbackFunctions.allocateMemory",
               offsetof(fmi2CallbackFunctions, allocateMemory));
  offset_entry("fmi2CallbackFunctions.freeMemory",
               offsetof(fmi2CallbackFunctions, freeMemory));
  offset_entry("fmi2CallbackFunctions.stepFinished",
               offsetof(fmi2CallbackFunctions, stepFinished));
  offset_entry("fmi2CallbackFunctions.componentEnvironment",
               offsetof(fmi2CallbackFunctions, componentEnvironment));
  end_section();

  printf(",");
  section("enum");
  int_entry("fmi2OK", fmi2OK);
  int_entry("fmi2Warning", fmi2Warning);
  int_entry("fmi2Discard", fmi2Discard);
  int_entry("fmi2Error", fmi2Error);
  int_entry("fmi2Fatal", fmi2Fatal);
  int_entry("fmi2Pending", fmi2Pending);
  int_entry("fmi2DoStepStatus", fmi2DoStepStatus);
  int_entry("fmi2PendingStatus", fmi2PendingStatus);
  int_entry("fmi2LastSuccessfulTime", fmi2LastSuccessfulTime);
  int_entry("fmi2Terminated", fmi2Terminated);
  int_entry("fmi2CoSimulation", fmi2CoSimulation);
  int_entry("fmi2ModelExchange", fmi2ModelExchange);
  int_entry("fmi2True", fmi2True);
  int_entry("fmi2False", fmi2False);
  end_section();
  printf("\n  },");

  printf("\n  \"fmi3\": {");
  section("sizeof");
  size_entry("fmi3Float64", sizeof(fmi3Float64));
  size_entry("fmi3Float32", sizeof(fmi3Float32));
  size_entry("fmi3Int64", sizeof(fmi3Int64));
  size_entry("fmi3UInt64", sizeof(fmi3UInt64));
  size_entry("fmi3Int32", sizeof(fmi3Int32));
  size_entry("fmi3UInt32", sizeof(fmi3UInt32));
  size_entry("fmi3Int16", sizeof(fmi3Int16));
  size_entry("fmi3UInt16", sizeof(fmi3UInt16));
  size_entry("fmi3Int8", sizeof(fmi3Int8));
  size_entry("fmi3UInt8", sizeof(fmi3UInt8));
  size_entry("fmi3Boolean", sizeof(fmi3Boolean));
  size_entry("fmi3Char", sizeof(fmi3Char));
  size_entry("fmi3String", sizeof(fmi3String));
  size_entry("fmi3Binary", sizeof(fmi3Binary));
  size_entry("fmi3Clock", sizeof(fmi3Clock));
  size_entry("fmi3ValueReference", sizeof(fmi3ValueReference));
  size_entry("fmi3Instance", sizeof(fmi3Instance));
  size_entry("fmi3InstanceEnvironment", sizeof(fmi3InstanceEnvironment));
  size_entry("fmi3FMUState", sizeof(fmi3FMUState));
  size_entry("fmi3Status", sizeof(fmi3Status));
  end_section();

  printf(",");
  section("enum");
  int_entry("fmi3OK", fmi3OK);
  int_entry("fmi3Warning", fmi3Warning);
  int_entry("fmi3Discard", fmi3Discard);
  int_entry("fmi3Error", fmi3Error);
  int_entry("fmi3Fatal", fmi3Fatal);
  int_entry("fmi3True", fmi3True);
  int_entry("fmi3False", fmi3False);
  end_section();
  printf("\n  }\n}\n");

  return 0;
}
