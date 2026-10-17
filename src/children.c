#include <R.h>
#include <Rinternals.h>

/* A cell's processx and callr children outlive the worker on Windows, as
   they do on Unix (design.md, #150; #208). processx starts every child
   with `cleanup = TRUE` (its default, and callr's) in one job object of
   its own, set to kill everything in it once the last handle to it
   closes. Only the process that started them holds that handle, and here
   that's the worker, so a restart or a killed server ended them all. On
   Unix the same children are in a session of their own and keep running.

   So on Windows the worker clears that one setting on processx's job:
   after every run, before it says the run is done, and from a thread that
   looks every half second, for a cell still running. processx makes the
   job only when a cell first starts a process, and keeps it while loaded.
   processx's job is the one that lets its members' children leave it
   silently (JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK); R's `system()` makes a
   kill-on-close job per child without that setting, and it is left alone,
   so what a cell starts with `system()` still ends with the worker, as on
   Unix. processx still ends its children itself when R exits normally or
   a process object is collected; only the end of the worker's own process
   no longer takes them. So that a cell's first child isn't left in the
   job for up to half a second, the worker has processx make the job as it
   loads, with a child that only exits, and releases it then (worker.R's
   `release_processx_job()`, #235); the thread stays in case that fails.
   The worker's processx marker matters too: see worker.R's
   `drop_processx_marker()` (#232).

   There is no call to list a process's job handles, so the thread asks
   every small handle value whether it's a job: handles are small integers
   that Windows reuses, and a worker holds a few hundred. On Unix this does
   nothing and returns FALSE. */

#if defined(_WIN32)
#include <windows.h>

#define LAST_HANDLE_VALUE 65536

static int keeping = 0;
/* Set while a run is going (C_cell_children_running()): the thread scans
   only then, since a finished run's children are released before its
   "done", and an idle worker has nothing new to release (#273). */
static HANDLE running_event = NULL;

static void release_processx_jobs(void) {
  for (ULONG_PTR v = 4; v < LAST_HANDLE_VALUE; v += 4) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    if (!QueryInformationJobObject((HANDLE) v, JobObjectExtendedLimitInformation,
                                   &info, sizeof info, NULL)) continue;
    DWORD flags = info.BasicLimitInformation.LimitFlags;
    if ((flags & JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) && (flags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)) {
      info.BasicLimitInformation.LimitFlags = flags & ~JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      SetInformationJobObject((HANDLE) v, JobObjectExtendedLimitInformation, &info, sizeof info);
    }
  }
}

static DWORD WINAPI release_loop(LPVOID unused) {
  for (;;) {
    if (WaitForSingleObject(running_event, INFINITE) != WAIT_OBJECT_0) return 0;
    release_processx_jobs();
    Sleep(500);
  }
  return 0;
}
#endif

/* Worker side: start the thread. TRUE once it runs; calling again does
   nothing more. */
SEXP C_keep_cell_children(void) {
#if defined(_WIN32)
  if (keeping) return ScalarLogical(1);
  running_event = CreateEventA(NULL, TRUE, FALSE, NULL);  /* manual reset */
  if (!running_event) return ScalarLogical(0);
  HANDLE thread = CreateThread(NULL, 0, release_loop, NULL, 0, NULL);
  if (!thread) {
    CloseHandle(running_event);
    running_event = NULL;
    return ScalarLogical(0);
  }
  CloseHandle(thread);
  keeping = 1;
  return ScalarLogical(1);
#else
  return ScalarLogical(0);
#endif
}


/* Worker side, after a run and before its "done": release now, so the
   children a finished cell started don't wait for the thread's next pass. */
SEXP C_release_cell_children(void) {
#if defined(_WIN32)
  release_processx_jobs();
#endif
  return R_NilValue;
}

/* Worker side, as a run starts (`on` TRUE) and once it ends (FALSE). */
SEXP C_cell_children_running(SEXP on) {
#if defined(_WIN32)
  if (running_event) {
    if (Rf_asLogical(on) == TRUE) SetEvent(running_event); else ResetEvent(running_event);
  }
#endif
  return R_NilValue;
}

/* Test-only: TRUE once no job this process holds is still processx's
   kill-on-close one, that is once the release has run on every job there
   is (test-session.R, #274). */
SEXP C_cell_children_released(void) {
#if defined(_WIN32)
  for (ULONG_PTR v = 4; v < LAST_HANDLE_VALUE; v += 4) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    if (!QueryInformationJobObject((HANDLE) v, JobObjectExtendedLimitInformation,
                                   &info, sizeof info, NULL)) continue;
    DWORD flags = info.BasicLimitInformation.LimitFlags;
    if ((flags & JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) && (flags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE))
      return ScalarLogical(0);
  }
#endif
  return ScalarLogical(1);
}
