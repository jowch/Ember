#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#ifndef _WIN32
#include <signal.h>
#endif

/* A process started with SIGINT ignored (a shell's `&`, nohup) passes that
   to its children, and R then never installs its interrupt handler. */
SEXP C_reset_sigint(void) {
  int was_ignored = 0;
#ifndef _WIN32
  struct sigaction sa;
  sigaction(SIGINT, NULL, &sa);
  was_ignored = sa.sa_handler == SIG_IGN;
  if (was_ignored) signal(SIGINT, SIG_DFL);
#endif
  return ScalarLogical(was_ignored);
}

/* Defined in random.c; declared here so every routine can be registered
   from the package's one R_init_ember(). */
extern SEXP C_random_bytes(SEXP n);
/* Defined in interrupt.c. */
extern SEXP C_interrupt_listen(void);
extern SEXP C_interrupt_drain(void);
extern SEXP C_interrupt_send(SEXP pid);
/* Defined in children.c. */
extern SEXP C_keep_cell_children(void);

static const R_CallMethodDef call_methods[] = {
  {"C_reset_sigint", (DL_FUNC) &C_reset_sigint, 0},
  {"C_random_bytes", (DL_FUNC) &C_random_bytes, 1},
  {"C_interrupt_listen", (DL_FUNC) &C_interrupt_listen, 0},
  {"C_interrupt_drain", (DL_FUNC) &C_interrupt_drain, 0},
  {"C_interrupt_send", (DL_FUNC) &C_interrupt_send, 1},
  {"C_keep_cell_children", (DL_FUNC) &C_keep_cell_children, 0},
  {NULL, NULL, 0}
};

void R_init_ember(DllInfo *dll) {
  R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
