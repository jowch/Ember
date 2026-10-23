#include <R.h>
#include <Rinternals.h>
#include <R_ext/GraphicsEngine.h>   /* R_interrupts_suspended */

/* Printed text shown while a cell runs (#470). The worker sinks a cell's
   stdout into a file and reads it back when a message or warning comes,
   before a prompt, and at the run's end, so text printed by a cell that
   then keeps computing stayed hidden until it finished. R gives no R-level
   hook while code runs, but it processes events wherever it checks for an
   interrupt (in every loop, the byte-code ones too, and in Sys.sleep()):
   R_PolledEvents on Unix, R_tcldo on Windows, which tcltk also uses. The
   worker sets `fun` here, and this calls it at most every `every` seconds,
   with interrupts held off so one arriving meanwhile is taken after it
   returns instead of being lost. A cell running C code that doesn't check
   for interrupts (a long sort) doesn't reach it, and stays as before. */

#if defined(_WIN32)
#include <windows.h>
extern __declspec(dllimport) void (*R_tcldo)(void);
static double now(void) { return (double) GetTickCount64() / 1000.0; }
#else
#include <R_ext/eventloop.h>
#include <time.h>
static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double) t.tv_sec + (double) t.tv_nsec / 1e9;
}
#endif

static void (*previous)(void) = NULL;
static SEXP fun = NULL;
static double every = 0.25, last = 0;
static int busy = 0;

static void call_fun(void *unused) {
  SEXP call = PROTECT(Rf_lang1(fun));
  Rf_eval(call, R_GlobalEnv);
  UNPROTECT(1);
}

static void console_poll(void) {
  if (previous) previous();
  if (fun == NULL || busy) return;
  double t = now();
  if (t - last < every) return;
  last = t;
  busy = 1;
  Rboolean suspended = R_interrupts_suspended;
  R_interrupts_suspended = TRUE;
  R_ToplevelExec(call_fun, NULL);
  R_interrupts_suspended = suspended;
  busy = 0;
}

/* Call `f` (a function of no arguments) from R's event processing, at
   most every `seconds`. Once only: a second call replaces `f`. */
SEXP C_console_poll(SEXP f, SEXP seconds) {
  if (fun != NULL) R_ReleaseObject(fun);
  R_PreserveObject(f);
  fun = f;
  every = Rf_asReal(seconds);
#if defined(_WIN32)
  if (R_tcldo != console_poll) { previous = R_tcldo; R_tcldo = console_poll; }
#else
  if (R_PolledEvents != console_poll) { previous = R_PolledEvents; R_PolledEvents = console_poll; }
#endif
  return R_NilValue;
}
