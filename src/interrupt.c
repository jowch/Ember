#include <R.h>
#include <Rinternals.h>

/* Interrupting a worker on Windows (#48). Windows has no SIGINT to send:
   processx's interrupt() starts a helper that attaches to the worker's
   console and sends it CTRL+C. A worker has a console only when the server
   has one, so a server started without one (by a GUI program, a service,
   an agent's tool) loses every interrupt, and processx still says it sent
   it. With a console the helper is slow enough that an interrupt can land
   after the cell it was meant for.

   So on Windows the worker waits on a named event of its own instead, on a
   thread of its own. The server sets the event; the thread does what R's
   own CTRL+C handler does (src/gnuwin32 in R): set UserBreak, which R
   checks wherever it checks for interrupts, and wake the main thread in
   case it is waiting for window messages. R then raises the interrupt on
   the main thread, as for CTRL+C. Setting the event fails if the worker has
   no such event, so the server knows when an interrupt can't be delivered.
   On Unix both routines do nothing and return FALSE: the server sends
   SIGINT there. */

#if defined(_WIN32)
#include <windows.h>
#include <stdio.h>
#include <Rembedded.h>   /* UserBreak */

static HANDLE interrupt_event = NULL;
/* The drain's handshake with the listener (#238): the main thread sets
   flush_event and waits for flushed_event. */
static HANDLE flush_event = NULL, flushed_event = NULL;
static DWORD main_thread = 0;
static HANDLE listener_thread = NULL;
/* Test-only (C_interrupt_test_delay()): how long the listener waits
   between taking an interrupt and applying it, to widen #238's window.
   0, so no wait, unless a test sets it. */
static volatile LONG test_delay_ms = 0;

static void event_name(char *buf, size_t size, unsigned long pid) {
  snprintf(buf, size, "Local\\ember-interrupt-%lu", pid);
}

/* One wake at a time, so the drain can't land between this thread taking
   an interrupt (the auto-reset event clears as the wait returns) and
   setting UserBreak. WaitForMultipleObjects reports the lowest signalled
   index, so an interrupt set before a drain is applied first and then
   cleared by the flush, or taken by the flush itself; one set after the
   drain still reaches the run. */
static DWORD WINAPI interrupt_listener(LPVOID unused) {
  HANDLE both[2] = { interrupt_event, flush_event };
  for (;;) {
    DWORD w = WaitForMultipleObjects(2, both, FALSE, INFINITE);
    if (w == WAIT_OBJECT_0) {
      if (test_delay_ms > 0) Sleep((DWORD) test_delay_ms);
      UserBreak = 1;
      PostThreadMessage(main_thread, 0, 0, 0);
    } else if (w == WAIT_OBJECT_0 + 1) {
      WaitForSingleObject(interrupt_event, 0);  /* drop one still pending */
      UserBreak = 0;
      SetEvent(flushed_event);
    } else {
      return 0;
    }
  }
}
#endif

/* Worker side: create this process's event and start the thread that waits
   on it. TRUE once listening; calling it again does nothing more. */
SEXP C_interrupt_listen(void) {
#if defined(_WIN32)
  if (interrupt_event) return ScalarLogical(1);
  char name[64];
  event_name(name, sizeof name, (unsigned long) GetCurrentProcessId());
  HANDLE ev = CreateEventA(NULL, FALSE, FALSE, name);
  if (!ev) return ScalarLogical(0);
  HANDLE flush = CreateEventA(NULL, FALSE, FALSE, NULL);
  HANDLE flushed = CreateEventA(NULL, FALSE, FALSE, NULL);
  if (!flush || !flushed) {
    if (flush) CloseHandle(flush);
    if (flushed) CloseHandle(flushed);
    CloseHandle(ev);
    return ScalarLogical(0);
  }
  flush_event = flush;
  flushed_event = flushed;
  interrupt_event = ev;
  main_thread = GetCurrentThreadId();
  HANDLE thread = CreateThread(NULL, 0, interrupt_listener, NULL, 0, NULL);
  if (!thread) {
    CloseHandle(ev);
    CloseHandle(flush_event);
    CloseHandle(flushed_event);
    interrupt_event = flush_event = flushed_event = NULL;
    return ScalarLogical(0);
  }
  listener_thread = thread;  /* kept: the drain watches it */
  return ScalarLogical(1);
#else
  return ScalarLogical(0);
#endif
}

/* Worker side, just before a run starts: drop an interrupt still pending.
   The server interrupts a run only once the worker has said it began, so
   one pending now is late, meant for the run before. R on Windows looks
   for one only every 200 ms while it waits on the socket, so a late one can
   still be pending when the next run is read, and would stop that run.
   The listener does the clearing, so a late interrupt it has already
   taken but not yet applied is cleared too (#238). */
SEXP C_interrupt_drain(void) {
#if defined(_WIN32)
  if (interrupt_event) {
    SetEvent(flush_event);
    /* If the listener has somehow ended, nothing would answer: clear
       UserBreak here instead of waiting forever. */
    HANDLE wait[2] = { flushed_event, listener_thread };
    if (WaitForMultipleObjects(2, wait, FALSE, INFINITE) != WAIT_OBJECT_0) UserBreak = 0;
  } else {
    UserBreak = 0;
  }
#endif
  return R_NilValue;
}

/* Server side: interrupt the worker with process id `pid`. TRUE if its
   event was set; FALSE if it has none (not listening, or gone). */
SEXP C_interrupt_send(SEXP pid) {
#if defined(_WIN32)
  int p = Rf_asInteger(pid);
  if (p == NA_INTEGER || p <= 0) return ScalarLogical(0);
  char name[64];
  event_name(name, sizeof name, (unsigned long) p);
  HANDLE ev = OpenEventA(EVENT_MODIFY_STATE, FALSE, name);
  if (!ev) return ScalarLogical(0);
  BOOL ok = SetEvent(ev);
  CloseHandle(ev);
  return ScalarLogical(ok != 0);
#else
  return ScalarLogical(0);
#endif
}

/* Test-only: make the listener wait `ms` between taking an interrupt and
   applying it (test-worker.R, #238). Nothing else sets it. */
SEXP C_interrupt_test_delay(SEXP ms) {
#if defined(_WIN32)
  InterlockedExchange(&test_delay_ms, (LONG) Rf_asInteger(ms));
#endif
  return R_NilValue;
}
