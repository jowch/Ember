// Corpus test: parses every R file in the corpus with the Lezer grammar,
// and compares its top-level statement boundaries against R's own parser
// (via test/r_boundaries.R, run as a prerequisite step here).
//
// The corpus is every .R file the installed R packages ship in doc/,
// demo/ and tests/ (r_boundaries.R finds them), so this runs on any
// machine with R and jsonlite. EMBER_CORPUS=<dir> uses a folder with a
// manifest.csv and files/ instead, such as the gitignored spikes/corpus
// of a few hundred scripts this test was first written against (#58).
//
// Usage: npm run corpus   (or node test/corpus.mjs)
//
// Fails (exit 1) if Lezer finds an error node, or a different top-level
// boundary, in any file R parses. Writes test/corpus-failures.txt with
// per-file detail and prints a summary (error-node count, boundary match
// rate, R parse failures, total parse time).
import { execFileSync } from "node:child_process"
import { readFileSync, writeFileSync, existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import { rParser } from "../dist/index.js"

const here = dirname(fileURLToPath(import.meta.url))
const corpusDir = process.env.EMBER_CORPUS
const boundariesJson = join(here, "r-boundaries.json")

function findRscript() {
  const candidates = [
    join(process.env.HOME || "", ".local/share/rig/r/4.6.1/bin/Rscript"),
    join(process.env.HOME || "", ".local/bin/Rscript"),
    "Rscript"
  ]
  for (const c of candidates) {
    try { execFileSync(c, ["--version"], { stdio: "ignore" }); return c } catch {}
  }
  throw new Error("No Rscript found")
}

console.log("Running R to get reference top-level boundaries...")
const rscript = findRscript()
const rArgs = [join(here, "r_boundaries.R"), boundariesJson]
if (corpusDir) rArgs.push(join(corpusDir, "manifest.csv"), join(corpusDir, "files"))
execFileSync(rscript, ["--vanilla", ...rArgs], { stdio: "inherit" })
const rBoundaries = JSON.parse(readFileSync(boundariesJson, "utf8"))

let totalFiles = 0
let rParseFailures = 0
let filesWithErrorNodes = 0
let totalErrorNodes = 0
let totalRBoundaries = 0
let matchedBoundaries = 0
let totalParseTimeMs = 0
const failureLines = []

for (const [id, rInfo] of Object.entries(rBoundaries)) {
  const filePath = rInfo.path
  if (!existsSync(filePath)) { failureLines.push(`${id}: file missing`); continue }
  totalFiles++

  const src = readFileSync(filePath, "utf8")
  const t0 = performance.now()
  const tree = rParser.parse(src)
  totalParseTimeMs += performance.now() - t0

  let errorNodes = 0
  tree.iterate({ enter: n => { if (n.type.isError) errorNodes++ } })

  // A file R can't parse has no reference to compare against, and Lezer's
  // error nodes in it are expected.
  if (rInfo.error) {
    rParseFailures++
    continue
  }
  if (errorNodes > 0) {
    filesWithErrorNodes++
    totalErrorNodes += errorNodes
    failureLines.push(`${id}: ${errorNodes} error node(s)`)
  }

  const lezerBoundaries = []
  const cursor = tree.cursor()
  if (cursor.firstChild()) {
    do {
      if (cursor.name === "TopExpr") lezerBoundaries.push([cursor.from, cursor.to])
    } while (cursor.nextSibling())
  }

  const rPairs = rInfo.boundaries.map(b => `${b[0]},${b[1]}`)
  const lezerSet = new Set(lezerBoundaries.map(b => `${b[0]},${b[1]}`))
  totalRBoundaries += rPairs.length
  let fileMatched = 0
  for (const p of rPairs) if (lezerSet.has(p)) { matchedBoundaries++; fileMatched++ }
  if (fileMatched !== rPairs.length) {
    failureLines.push(
      `${id}: boundary mismatch, R has ${rPairs.length} top-level exprs, ` +
      `Lezer matched ${fileMatched} (Lezer found ${lezerBoundaries.length} top-level nodes)`
    )
  }
}

const matchRate = totalRBoundaries ? (100 * matchedBoundaries / totalRBoundaries) : 100

writeFileSync(join(here, "corpus-failures.txt"), failureLines.join("\n") + "\n")

console.log(`
Corpus summary (${totalFiles} files)
  R parse failures (skipped from boundary comparison): ${rParseFailures}
  Files with Lezer error nodes: ${filesWithErrorNodes} (${totalErrorNodes} total error nodes)
  Top-level boundary match: ${matchedBoundaries} / ${totalRBoundaries} (${matchRate.toFixed(3)}%)
  Total Lezer parse time: ${totalParseTimeMs.toFixed(1)} ms for ${totalFiles} files
  Per-file failure detail: test/corpus-failures.txt
`)

if (totalFiles === 0) {
  console.error("No corpus files found")
  process.exit(1)
}
if (failureLines.length > 0) process.exit(1)
