// #558: which cells are a `?topic` lookup, as at R's console
// (inst/frontend/common/help_query.js). A plain function, so no server or
// browser here.

import { test } from "node:test";
import assert from "node:assert/strict";
import { help_query_of } from "../../../inst/frontend/common/help_query.js";

test("a cell that is one ?topic line asks for that topic", () => {
  assert.equal(help_query_of("?mean"), "mean");
  assert.equal(help_query_of("  ? mean  \n"), "mean");
  assert.equal(help_query_of("?stats::sd"), "stats::sd");
  assert.equal(help_query_of("?base:::print.default"), "base::print.default");
  assert.equal(help_query_of("?`+`"), "+");
  assert.equal(help_query_of('?"if"'), "if");
  assert.equal(help_query_of("?data.frame"), "data.frame");
});

test("anything else is not a lookup", () => {
  for (const code of ["", "?", "??regression", "mean(x)", "?mean\nx <- 1", "x <- 1\n?mean", "?mean(1)", "# ?mean", null]) {
    assert.equal(help_query_of(code), null, JSON.stringify(code));
  }
});
