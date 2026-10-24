#include <R.h>
#include <Rinternals.h>
#include <R_ext/GraphicsEngine.h>   /* R_interrupts_suspended */

/* Printed text shown while a cell runs (#470). The worker sinks a cell's
   stdout into a file and reads it back when a message or warning comes,
   before a prompt, and at the run's end, so text printed by a cell that
   then keeps computing stayed hidden until it finished. R gives no R-level
   hook while code runs, but it processes events wherever it checks for an
   interrupt (in every loop, the byte-code ones too, and in Sys.sleep()).
   The worker sets `fun` here, and this calls it a few times a second, with
   interrupts held off so one arriving meanwhile is taken after it returns
   instead of being lost. A cell running C code that doesn't check for
   interrupts (a long sort) doesn't reach it, and stays as before.

   On Unix R calls R_PolledEvents there, as tcltk does. Windows has no hook
   R exports (tcltk's, R_Tcl_do, is set through a call that refuses anyone
   else), but its event processing dispatches the main thread's window
   messages, so a thread timer's callback runs there instead (#482).
   Sys.sleep() on Windows processes events every 0.5 s. Any other message
   loop on the main thread also dispatches it (a modal dialog's, COM's),
   so there a tick can run R code inside C code that didn't expect it, as
   tcltk's callbacks can; a headless worker rarely runs one. */

#if defined(_WIN32)
#include <windows.h>
#include <Rembedded.h>   /* UserBreak */
#else
#include <R_ext/eventloop.h>
#include <time.h>
#include <unistd.h>
#endif

static SEXP fun = NULL;
static double every = 0.25;
static int busy = 0;

static void call_fun(void *unused) {
  SEXP call = PROTECT(Rf_lang1(fun));
  Rf_eval(call, R_GlobalEnv);
  UNPROTECT(1);
}

static void call_now(void) {
  if (fun == NULL || busy) return;
  busy = 1;
  Rboolean suspended = R_interrupts_suspended;
  R_interrupts_suspended = TRUE;
  R_ToplevelExec(call_fun, NULL);
  R_interrupts_suspended = suspended;
  busy = 0;
}

#if defined(_WIN32)
static UINT_PTR timer = 0;
/* Test-only (C_console_test_break()): 1 holds ticks off; 2 sets
   UserBreak at the next tick, as if an interrupt arrived just as it
   began. */
static int test_break = 0;

/* Dispatched only on the thread that set the timer, the main one. */
static VOID CALLBACK console_timer(HWND hwnd, UINT msg, UINT_PTR id, DWORD ms) {
  if (test_break == 1) return;
  int pending = R_interrupts_pending;
  if (test_break == 2) { test_break = 0; UserBreak = 1; }
  call_now();
  /* The tick's send runs R_ProcessEvents() (every socket write waits in
     it), which turns an interrupt that arrived meanwhile (UserBreak) into
     a pending one, interrupts being held off. Only R_CheckUserInterrupt()
     takes a pending one, and on Windows Sys.sleep() and socket waits
     never call it, so it could wait out an hour's sleep. Give it back as
     UserBreak, which the R_ProcessEvents() that dispatched this checks
     next. */
  if (R_interrupts_pending && !pending) { R_interrupts_pending = 0; UserBreak = 1; }
}
#else
static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double) t.tv_sec + (double) t.tv_nsec / 1e9;
}

static void (*previous)(void) = NULL;
static double last = 0;
static pid_t owner = 0;

static void console_poll(void) {
  if (previous) previous();
  /* A forked child (parallel::mclapply()) inherits the hook, the sink
     file and the socket: only the worker itself may send what was
     printed, or each child would send the parent's text again. */
  if (fun == NULL || busy || getpid() != owner) return;
  double t = now();
  if (t - last < every) return;
  last = t;
  call_now();
}
#endif

/* Call `f` (a function of no arguments) from R's event processing, about
   every `seconds`. Once only: a second call replaces `f`. Call it from
   R's main thread. */
SEXP C_console_poll(SEXP f, SEXP seconds) {
  if (fun != NULL) R_ReleaseObject(fun);
  R_PreserveObject(f);
  fun = f;
  every = Rf_asReal(seconds);
#if defined(_WIN32)
  UINT ms = (UINT) (every * 1000);
  /* SetTimer() with the id it returned resets that timer's interval. */
  UINT_PTR t = SetTimer(NULL, timer, ms, console_timer);
  if (t == 0) return ScalarLogical(FALSE);
  timer = t;
#else
  owner = getpid();
  if (R_PolledEvents != console_poll) { previous = R_PolledEvents; R_PolledEvents = console_poll; }
  /* How long R's waits (Sys.sleep(), a socket select) go before checking
     events, as tcltk sets it: by default R sleeps the whole wait in one
     go, so a line printed before Sys.sleep(3) would wait for its end. */
  int usec = (int) (every * 1e6);
  if (R_wait_usec == 0 || R_wait_usec > usec) R_wait_usec = usec;
#endif
  return ScalarLogical(TRUE);
}

/* Test-only (test-worker.R, #482): on Windows, `what` 1 holds ticks off,
   so a line printed meanwhile waits; 2 lets them run again, the next one
   starting with an interrupt arrived. Nothing else calls it. */
SEXP C_console_test_break(SEXP what) {
#if defined(_WIN32)
  test_break = Rf_asInteger(what);
#endif
  return R_NilValue;
}
