# The engine's rules: which functions attach packages, which change global
# settings, which reads can't be tracked, and how formulas are read. The
# design says these rules change rarely and each change is announced, so
# they live in one file that nothing else in the package duplicates.
#
# Every table is a plain character vector or list of the fully-qualified
# names the walker matches on. A call matches by its head symbol
# (`library`) or by `pkg::name` / `pkg:::name` with the package dropped.

#' Functions that attach a package to the search path.
#'
#' The first argument names the package. A bare symbol is the package name
#' unless `character.only = TRUE`, in which case the name is computed and the
#' cell gets a `computed_package` note instead.
attach_functions <- c("library", "require", "p_load")

#' Functions that load a package without attaching it.
#'
#' `pkg::fn` and `pkg:::fn` are handled by the walker as calls to `::`, not
#' through this table.
use_functions <- c("requireNamespace", "loadNamespace", "use")

#' Functions whose top-level call changes a global setting.
#'
#' A call counts only when it changes something: `options()` and
#' `options("digits")` read, `options(digits = 3)` writes, and so does an
#' unnamed argument that isn't a bare string (`options(op)`, restoring a
#' saved options list). `write_only` lists the ones that need at least one
#' such argument to count. withr's `local_*` functions count too: at the
#' top level of a cell the "local" frame is the global environment and
#' never exits.
setting_functions <- list(
  always = c("Sys.setenv", "Sys.unsetenv", "setwd", "Sys.setlocale",
             "attach", "theme_set", "local_options", "local_envvar",
             "local_dir", "local_locale"),
  write_only = c("options")
)

#' Functions that read globals in a way static reading can't follow.
#'
#' The cell gets an `untracked_read` note. `eval` is listed because
#' `eval(parse(text = ...))` is the common form; a plain `eval(quote(x))`
#' also gets the note, which is the cheap side of the tradeoff.
untracked_reads <- c("get", "get0", "mget", "exists", "dynGet",
                     "eval", "evalq", "eval.parent")

#' Calls whose arguments are code, not references.
#'
#' Their arguments are not walked. `bquote` is walked, because `.()` parts
#' read globals and the design prefers an extra edge to a missing one.
quoting_functions <- c("quote", "substitute", "expression", "alist")

#' Assignment operators, each with the side that names the target.
assignment_ops <- c("<-" = "lhs", "=" = "lhs", "<<-" = "lhs",
                    "->" = "rhs", "->>" = "rhs", "%<>%" = "lhs")

#' Calls that define a name from a literal argument at the top level.
#'
#' `assign("x", v)` defines `x` when the first argument is a string and no
#' `envir` or `pos` argument is given. `data(iris)` defines `iris` when the
#' argument is a symbol or string, and likewise for each name in a
#' `list = c(...)` literal vector; a named argument such as `package =`,
#' `envir =` or `lib.loc =` is never a dataset name and is walked as
#' ordinary code instead. Other forms are left to the worker, which
#' compares the global environment before and after the cell.
literal_definers <- c("assign", "data")

#' Formula operators whose every argument is a term.
#'
#' Inside a formula with a `data` argument, a symbol under one of these is
#' a column, not a reference. Any other call inside the formula takes only
#' its first argument as a column; the rest are references
#' (`poly(x, deg)`, `s(x, k = k)`).
formula_transparent <- c("+", "-", "*", "/", "^", ":", "|", "||", "&", "&&",
                         "(", "I", "%in%", "==", "!=", "<", ">", "<=", ">=")

#' Model functions whose second positional argument is the data.
#'
#' `lm(y ~ x, df)` reads its formula by the column rule, as
#' `lm(y ~ x, data = df)` does. Any other call needs a named `data`.
formula_data_positional <- c("lm", "glm", "aov", "lmer", "glmer", "nls",
                             "gam", "t.test", "wilcox.test", "xtabs",
                             "aggregate", "boxplot")

#' Names never recorded as references or definitions.
#'
#' `.` is a formula placeholder and the magrittr pipe placeholder.
#' `.Random.seed` follows the random-numbers decision. `.x`, `.y`, `.data`
#' and `.env` are purrr/dplyr pronouns and `~` lambda arguments, never a
#' notebook object. `break` and `next` parse as zero-argument calls
#' (`` `break`() ``); listing them here is simpler than special-casing loop
#' control in the walker.
ignored_names <- c(".", ".Random.seed", "T", "F", "TRUE", "FALSE", "NULL",
                   "NA", "Inf", "NaN", "...", "..1", "..2", "..3",
                   ".x", ".y", ".data", ".env", "break", "next")

#' Is `name` private to its cell?
#'
#' Dot-names are private. Used by the graph, never by the walker: the
#' walker records every name and the graph applies the policy, so the
#' analysis of a cell doesn't depend on which rule is in force.
is_private_name <- function(name) {
  startsWith(name, ".")
}
