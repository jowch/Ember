#include <R.h>
#include <Rinternals.h>

#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <stdlib.h>
#else
#include <sys/random.h>
#include <errno.h>
#include <stdio.h>
#endif

/* `n` raw bytes from the OS random source, never R's own generator: a
   secret (the URL secret, a worker's hello secret) drawn with sample() or
   runif() is predictable once an attacker knows set.seed()'s argument, and
   reading R's generator at all advances the caller's .Random.seed, which a
   plain analysis script relies on being left alone (design.md: starting a
   server must not change the user's random stream). macOS/BSD use
   arc4random_buf(); Linux uses getrandom(), falling back to /dev/urandom on
   a kernel too old to have it; Windows uses BCryptGenRandom(). */
SEXP C_random_bytes(SEXP n_) {
  int n = Rf_asInteger(n_);
  if (n < 0) Rf_error("ember: random_bytes: n must be >= 0");
  SEXP out = PROTECT(Rf_allocVector(RAWSXP, n));
  unsigned char *buf = (n > 0) ? RAW(out) : NULL;

#if defined(_WIN32)
  if (n > 0) {
    NTSTATUS status = BCryptGenRandom(NULL, buf, (ULONG) n, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (status != 0) {
      UNPROTECT(1);
      Rf_error("ember: BCryptGenRandom failed (status %ld)", (long) status);
    }
  }
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
  if (n > 0) arc4random_buf(buf, (size_t) n);
#else
  size_t got = 0;
  while (got < (size_t) n) {
    ssize_t r = getrandom(buf + got, (size_t) n - got, 0);
    if (r < 0) {
      if (errno == EINTR) continue;
      /* getrandom() unavailable (a kernel older than 3.17): fall back to
         reading /dev/urandom directly. */
      FILE *f = fopen("/dev/urandom", "rb");
      if (!f) { UNPROTECT(1); Rf_error("ember: no OS random source available"); }
      size_t rest = (size_t) n - got;
      size_t rd = fread(buf + got, 1, rest, f);
      fclose(f);
      if (rd != rest) { UNPROTECT(1); Rf_error("ember: short read from /dev/urandom"); }
      got = (size_t) n;
      break;
    }
    got += (size_t) r;
  }
#endif

  UNPROTECT(1);
  return out;
}
