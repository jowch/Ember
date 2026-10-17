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
static DWORD main_thread = 0;

static void event_name(char *buf, size_t size, unsigned long pid) {
  snprintf(buf, size, "Local\\ember-interrupt-%lu", pid);
}

static DWORD WINAPI interrupt_listener(LPVOID unused) {
  for (;;) {
    if (WaitForSingleObject(interrupt_event, INFINITE) != WAIT_OBJECT_0) return 0;
    UserBreak = 1;
    PostThreadMessage(main_thread, 0, 0, 0);
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
  interrupt_event = ev;
  main_thread = GetCurrentThreadId();
  HANDLE thread = CreateThread(NULL, 0, interrupt_listener, NULL, 0, NULL);
  if (!thread) {
    CloseHandle(ev);
    interrupt_event = NULL;
    return ScalarLogical(0);
  }
  CloseHandle(thread);
  return ScalarLogical(1);
#else
  return ScalarLogical(0);
#endif
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
