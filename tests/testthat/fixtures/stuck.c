#include <R.h>
#include <Rinternals.h>
#include <unistd.h>

/* Loops for `secs` seconds without calling R_CheckUserInterrupt(). */
SEXP stuck(SEXP secs) {
  double n = asReal(secs);
  for (int i = 0; i < (int)(n * 10); i++) usleep(100000);
  return ScalarInteger(1);
}
