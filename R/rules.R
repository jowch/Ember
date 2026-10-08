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

#' The setting each setting function changes, as the key prefix the graph
#' compares (settings-cells.md, "What counts as a setting"). `option:` and
#' `env:` keys take the names the call gives (`option:digits`); the rest
#' are one setting each. `attach` keys are `attach:<name>`, from the
#' `name` argument or R's own default for it, the first argument's text.
setting_kinds <- c(options = "option", local_options = "option",
                   Sys.setenv = "env", Sys.unsetenv = "env",
                   local_envvar = "env", setwd = "wd", local_dir = "wd",
                   Sys.setlocale = "locale", local_locale = "locale",
                   theme_set = "theme", attach = "attach")

#' Functions that read globals in a way static reading can't follow.
#'
#' The cell gets an `untracked_read` note. `eval` is listed because
#' `eval(parse(text = ...))` is the common form; a plain `eval(quote(x))`
#' also gets the note, which is the cheap side of the tradeoff. `eval`,
#' `evalq` and `eval.parent` always get the note: resolving their argument
#' statically isn't attempted.
#'
#' `get`, `get0`, `exists`, `mget` and `dynGet` (the `get_family_functions`,
#' below) are different: when the name argument resolves to a literal (or,
#' for `mget`, a literal `c(...)` of names) and no `envir`/`pos`/`inherits =
#' FALSE` argument says otherwise, each name is recorded as a reference
#' instead, and the note is dropped -- the cell no longer reads
#' untrackably, it reads a specific global. A non-literal name
#' (`get(paste0("fit_", i))`) keeps the note, same as before.
untracked_reads <- c("get", "get0", "mget", "exists", "dynGet",
                     "eval", "evalq", "eval.parent")

#' The subset of `untracked_reads` whose name argument is checked for a
#' literal before falling back to the plain `untracked_read` note.
get_family_functions <- c("get", "get0", "exists", "mget", "dynGet")

is_get_family <- function(name) {
  name %in% get_family_functions
}

#' Calls whose arguments are code, not references.
#'
#' Their arguments are not walked (except `substitute`'s second argument;
#' see `walk_expr`'s dispatch). `bquote` is walked, because `.()` parts
#' read globals and the design prefers an extra edge to a missing one.
quoting_functions <- c("quote", "substitute", "expression", "alist")

#' Functions whose string-literal arguments are glue templates (`"{...}"`
#' interpolation): a cell that only uses another cell's variable inside
#' such a string still needs the edge, or it goes stale (cell-graph.md's
#' glue design gap).
glue_functions <- c("glue", "glue_data", "str_glue")

#' Is `name` one of the glue-syntax functions? Every `cli_`-prefixed
#' function (`cli_alert_success`, `cli_abort`, `cli_text`, `cli_warn`,
#' `cli_inform`, ...) uses glue syntax for interpolation, so the whole
#' family is matched by prefix instead of listing each one.
is_glue_function <- function(name) {
  name %in% glue_functions || startsWith(name, "cli_")
}

#' `stringr::str_interp()`'s own interpolation syntax: `${expr}` and
#' `$[fmt]{expr}` (`fmt` a sprintf conversion spec, not code). Its first
#' argument (`string`, positional or named) is the template; same glue
#' design gap, different syntax, so it gets its own table instead of
#' joining `glue_functions`.
str_interp_functions <- c("str_interp")

is_str_interp_function <- function(name) {
  name %in% str_interp_functions
}

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
#' ordinary code instead. `setGeneric("area", ...)` defines `area` (an S4
#' generic, in the global environment), with kind `"generic"`. Other forms
#' are left to the worker, which compares the global environment before and
#' after the cell.
literal_definers <- c("assign", "data", "setGeneric")

#' Calls that register a method for a generic without defining a global
#' name. Each entry names the argument holding the generic and the one
#' holding the class (S3) or signature (S4); either may also be given
#' positionally, first and second. `form` is the analysis's `methods$form`.
#' A literal generic makes the call a method definition of it (the graph
#' adds an edge from every cell that reads the generic); a computed one is
#' ignored, and a computed class or signature still gives the edge but
#' can't take part in the duplicate check.
method_registrars <- list(
  registerS3method = c(generic = "genname", signature = "class", form = "register"),
  .S3method = c(generic = "generic", signature = "class", form = "register"),
  setMethod = c(generic = "f", signature = "signature", form = "s4")
)

#' Base R's S3 generics: a top-level function named `generic.class` is a
#' method only when `generic` is one of these, a function or `setGeneric()`
#' another cell defines, or a name an installed package exports (the graph
#' checks the last two; see `resolve_methods()`). Without this check every
#' dotted helper name (`fit.plot <- function() ...`) would feed every cell
#' that reads its prefix (`fit`), and could close a false cycle.
#'
#' The S3 generics of base, stats, utils, graphics, grDevices and methods as
#' of R 4.6.1 (`utils::isS3stdGeneric()`), the internal and primitive
#' generics (`?InternalMethods`, `.S3PrimitiveGenerics`), and the members of
#' the group generics, so `+.money` and `max.interval` count. The group
#' generics themselves (`Ops.money`, `Math.interval`) are not methods of
#' any one name and are left out.
s3_generics <- c(
  "-", "!", "!=", ".AtNames", ".DollarNames", "[", "[[", "[[<-", "[<-", "*",
  "/", "&", "%/%", "%%", "^", "+", "<", "<=", "==", ">", ">=", "|", "$",
  "$<-", "abs", "acos", "acosh", "add1", "aggregate", "AIC", "alias", "all",
  "all.equal", "anova", "ansari.test", "any", "anyDuplicated", "anyNA",
  "aperm", "ar.burg", "ar.yw", "Arg", "as.array", "as.call", "as.character",
  "as.complex", "as.data.frame", "as.Date", "as.dendrogram", "as.dist",
  "as.double", "as.environment", "as.expression", "as.function", "as.hclust",
  "as.integer", "as.list", "as.logical", "as.matrix", "as.null",
  "as.numeric", "as.person", "as.personList", "as.POSIXct", "as.POSIXlt",
  "as.raster", "as.raw", "as.single", "as.stepfun", "as.table", "as.ts",
  "as.vector", "asin", "asinh", "atan", "atanh", "barplot", "bartlett.test",
  "BIC", "biplot", "bitstring", "boxplot", "by", "c", "case.names", "cbind",
  "cdplot", "ceiling", "chol", "chooseOpsMethod", "close", "coef",
  "coefficients", "conditionCall", "conditionMessage", "confint", "Conj",
  "contour", "cooks.distance", "cophenetic", "cor.test", "cos", "cosh",
  "cospi", "cummax", "cummin", "cumprod", "cumsum", "cut", "cycle", "deltat",
  "density", "deriv", "deriv3", "determinant", "deviance", "df.residual",
  "dfbeta", "dfbetas", "dffits", "diff", "diffinv", "digamma", "dim",
  "dim<-", "dimnames", "dimnames<-", "drop1", "droplevels", "dummy.coef",
  "duplicated", "edit", "effects", "end", "estVar", "exp", "expm1",
  "extractAIC", "family", "fitted", "fitted.values", "fligner.test", "floor",
  "flush", "format", "formula", "free1way", "frequency", "friedman.test",
  "ftable", "gamma", "getCall", "getDLLRegisteredRoutines", "getInitial",
  "glyphJust", "hatvalues", "head", "hist", "identify", "Im", "image",
  "influence", "is.array", "is.finite", "is.infinite", "is.matrix", "is.na",
  "is.na<-", "is.nan", "is.numeric", "is.unsorted", "isSymmetric", "julian",
  "kappa", "kernapply", "knots", "kruskal.test", "ks.test", "labels", "lag",
  "length", "length<-", "levels", "levels<-", "lgamma", "lines", "log",
  "log10", "log1p", "log2", "logLik", "makepredictcall", "mauchly.test",
  "max", "mean", "median", "merge", "min", "Mod", "model.frame",
  "model.matrix", "model.tables", "monthplot", "months", "mood.test",
  "mosaicplot", "mtfrm", "na.action", "na.contiguous", "na.exclude",
  "na.fail", "na.omit", "nameOfClass", "names", "names<-", "napredict",
  "naprint", "naresid", "nchar", "NLSstAsymptotic", "NLSstClosestX",
  "NLSstLfAsymptote", "NLSstRtAsymptote", "nobs", "open", "pacf", "pairs",
  "persp", "plot", "points", "ppr", "prcomp", "predict", "preplot", "pretty",
  "princomp", "print", "prod", "profile", "proj", "prompt", "qqnorm", "qr",
  "quade.test", "quantile", "quarters", "range", "rbind", "Re", "relevel",
  "reorder", "rep", "rep_len", "rep.int", "resid", "residuals", "rev",
  "row.names", "row.names<-", "rowsum", "rstandard", "rstudent", "scale",
  "screeplot", "se.contrast", "seek", "selfStart", "seq", "seq.int",
  "sequence", "sigma", "sign", "simulate", "sin", "sinh", "sinpi", "solve",
  "sort_by", "sortedXyData", "spineplot", "split", "split<-", "sqrt", "SSD",
  "stack", "start", "str", "stripchart", "subset", "sum", "summary",
  "sunflowerplot", "t", "t.test", "tail", "tan", "tanh", "tanpi", "terms",
  "text", "time", "toBibtex", "toLatex", "toString", "transform", "trigamma",
  "trunc", "truncate", "tsdiag", "tsSmooth", "TukeyHSD", "type.convert",
  "unique", "units", "units<-", "unlist", "unstack", "update", "upgrade",
  "var.test", "variable.names", "vcov", "weekdays", "weighted.mean",
  "weights", "wilcox.test", "window", "window<-", "with", "within", "xtfrm"
)

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
#' control in the walker. `..1`, `..2`, ... (any `..N`) are purrr's
#' positional lambda pronouns; matched by `is_dot_dot_name()` since N is
#' unbounded, not listed here.
ignored_names <- c(".", ".Random.seed", "T", "F", "TRUE", "FALSE", "NULL",
                   "NA", "Inf", "NaN", "...",
                   ".x", ".y", ".data", ".env", "break", "next")

#' Is `name` a `..N` positional lambda pronoun (`..1`, `..2`, `..42`, ...)?
is_dot_dot_name <- function(name) {
  grepl("^\\.\\.[0-9]+$", name)
}

#' Is `name` a data.table `..` prefixed name (`..cols`, `..x`), used inside
#' a `[` call's `j`/`by`/`i` position to mean "look this up outside the
#' data.table frame, as a global"? `...` (R's dots) and `..1`/`..2`/... (the
#' positional pronoun above) start with the same two dots but aren't this:
#' the two dots must be followed by a name-start character (a letter, or a
#' dot not itself followed by a digit), not a digit or the end of the name.
is_dotdot_prefixed_name <- function(name) {
  grepl("^\\.\\.([A-Za-z]|\\.[^0-9])", name) && !identical(name, "...")
}

#' Is `name` private to its cell?
#'
#' Dot-names are private. Used by the graph, never by the walker: the
#' walker records every name and the graph applies the policy, so the
#' analysis of a cell doesn't depend on which rule is in force.
is_private_name <- function(name) {
  startsWith(name, ".")
}
