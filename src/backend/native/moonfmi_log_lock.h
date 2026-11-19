/*
 * Process-wide lock around log-callback delivery (security review R-04).
 *
 * The MoonBit runtime expects to be driven from one thread, but an FMU may
 * call the logger from several of its own threads. The shim serializes the
 * thunk invocation so concurrent callbacks never interleave inside MoonBit
 * code; delivery stays synchronous (no queue, no extra copying).
 */
#ifndef MOONFMI_LOG_LOCK_H
#define MOONFMI_LOG_LOCK_H

#ifdef _WIN32

static CRITICAL_SECTION moonfmi_log_lock;
/* 0 = uninitialized, 1 = initializing, 2 = ready. */
static volatile LONG moonfmi_log_lock_state = 0;

static void moonfmi_log_lock_acquire(void) {
  if (InterlockedCompareExchange(&moonfmi_log_lock_state, 0, 0) == 0) {
    while (InterlockedCompareExchange(&moonfmi_log_lock_state, 1, 0) != 0) {
      /* Another thread is initializing; spin until it publishes state 2. */
    }
    InitializeCriticalSection(&moonfmi_log_lock);
    InterlockedExchange(&moonfmi_log_lock_state, 2);
  }
  EnterCriticalSection(&moonfmi_log_lock);
}

static void moonfmi_log_lock_release(void) {
  LeaveCriticalSection(&moonfmi_log_lock);
}

#else

#include <pthread.h>

static pthread_mutex_t moonfmi_log_mutex = PTHREAD_MUTEX_INITIALIZER;

static void moonfmi_log_lock_acquire(void) {
  pthread_mutex_lock(&moonfmi_log_mutex);
}

static void moonfmi_log_lock_release(void) {
  pthread_mutex_unlock(&moonfmi_log_mutex);
}

#endif

#endif /* MOONFMI_LOG_LOCK_H */
