import { nodeResolve } from "@rollup/plugin-node-resolve"

export default {
  input: "src/index.js",
  output: [
    { file: "dist/index.js", format: "esm" },
    { file: "dist/index.cjs", format: "cjs" }
  ],
  external: id => !/^[./]/.test(id) && id !== "./parser.js" && !id.startsWith("/"),
  plugins: [nodeResolve()]
}
