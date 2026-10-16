// #91: the Packages tab's failure cards, one per package the notebook
// loads (inst/frontend/common/install_cards.js). Plain functions, so no
// server or browser here.

import { test } from "node:test";
import assert from "node:assert/strict";
import { install_cards, cause_groups, join_names } from "../../../inst/frontend/common/install_cards.js";

const fail = (pkg, kind, extra = {}) => ({ package: pkg, version: null, kind, detail: null, libraries: null, needed_by: [], ...extra });
const summary = (cards) => cards.map((c) => [c.package, c.own?.package ?? null, c.causes.map((f) => f.package)]);

test("#17's DESeq2 notebook: 14 failures under one loaded package make one card", () => {
  const deps = ["Biobase", "BiocGenerics", "IRanges", "S4Vectors", "GenomicRanges", "SummarizedExperiment",
    "MatrixGenerics", "GenomeInfoDb", "XVector", "S4Arrays", "SparseArray", "DelayedArray", "UCSC.utils"];
  const failures = [
    fail("S4Vectors", "compile", { needed_by: ["DESeq2"] }),
    fail("DESeq2", "dependency", { detail: "S4Vectors", needed_by: ["DESeq2"] }),
    ...deps.filter((d) => d !== "S4Vectors").map((d) => fail(d, "dependency", { detail: "S4Vectors", needed_by: ["DESeq2"] })),
  ];
  assert.equal(failures.length, 14);
  assert.deepEqual(summary(install_cards(failures)), [["DESeq2", null, ["S4Vectors"]]]);
});

test("a loaded package that failed itself says so, with what it needs after", () => {
  const failures = [
    fail("broom", "compile", { needed_by: ["broom"] }),
    fail("rlang", "download", { needed_by: ["broom"] }),
  ];
  assert.deepEqual(summary(install_cards(failures)), [["broom", "broom", ["rlang"]]]);
});

test("a dependency two loaded packages need is named on both cards", () => {
  const failures = [fail("rlang", "compile", { needed_by: ["dplyr", "ggplot2"] })];
  assert.deepEqual(summary(install_cards(failures)), [["dplyr", null, ["rlang"]], ["ggplot2", null, ["rlang"]]]);
});

test("before needed_by fills in, a card follows the dependency rows to the failure", () => {
  // A loaded package names itself in needed_by even with no index; the rest are empty.
  const failures = [
    fail("BiocGenerics", "compile"),
    fail("Biobase", "dependency", { detail: "BiocGenerics" }),
    fail("DESeq2", "dependency", { detail: "Biobase", needed_by: ["DESeq2"] }),
  ];
  assert.deepEqual(summary(install_cards(failures)), [["DESeq2", null, ["BiocGenerics"]]]);
});

test("with no loaded package to group under, each failure that caused something keeps a card", () => {
  const failures = [
    fail("toyB", "compile"),
    fail("toyC", "dependency", { detail: "toyB" }),
    fail("toyD", "unavailable"),
  ];
  assert.deepEqual(summary(install_cards(failures)), [["toyB", "toyB", []], ["toyD", "toyD", []]]);
});

test("a dependency row whose package isn't among the failures still names it", () => {
  const cards = install_cards([fail("toyA", "dependency", { detail: "toyZ", needed_by: ["toyA"] })]);
  assert.deepEqual(summary(cards), [["toyA", null, ["toyZ"]]]);
  assert.equal(cards[0].causes[0].kind, "other");
});

test("a dependency cycle doesn't loop", () => {
  const failures = [fail("a", "dependency", { detail: "b" }), fail("b", "dependency", { detail: "a" })];
  // The first card covers the whole chain, so b gets none of its own.
  assert.deepEqual(summary(install_cards(failures)), [["a", null, []]]);
});

test("causes are grouped by the sentence they read as", () => {
  const groups = cause_groups([
    fail("a", "compile"),
    fail("b", "missing_system", { libraries: "libxml2.so.2" }),
    fail("c", "configure"),
    fail("d", "system", { libraries: "libcurl.so.4" }),
    fail("e", "system"),
    fail("f", "dependency"),
  ]);
  assert.deepEqual(groups.map((g) => [g.kind, g.failures.map((f) => f.package)]),
    [["compile", ["a", "c"]], ["missing_system", ["b", "d"]], ["system", ["e"]], ["other", ["f"]]]);
});

test("names join as a sentence's list", () => {
  assert.equal(join_names(["rlang 1.1.6"]), "rlang 1.1.6");
  assert.equal(join_names(["a", "b"]), "a and b");
  assert.equal(join_names(["a", "b", "c"]), "a, b, and c");
});
