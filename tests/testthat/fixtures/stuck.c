#include <R.h>
#include <Rinternals.h>
#include <stdio.h>
#include <unistd.h>

/* Loops for `secs` seconds without calling R_CheckUserInterrupt(). It
 * first creates the file `marker`, so a test knows the loop has begun. */
SEXP stuck(SEXP secs, SEXP marker) {
  double n = asReal(secs);
  FILE *f = fopen(CHAR(STRING_ELT(marker, 0)), "w");
  if (f) fclose(f);
  for (int i = 0; i < (int)(n * 10); i++) usleep(100000);
  return ScalarInteger(1);
}
