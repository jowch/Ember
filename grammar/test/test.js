import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import { test } from "node:test"
import { fileTests } from "@lezer/generator/test"
import { rParser } from "../dist/index.js"

const dir = dirname(fileURLToPath(import.meta.url))
const file = readFileSync(join(dir, "cases.txt"), "utf8")

for (const { name, run } of fileTests(file, "cases.txt")) {
  test(name, () => run(rParser))
}
