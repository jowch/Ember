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

#' Install calls: the way R users say where a package lives
#' (packages.md, "Install calls"). `library(pkg)` is what fetches it; an
#' install call only names the source, which goes into the header's
#' `[sources]`. The walker reads one in a cell's own code, outside function
#' bodies, by the kind of argument it takes: `"github"` (`"user/repo"`,
#' optionally with `@ref`, or a `ref =` argument), `"pak"` (`"user/repo"`,
#' `"github::user/repo"`, `"pkg=user/repo"`, or a plain name), `"repos"`
#' (package names, with an r-universe among `repos`), `"names"` (package
#' names only: Bioconductor's are found without a source). The worker
#' doesn't run one at a cell's top level: the lock already answers it.
#'
#' `install_calls` are matched as `pkg::fn` (as a whole top-level
#' expression the package isn't one the notebook needs: the call doesn't
#' run); `install_calls_bare` by the bare
#' name, for code that attached the package first. `BiocManager::install`
#' has no bare form: `install()` alone is too common a name.
install_calls <- c("remotes::install_github" = "github", "devtools::install_github" = "github",
                   "pak::pak" = "pak", "pak::pkg_install" = "pak",
                   "utils::install.packages" = "repos", "BiocManager::install" = "names")
install_calls_bare <- c(install_github = "github", pak = "pak", pkg_install = "pak",
                        install.packages = "repos")

#' Sources Ember knows without an install call: its own packages, which
#' aren't on CRAN. emberui (docs/inputs.md) goes here as
#' `"universe:jowch"` once its universe builds it; until then an entry
#' would send `library(emberui)` to a universe that doesn't have it.
builtin_sources <- stats::setNames(character(), character())

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
#' (`get(paste0("fit_", i))`) keeps the note, same as before. So does one
#' of them passed as a function (`lapply(names, get)`, walk.R).
untracked_reads <- c("get", "get0", "mget", "exists", "dynGet",
                     "eval", "evalq", "eval.parent")

#' Functions that read a data file, each with the argument that names it
#' (#276). A literal path there is watched as a `source()` path is: when
#' the file changes, the cell and its dependents rerun or go stale. Any
#' other value gets an `untracked_file` note. The argument is taken by
#' name (or as `file`, which `fread()` also takes), or else as the first
#' unnamed one.
data_readers <- c(
  # base and utils
  read.csv = "file", read.csv2 = "file", read.delim = "file", read.delim2 = "file",
  read.table = "file", read.fwf = "file", read.dcf = "file", readRDS = "file",
  load = "file", readLines = "con", scan = "file",
  # readr and vroom
  read_csv = "file", read_csv2 = "file", read_tsv = "file", read_delim = "file",
  read_table = "file", read_fwf = "file", read_lines = "file", read_file = "file",
  read_rds = "file", vroom = "file",
  # data.table, readxl, arrow, haven, jsonlite
  fread = "input", read_excel = "path", read_xlsx = "path", read_xls = "path",
  read_parquet = "file", read_feather = "file", read_ipc_file = "file",
  read_csv_arrow = "file", read_sav = "file", read_dta = "file", read_sas = "data_file",
  read_xpt = "file", read_json = "path")

#' Functions that write a file, each with the argument that names it and
#' its position (#276). They aren't watched: they tell the worker which
#' top-level expressions of a reading cell change its data files
#' themselves (`data_touch`), so that a change made by any other
#' expression while the cell runs is someone else's.
data_writers <- list(
  write.csv = list("file", 2L), write.csv2 = list("file", 2L), write.table = list("file", 2L),
  saveRDS = list("file", 2L), save = list("file", NA_integer_), writeLines = list("con", 2L),
  write_csv = list("file", 2L), write_csv2 = list("file", 2L), write_tsv = list("file", 2L),
  write_delim = list("file", 2L), write_rds = list("file", 2L), write_lines = list("file", 2L),
  write_file = list("file", 2L), fwrite = list("file", 2L), write_parquet = list("sink", 2L),
  write_feather = list("sink", 2L), write_xlsx = list("path", 2L), write_json = list("path", 2L),
  ggsave = list("filename", 1L), file.copy = list("to", 2L), file.rename = list("to", 2L),
  download.file = list("destfile", 2L))

#' The subset of `untracked_reads` whose name argument is checked for a
#' literal before falling back to the plain `untracked_read` note.
get_family_functions <- c("get", "get0", "exists", "mget", "dynGet")

#' Calls that take a function as an object to look at, not to call:
#' `args(get)` or `?get` reads no global through `get`, so a get-family
#' function that is a direct argument of one gets no note (#357).
function_object_heads <- c("?", "help", "args", "formals", "body",
                           "environment", "debug", "debugonce", "undebug",
                           "trace", "untrace", "identical", "bquote")

#' The get-family function `e` passes as a value, or `NULL`: a bare
#' `get` (unless a local binds it) or `base::get` / `base:::get` that isn't
#' being called (#357).
get_family_value <- function(e, scope) {
  if (is.symbol(e)) {
    name <- as.character(e)
    if (name %in% get_family_functions && !is_bound_locally(scope, name)) return(name)
    return(NULL)
  }
  if (is.call(e) && length(e) == 3 && is.symbol(e[[1]]) &&
      as.character(e[[1]]) %in% c("::", ":::") &&
      identical(as.character(e[[2]]), "base") &&
      as.character(e[[3]]) %in% get_family_functions) {
    return(as.character(e[[3]]))
  }
  NULL
}

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
#' can't take part in the duplicate check. `suffix` is appended to the
#' literal generic: `setReplaceMethod("r", ...)` is `setMethod("r<-", ...)`.
method_registrars <- list(
  registerS3method = c(generic = "genname", signature = "class", form = "register"),
  .S3method = c(generic = "generic", signature = "class", form = "register"),
  setMethod = c(generic = "f", signature = "signature", form = "s4"),
  setReplaceMethod = c(generic = "f", signature = "signature", form = "s4", suffix = "<-")
)

#' S4 class names written as strings. R keeps the definition of class `X`
#' in the global binding `.__C__X` (what `setClass("X")` creates, and what a
#' package's `exportClasses(X)` exports), so a string in a class position
#' is read as that name and resolves by the ordinary rules: to the cell
#' that defines the class, else to a cell attaching a package that exports
#' it. Each entry lists the function's leading formals, in order (for
#' matching positional arguments), and which of them hold class names:
#' `read` are classes the call needs, `define` the class it creates (at the
#' top level, or in `local()` nested there, like `setGeneric()`).
#' `slots` and `fields` name their classes only in named elements
#' (`slots = c(r = "numeric")`; `slots = c("r")` is a slot of class "ANY").
#' `setOldClass(c("lm2", "lm"))` defines its first class and reads the
#' rest, the S3 superclasses it names (`define_first`).
#' Slot and field classes, and the named elements of `representation()`,
#' are soft reads (`where = "slot"`): R doesn't need them until `new()`,
#' so they never make a cycle (`add_soft_edges()`). Every other class
#' position, `representation()`'s unnamed superclasses included, is a hard
#' read.
class_name_calls <- list(
  setClass = list(formals = c("Class", "representation", "prototype", "contains"),
                  define = "Class", read = c("representation", "contains", "slots")),
  setClassUnion = list(formals = c("name", "members"), define = "name", read = "members"),
  setRefClass = list(formals = c("Class", "fields", "contains"),
                     define = "Class", read = c("fields", "contains")),
  setValidity = list(formals = "Class", read = "Class"),
  setOldClass = list(formals = c("Classes", "prototype", "where", "test", "S4Class"),
                     define = "Classes", define_first = TRUE, read = "S4Class"),
  setMethod = list(formals = c("f", "signature"), read = "signature"),
  setReplaceMethod = list(formals = c("f", "signature"), read = "signature"),
  new = list(formals = "Class", read = "Class"),
  is = list(formals = c("object", "class2"), read = "class2"),
  as = list(formals = c("object", "Class"), read = "Class"),
  setAs = list(formals = c("from", "to"), read = c("from", "to")),
  getClass = list(formals = "Class", read = "Class"),
  getClassDef = list(formals = "Class", read = "Class"),
  slotNames = list(formals = "x", read = "x"),
  getSlots = list(formals = "x", read = "x"),
  extends = list(formals = c("class1", "class2"), read = c("class1", "class2")),
  isVirtualClass = list(formals = "Class", read = "Class"),
  existsMethod = list(formals = c("f", "signature"), read = "signature"),
  hasMethod = list(formals = c("f", "signature"), read = "signature"),
  getMethod = list(formals = c("f", "signature"), read = "signature"),
  selectMethod = list(formals = c("f", "signature"), read = "signature")
)

#' The arguments of `class_name_calls` that hold slot or field classes,
#' in their named elements only (unnamed ones are names of class "ANY").
class_slot_args <- c("slots", "fields")

#' The global name R keeps class `cls`'s definition in.
class_binding <- function(cls) paste0(".__C__", cls)

#' Is `name` a class definition's binding (`.__C__X`)? Those are public
#' despite the leading dot: they are how one cell's `setClass()` reaches
#' another cell's `new()`.
is_class_binding <- function(name) startsWith(name, ".__C__")

#' The class a `.__C__X` binding holds the definition of: `"X"`.
class_of_binding <- function(name) substring(name, nchar(".__C__") + 1)

#' Names as messages show them: a class binding (`.__C__Circle`) reads
#' "class Circle".
display_names <- function(names) {
  cls <- is_class_binding(names)
  names[cls] <- paste("class", class_of_binding(names[cls]))
  names
}

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
#' generics themselves (`Ops.money`, `Math.interval`) are in
#' `group_generics`.
s3_generics <- c(
  "-", "!", "!=", ".AtNames", ".DollarNames", "[", "[[", "[[<-", "[<-", "*",
  "/", "&", "%/%", "%%", "%*%", "^", "+", "<", "<=", "==", ">", ">=", "|", "$",
  "$<-", "@", "@<-", "abs", "acos", "acosh", "add1", "aggregate", "AIC", "alias", "all",
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
  "round", "row.names", "row.names<-", "rowsum", "rstandard", "rstudent", "scale",
  "screeplot", "se.contrast", "seek", "selfStart", "seq", "seq.int",
  "sequence", "sigma", "sign", "signif", "simulate", "sin", "sinh", "sinpi", "solve",
  "sort_by", "sortedXyData", "spineplot", "split", "split<-", "sqrt", "SSD",
  "stack", "start", "str", "stripchart", "subset", "sum", "summary",
  "sunflowerplot", "t", "t.test", "tail", "tan", "tanh", "tanpi", "terms",
  "text", "time", "toBibtex", "toLatex", "toString", "transform", "trigamma",
  "trunc", "truncate", "tsdiag", "tsSmooth", "TukeyHSD", "type.convert",
  "unique", "units", "units<-", "unlist", "unstack", "update", "upgrade",
  "var.test", "variable.names", "vcov", "weekdays", "weighted.mean",
  "weights", "wilcox.test", "window", "window<-", "with", "within", "xtfrm"
)

#' The group generics and their members, S3 (`?groupGeneric`) and S4
#' (`?S4groupGeneric`). A method of a group (`Ops.money`,
#' `setMethod("Arith", "Money", ...)`) runs for each member, so it feeds
#' every cell that reads one (#41).
group_generics <- local({
  arith <- c("+", "-", "*", "^", "%%", "%/%", "/")
  compare <- c("==", ">", "<", "!=", "<=", ">=")
  logic <- c("&", "|")
  math <- c("abs", "sign", "sqrt", "ceiling", "floor", "trunc", "cummax", "cummin",
            "cumprod", "cumsum", "exp", "expm1", "log", "log10", "log2", "log1p",
            "cos", "cosh", "sin", "sinh", "tan", "tanh", "acos", "acosh", "asin",
            "asinh", "atan", "atanh", "cospi", "sinpi", "tanpi", "gamma", "lgamma",
            "digamma", "trigamma")
  list(Ops = c(arith, compare, logic, "!"), Arith = arith, Compare = compare,
       Logic = logic, Math = c(math, "round", "signif"), Math2 = c("round", "signif"),
       Summary = c("max", "min", "range", "prod", "sum", "any", "all"),
       Complex = c("Arg", "Conj", "Im", "Mod", "Re"), matrixOps = "%*%")
})

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

#' Base R's data-masking calls (#107): each looks a name in its other
#' arguments up in its data first, and in the calling environment only
#' when the data has no such name. `data` is the data argument's names, in
#' the order R matches them (a named one, else the first unnamed one).
#' `frame` is `TRUE` when only a data frame masks (`subset()` and
#' `transform()` on anything else evaluate their arguments as usual);
#' `with()` and `within()` also mask with a plain list. The graph decides
#' per name, from the columns the data had when its cell last ran
#' (graph.R, `resolve_masked()`).
data_masking_calls <- list(
  subset = list(data = "x", frame = TRUE),
  transform = list(data = "_data", frame = TRUE),
  with = list(data = "data", frame = FALSE),
  within = list(data = "data", frame = FALSE)
)

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
#' Dot-names are private, except class bindings (`.__C__X`; see
#' `class_name_calls`). Used by the graph, never by the walker: the
#' walker records every name and the graph applies the policy, so the
#' analysis of a cell doesn't depend on which rule is in force.
is_private_name <- function(name) {
  startsWith(name, ".") & !is_class_binding(name)
}
