// A node:test reporter that writes one JSON line per failed test (its name,
// file and error) for run.mjs to check against known.mjs. The run's own
// output still comes from the usual reporter.

export default async function* knownReporter(source) {
  for await (const event of source) {
    if (event.type !== "test:fail") continue;
    const { name, file, details } = event.data;
    const error = details?.error;
    // A test's own failure arrives wrapped (ERR_TEST_FAILURE), with the
    // error the test threw as its cause.
    const message = String(error?.cause?.message ?? error?.message ?? error);
    yield JSON.stringify({ name, file, failureType: error?.failureType, message }) + "\n";
  }
}
