// Known failures, keyed by their open issue (#412). A failed test counts as
// known only when its error matches one entry's `error` exactly: any other
// failure in the same test, or a test file stopped at its time limit, still
// fails the run. Nothing is skipped: a known failure is still run and still
// reported, as a warning that names its issue, and the run's other results
// stand.
//
// known-reporter.mjs writes each failed test's name and error to a file;
// run.mjs reads it once the tests end.

export const KNOWN = [
  // Windows only, cause unknown: a page's load from the test's own
  // 127.0.0.1 server fails with WSAENOBUFS. openNotebook names it (#475).
  { issue: 412, error: /^opening the notebook: http:\/\/127\.0\.0\.1:\d+\/\S+ failed to load: net::ERR_NO_BUFFER_SPACE$/ },
];

/** The KNOWN entry a failure's error matches, or undefined. */
export function knownFor(error) {
  return KNOWN.find((k) => k.error.test(error));
}
