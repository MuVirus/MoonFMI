/* MoonfmiClocks — the self-built test FMU (0.8.2).
 *
 * A deliberately tiny FMI 3 FMU that declares BOTH Co-Simulation and
 * Model Exchange (but no Scheduled Execution, unlike the official
 * Clocks model) and carries input/output clocks, so the CS/ME clock
 * scheduling and the intermediate-update channel get real-FMU evidence:
 *
 * - Int32 counters, each incremented when the host activates the matching
 *   input clock through fmi3ActivateModelPartition (constant / triggered /
 *   countdown); Float64 mirrors of the counters for the Real recorder.
 * - `clock_time` is the one continuous state (der = 1) so the ME master
 *   has a state to integrate; GetEventIndicators is constant (no events).
 * - out_clock pulses on every internal solver step; fmi3GetClock reads
 *   and clears the pulse.
 * - fmi3DoStep advances in fixed internal steps of 0.05 and calls the
 *   intermediate-update callback after each one (getAllowed=true,
 *   stepFinished=true, canReturnEarly=earlyReturnAllowed). When the host
 *   requests an early return through the callback the FMU returns
 *   earlyReturn=true at that update time and counts the request in the
 *   `early_return_requests` variable.
 *
 * The C source is compiled by the integration tests themselves (see
 * tests/integration/clock_fmu_wbtest.mbt); the include path is relative
 * to this file, independent of the compiler's working directory.
 */

#include "../../docs/standards/headers/fmi3/fmi3Functions.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define MOONFMI_CLOCKS_INTERNAL_STEP 0.05
#define MOONFMI_CLOCKS_COUNTDOWN_INTERVAL 0.2
/* The ME master settles the one scheduled event here. */
#define MOONFMI_CLOCKS_EVENT_TIME 0.3

typedef struct MoonfmiClocksInstance MoonfmiClocksInstance;

struct MoonfmiClocksInstance {
  int is_co_simulation;
  fmi3InstanceEnvironment environment;
  fmi3LogMessageCallback log_message;
  fmi3IntermediateUpdateCallback intermediate_update;
  int early_return_allowed;
  double time;
  double state; /* `clock_time`, integrated by the ME master */
  long constant_counter;
  long triggered_counter;
  long countdown_counter;
  long early_return_requests;
  int out_pulse; /* read-and-clear through fmi3GetClock(out_clock) */
  double countdown_armed_at;
  int settled_event; /* the ME master's one scheduled event at 0.3 */
};

static MoonfmiClocksInstance *moonfmi_clocks_instance(fmi3Instance instance) {
  return (MoonfmiClocksInstance *)instance;
}

static int moonfmi_clocks_is_close(double a, double b) {
  return fabs(a - b) <= 1e-9;
}

/* ------------------------------------------------------------------------- */
/* Inquire                                                                   */
/* ------------------------------------------------------------------------- */

const char *fmi3GetVersion(void) {
  return "3.0";
}

const char *fmi3GetTypesPlatform(void) {
  return "default";
}

/* ------------------------------------------------------------------------- */
/* Instantiation                                                             */
/* ------------------------------------------------------------------------- */

static MoonfmiClocksInstance *moonfmi_clocks_create(
    fmi3InstanceEnvironment environment,
    fmi3LogMessageCallback log_message,
    int is_co_simulation,
    int early_return_allowed,
    fmi3IntermediateUpdateCallback intermediate_update) {
  MoonfmiClocksInstance *instance =
      (MoonfmiClocksInstance *)calloc(1, sizeof(MoonfmiClocksInstance));
  if (instance == NULL) {
    return NULL;
  }
  instance->is_co_simulation = is_co_simulation;
  instance->environment = environment;
  instance->log_message = log_message;
  instance->intermediate_update = intermediate_update;
  instance->early_return_allowed = early_return_allowed;
  instance->time = 0.0;
  instance->state = 0.0;
  instance->countdown_armed_at = 0.0;
  return instance;
}

fmi3Instance fmi3InstantiateCoSimulation(
    fmi3String instanceName,
    fmi3String instantiationToken,
    fmi3String resourcePath,
    fmi3Boolean visible,
    fmi3Boolean loggingOn,
    fmi3Boolean eventModeUsed,
    fmi3Boolean earlyReturnAllowed,
    const fmi3ValueReference requiredIntermediateVariables[],
    size_t nRequiredIntermediateVariables,
    fmi3InstanceEnvironment instanceEnvironment,
    fmi3LogMessageCallback logMessage,
    fmi3IntermediateUpdateCallback intermediateUpdate) {
  (void)instanceName;
  (void)instantiationToken;
  (void)resourcePath;
  (void)visible;
  (void)loggingOn;
  (void)requiredIntermediateVariables;
  (void)nRequiredIntermediateVariables;
  /* Unlike Reference-FMUs Roberts this fixture accepts eventModeUsed
     either way — it implements the event-mode calls. */
  return moonfmi_clocks_create(instanceEnvironment, logMessage, 1,
                               earlyReturnAllowed != fmi3False,
                               intermediateUpdate);
}

fmi3Instance fmi3InstantiateModelExchange(
    fmi3String instanceName,
    fmi3String instantiationToken,
    fmi3String resourcePath,
    fmi3Boolean visible,
    fmi3Boolean loggingOn,
    fmi3InstanceEnvironment instanceEnvironment,
    fmi3LogMessageCallback logMessage) {
  (void)instanceName;
  (void)instantiationToken;
  (void)resourcePath;
  (void)visible;
  (void)loggingOn;
  return moonfmi_clocks_create(instanceEnvironment, logMessage, 0, 0, NULL);
}

void fmi3FreeInstance(fmi3Instance instance) {
  free(moonfmi_clocks_instance(instance));
}

fmi3Status fmi3Terminate(fmi3Instance instance) {
  (void)instance;
  return fmi3OK;
}

/* ------------------------------------------------------------------------- */
/* Initialization and modes                                                  */
/* ------------------------------------------------------------------------- */

fmi3Status fmi3EnterInitializationMode(
    fmi3Instance instance,
    fmi3Boolean toleranceDefined,
    fmi3Float64 tolerance,
    fmi3Float64 startTime,
    fmi3Boolean stopTimeDefined,
    fmi3Float64 stopTime) {
  (void)toleranceDefined;
  (void)tolerance;
  (void)stopTimeDefined;
  (void)stopTime;
  moonfmi_clocks_instance(instance)->time = startTime;
  moonfmi_clocks_instance(instance)->state = startTime;
  return fmi3OK;
}

fmi3Status fmi3ExitInitializationMode(fmi3Instance instance) {
  (void)instance;
  return fmi3OK;
}

fmi3Status fmi3EnterEventMode(fmi3Instance instance) {
  (void)instance;
  return fmi3OK;
}

fmi3Status fmi3EnterStepMode(fmi3Instance instance) {
  (void)instance;
  return fmi3OK;
}

fmi3Status fmi3EnterContinuousTimeMode(fmi3Instance instance) {
  (void)instance;
  return fmi3OK;
}

/* ------------------------------------------------------------------------- */
/* Co-Simulation step                                                        */
/* ------------------------------------------------------------------------- */

fmi3Status fmi3DoStep(
    fmi3Instance instance,
    fmi3Float64 currentCommunicationPoint,
    fmi3Float64 communicationStepSize,
    fmi3Boolean noSetFMUStatePriorToCurrentPoint,
    fmi3Boolean *eventHandlingNeeded,
    fmi3Boolean *terminateSimulation,
    fmi3Boolean *earlyReturn,
    fmi3Float64 *lastSuccessfulTime) {
  (void)noSetFMUStatePriorToCurrentPoint;
  MoonfmiClocksInstance *s = moonfmi_clocks_instance(instance);
  *eventHandlingNeeded = fmi3False;
  *terminateSimulation = fmi3False;
  *earlyReturn = fmi3False;
  *lastSuccessfulTime = currentCommunicationPoint;
  double target = currentCommunicationPoint + communicationStepSize;
  while (s->time < target - 1e-9) {
    double next = target - s->time > MOONFMI_CLOCKS_INTERNAL_STEP
                      ? s->time + MOONFMI_CLOCKS_INTERNAL_STEP
                      : target;
    s->time = next;
    s->state = next;
    /* One output-clock pulse per internal solver step; fmi3GetClock
       reads and clears it. */
    s->out_pulse = 1;
    if (s->intermediate_update != NULL) {
      fmi3Boolean host_wants_early = fmi3False;
      fmi3Float64 host_early_time = 0.0;
      s->intermediate_update(
          s->environment, s->time, fmi3False, fmi3True, fmi3True,
          s->early_return_allowed ? fmi3True : fmi3False,
          &host_wants_early, &host_early_time);
      if (host_wants_early != fmi3False) {
        s->early_return_requests++;
        /* Return early at the update's own time. */
        *earlyReturn = fmi3True;
        *lastSuccessfulTime = s->time;
        return fmi3OK;
      }
    }
  }
  return fmi3OK;
}

/* ------------------------------------------------------------------------- */
/* Clocks                                                                    */
/* ------------------------------------------------------------------------- */

fmi3Status fmi3SetClock(fmi3Instance instance,
                        const fmi3ValueReference valueReferences[],
                        size_t nValueReferences,
                        const fmi3Clock values[]) {
  /* Input clocks are driven through fmi3ActivateModelPartition. */
  (void)instance;
  (void)valueReferences;
  (void)nValueReferences;
  (void)values;
  return fmi3OK;
}

fmi3Status fmi3GetClock(fmi3Instance instance,
                        const fmi3ValueReference valueReferences[],
                        size_t nValueReferences,
                        fmi3Clock values[]) {
  MoonfmiClocksInstance *s = moonfmi_clocks_instance(instance);
  for (size_t i = 0; i < nValueReferences; i++) {
    if (valueReferences[i] == 9U) {
      /* Read-and-clear: each true observation consumes one pulse. */
      values[i] = s->out_pulse != 0 ? fmi3True : fmi3False;
      s->out_pulse = 0;
    } else {
      values[i] = fmi3False;
    }
  }
  return fmi3OK;
}

fmi3Status fmi3GetIntervalDecimal(
    fmi3Instance instance,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    fmi3Float64 intervals[],
    fmi3IntervalQualifier qualifiers[]) {
  MoonfmiClocksInstance *s = moonfmi_clocks_instance(instance);
  for (size_t i = 0; i < nValueReferences; i++) {
    if (valueReferences[i] != 8U) {
      return fmi3Error;
    }
    double remaining = MOONFMI_CLOCKS_COUNTDOWN_INTERVAL -
                       (s->time - s->countdown_armed_at);
    if (remaining < 0.0) {
      remaining = 0.0;
    }
    intervals[i] = remaining;
    qualifiers[i] = fmi3IntervalChanged;
  }
  return fmi3OK;
}

fmi3Status fmi3ActivateModelPartition(
    fmi3Instance instance,
    fmi3ValueReference clockReference,
    fmi3Float64 activationTime) {
  MoonfmiClocksInstance *s = moonfmi_clocks_instance(instance);
  switch (clockReference) {
  case 6U:
    s->constant_counter++;
    s->out_pulse = 1;
    break;
  case 7U:
    s->triggered_counter++;
    break;
  case 8U:
    s->countdown_counter++;
    /* Re-arm the countdown from the activation instant. */
    s->countdown_armed_at = activationTime;
    break;
  default:
    return fmi3Error;
  }
  return fmi3OK;
}

/* ------------------------------------------------------------------------- */
/* Variables                                                                 */
/* ------------------------------------------------------------------------- */

static fmi3Status moonfmi_clocks_get_float64(
    MoonfmiClocksInstance *s,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    fmi3Float64 values[],
    size_t nValues) {
  for (size_t i = 0; i < nValueReferences; i++) {
    if (i >= nValues) {
      return fmi3Error;
    }
    switch (valueReferences[i]) {
    case 4U:
      values[i] = s->state;
      break;
    case 5U:
      values[i] = 1.0;
      break;
    case 10U:
      values[i] = (fmi3Float64)s->constant_counter;
      break;
    case 11U:
      values[i] = (fmi3Float64)s->triggered_counter;
      break;
    case 12U:
      values[i] = (fmi3Float64)s->countdown_counter;
      break;
    default:
      return fmi3Error;
    }
  }
  return fmi3OK;
}

fmi3Status fmi3GetFloat64(
    fmi3Instance instance,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    fmi3Float64 values[],
    size_t nValues) {
  return moonfmi_clocks_get_float64(moonfmi_clocks_instance(instance),
                                    valueReferences, nValueReferences,
                                    values, nValues);
}

fmi3Status fmi3SetFloat64(
    fmi3Instance instance,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    const fmi3Float64 values[],
    size_t nValues) {
  /* Nothing settable; reject like a strict FMU. */
  (void)instance;
  (void)valueReferences;
  (void)nValueReferences;
  (void)values;
  (void)nValues;
  return fmi3Error;
}

fmi3Status fmi3GetInt32(
    fmi3Instance instance,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    fmi3Int32 values[],
    size_t nValues) {
  MoonfmiClocksInstance *s = moonfmi_clocks_instance(instance);
  for (size_t i = 0; i < nValueReferences; i++) {
    if (i >= nValues) {
      return fmi3Error;
    }
    switch (valueReferences[i]) {
    case 0U:
      values[i] = (fmi3Int32)s->constant_counter;
      break;
    case 1U:
      values[i] = (fmi3Int32)s->triggered_counter;
      break;
    case 2U:
      values[i] = (fmi3Int32)s->countdown_counter;
      break;
    case 3U:
      values[i] = (fmi3Int32)s->early_return_requests;
      break;
    default:
      return fmi3Error;
    }
  }
  return fmi3OK;
}

fmi3Status fmi3SetInt32(
    fmi3Instance instance,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    const fmi3Int32 values[],
    size_t nValues) {
  (void)instance;
  (void)valueReferences;
  (void)nValueReferences;
  (void)values;
  (void)nValues;
  return fmi3Error;
}

/* ------------------------------------------------------------------------- */
/* Model Exchange                                                            */
/* ------------------------------------------------------------------------- */

fmi3Status fmi3SetTime(fmi3Instance instance, fmi3Float64 time) {
  moonfmi_clocks_instance(instance)->time = time;
  return fmi3OK;
}

fmi3Status fmi3GetContinuousStates(fmi3Instance instance,
                                   fmi3Float64 continuousStates[],
                                   size_t nContinuousStates) {
  if (nContinuousStates != 1) {
    return fmi3Error;
  }
  continuousStates[0] = moonfmi_clocks_instance(instance)->state;
  return fmi3OK;
}

fmi3Status fmi3SetContinuousStates(
    fmi3Instance instance,
    const fmi3Float64 continuousStates[],
    size_t nContinuousStates) {
  if (nContinuousStates != 1) {
    return fmi3Error;
  }
  moonfmi_clocks_instance(instance)->state = continuousStates[0];
  return fmi3OK;
}

fmi3Status fmi3GetContinuousStateDerivatives(
    fmi3Instance instance,
    fmi3Float64 derivatives[],
    size_t nContinuousStates) {
  if (nContinuousStates != 1) {
    return fmi3Error;
  }
  derivatives[0] = 1.0; /* d clock_time / d t */
  return fmi3OK;
}

fmi3Status fmi3GetEventIndicators(fmi3Instance instance,
                                  fmi3Float64 eventIndicators[],
                                  size_t nEventIndicators) {
  (void)instance;
  for (size_t i = 0; i < nEventIndicators; i++) {
    eventIndicators[i] = 1.0;
  }
  return fmi3OK;
}

fmi3Status fmi3GetNominalsOfContinuousStates(
    fmi3Instance instance,
    fmi3Float64 nominals[],
    size_t nContinuousStates) {
  (void)instance;
  for (size_t i = 0; i < nContinuousStates; i++) {
    nominals[i] = 1.0;
  }
  return fmi3OK;
}

fmi3Status fmi3CompletedIntegratorStep(
    fmi3Instance instance,
    fmi3Boolean noSetFMUStatePriorToCurrentPoint,
    fmi3Boolean *enterEventMode,
    fmi3Boolean *terminateSimulation) {
  (void)noSetFMUStatePriorToCurrentPoint;
  MoonfmiClocksInstance *s = moonfmi_clocks_instance(instance);
  /* One scheduled event: enter event mode once at t = 0.3 so the ME
     master runs the clock rounds inside event mode there. */
  if (!s->settled_event && moonfmi_clocks_is_close(s->time,
                                                   MOONFMI_CLOCKS_EVENT_TIME)) {
    s->settled_event = 1;
    *enterEventMode = fmi3True;
  } else {
    *enterEventMode = fmi3False;
  }
  *terminateSimulation = fmi3False;
  return fmi3OK;
}

fmi3Status fmi3UpdateDiscreteStates(
    fmi3Instance instance,
    fmi3Boolean *discreteStatesNeedUpdate,
    fmi3Boolean *terminateSimulation,
    fmi3Boolean *nominalsOfContinuousStatesChanged,
    fmi3Boolean *valuesOfContinuousStatesChanged,
    fmi3Boolean *nextEventTimeDefined,
    fmi3Float64 *nextEventTime) {
  (void)instance;
  *discreteStatesNeedUpdate = fmi3False;
  *terminateSimulation = fmi3False;
  *nominalsOfContinuousStatesChanged = fmi3False;
  *valuesOfContinuousStatesChanged = fmi3False;
  *nextEventTimeDefined = fmi3False;
  *nextEventTime = 0.0;
  return fmi3OK;
}

/* ------------------------------------------------------------------------- */
/* Unused but declared by the header                                         */
/* ------------------------------------------------------------------------- */

fmi3Status fmi3SetDebugLogging(fmi3Instance instance,
                               fmi3Boolean loggingOn,
                               size_t nCategories,
                               const fmi3String categories[]) {
  (void)instance;
  (void)loggingOn;
  (void)nCategories;
  (void)categories;
  return fmi3OK;
}
