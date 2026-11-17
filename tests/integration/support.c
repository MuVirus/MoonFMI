/*
 * Test-only support code for the integration package.
 *
 * The 10,000-message log test needs a memory number that is independent of the
 * code under test. Resident set size alone is misleading, because both the
 * Windows heap and glibc keep freed blocks mapped; trimming first makes the
 * number reflect live allocations instead of peak churn.
 *
 * `moonfmi_test_run_command` lets the source-FMU export tests invoke the
 * external C compiler (roadmap P6 / E-06) without pulling a process module
 * into the test package; the command string is fully built by the caller.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int64_t moonfmi_test_run_command(const char *command) {
  /* Capture the child's output instead of inheriting stdout: the MoonBit
     test harness speaks JSON on its own stdout, and a compiler banner would
     corrupt the protocol stream. */
#ifdef _WIN32
  FILE *pipe = _popen(command, "r");
#else
  FILE *pipe = popen(command, "r");
#endif
  if (pipe == NULL) {
    return -1;
  }
  char buffer[512];
  while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
    /* discard */
  }
#ifdef _WIN32
  return (int64_t)_pclose(pipe);
#else
  return (int64_t)pclose(pipe);
#endif
}

#ifdef _WIN32
#include <malloc.h>
#include <windows.h>
#include <psapi.h>
#pragma comment(lib, "psapi.lib")

void moonfmi_test_trim_memory(void) { _heapmin(); }

int64_t moonfmi_test_resident_bytes(void) {
  PROCESS_MEMORY_COUNTERS counters;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof(counters))) {
    return -1;
  }
  return (int64_t)counters.WorkingSetSize;
}
#else
#include <malloc.h>
#include <stdio.h>
#include <unistd.h>

void moonfmi_test_trim_memory(void) { malloc_trim(0); }

int64_t moonfmi_test_resident_bytes(void) {
  FILE *file = fopen("/proc/self/statm", "r");
  if (file == NULL) {
    return -1;
  }
  long total = 0;
  long resident = 0;
  if (fscanf(file, "%ld %ld", &total, &resident) != 2) {
    fclose(file);
    return -1;
  }
  return (int64_t)resident * (int64_t)sysconf(_SC_PAGESIZE);
}
#endif
