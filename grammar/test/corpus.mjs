// Corpus test: parses every R file in spikes/corpus/files with the Lezer
// grammar, and compares its top-level statement boundaries against R's
// own parser (via test/r_boundaries.R, run as a prerequisite step here).
//
// Usage: node test/corpus.mjs
//
// Writes test/corpus-failures.txt with per-file detail and prints a
// summary (error-node count, boundary match rate, R parse failures,
// total parse time).
import { execFileSync } from "node:child_process"
import { readFileSync, writeFileSync, existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import { rParser } from "../dist/index.js"

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(here, "..", "..")
const corpusDir = join(repoRoot, "spikes", "corpus")
const manifestPath = join(corpusDir, "manifest.csv")
const filesDir = join(corpusDir, "files")
const boundariesJson = join(here, "r-boundaries.json")

function parseCsv(text) {
  // Minimal CSV parser sufficient for manifest.csv (quoted fields, no
  // embedded commas-in-quotes edge cases beyond plain quoting).
  const lines = text.split("\n").filter(l => l.length > 0)
  const header = splitCsvLine(lines[0])
  return lines.slice(1).map(line => {
    const cells = splitCsvLine(line)
    const row = {}
    header.forEach((h, i) => { row[h] = cells[i] })
    return row
  })
}
function splitCsvLine(line) {
  const out = []
  let cur = "", inQ = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (inQ) {
      if (c == '"') { if (line[i + 1] == '"') { cur += '"'; i++ } else inQ = false }
      else cur += c
    } else {
      if (c == '"') inQ = true
      else if (c == ",") { out.push(cur); cur = "" }
      else cur += c
    }
  }
  out.push(cur)
  return out
}

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
execFileSync(rscript, ["--vanilla", join(here, "r_boundaries.R"), manifestPath, filesDir, boundariesJson], { stdio: "inherit" })
const rBoundaries = JSON.parse(readFileSync(boundariesJson, "utf8"))

const manifest = parseCsv(readFileSync(manifestPath, "utf8"))

let totalFiles = 0
let rParseFailures = 0
let filesWithErrorNodes = 0
let totalErrorNodes = 0
let totalRBoundaries = 0
let matchedBoundaries = 0
let totalParseTimeMs = 0
const failureLines = []

for (const row of manifest) {
  const id = row.id
  const fileName = row.file.split("/").pop()
  const filePath = join(filesDir, fileName)
  if (!existsSync(filePath)) { failureLines.push(`${id}: file missing`); continue }
  totalFiles++

  const src = readFileSync(filePath, "utf8")
  const t0 = performance.now()
  const tree = rParser.parse(src)
  totalParseTimeMs += performance.now() - t0

  let errorNodes = 0
  tree.iterate({ enter: n => { if (n.type.isError) errorNodes++ } })
  if (errorNodes > 0) {
    filesWithErrorNodes++
    totalErrorNodes += errorNodes
    failureLines.push(`${id}: ${errorNodes} error node(s)`)
  }

  const rInfo = rBoundaries[id]
  if (!rInfo || rInfo.error) {
    rParseFailures++
    continue
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
