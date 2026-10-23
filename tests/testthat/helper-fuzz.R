# Test-only helpers for test-scheduling-fuzz.R: random notebooks, random
# edit sequences, and a check of every cell's output and stale mark after
# each step against a reference that runs the notebook from scratch.
#
# A trace is plain data, so a failure prints as one and replays exactly:
#   list(mode = "lazy", cells = list(A = "v1 <- 3", ...),
#        steps = list(list(ops = list(<op>, ...), run = NULL | "all" | id)))
# where an op is list(op = "set_code", cell, code), list(op = "insert",
# index, id, code), list(op = "delete", cell) or list(op = "move", cell,
# index). Cells only use names `v<n>`, numbers and base arithmetic, so the
# checker reads definitions and references with a regular expression and
# needs nothing from the generator.
#
# With `extras`, cells also write and read data files (`f<n>.txt`, through
# `writeLines()` and `readLines()`), define replacement functions
# (`` `s<n><-` ``, plain or an S3 generic with a default method in another
# cell) and call them (`s<n>(v) <- k`), and a step can change a file from
# outside the notebook: list(op = "outside", file, value).

# Generating ---------------------------------------------------------------

#' A random trace for `seed`: a notebook shaped as a chain, diamonds, a fan
#' or a random graph, then `steps` steps of one to three edits each and a
#' run of one cell, of every cell, or of nothing.
#'
#' With `conflicts = TRUE`, each step is one edit, and the edited or
#' inserted cell runs as if submitted. About one edit in three is one of
#' the ways code goes wrong (`fuzz_gen_conflict_op()`): a name defined in
#' two cells, a cycle, a parse error, a cell reading its own variable, or
#' the undoing of one of these.
#' Without it, a seed gives the same trace it always has.
#'
#' With `extras = TRUE`, cells write and read data files and define and call
#' replacement functions (`fuzz_add()`), and about one step in four also
#' rewrites a file from outside the notebook.
fuzz_trace <- function(seed, mode, steps = 12, cells = 6, conflicts = FALSE, extras = FALSE) {
  with_seed(seed, {
    g <- fuzz_gen_new()
    g$extras <- extras
    g <- fuzz_gen_shape(g, sample(c("chain", "diamond", "fan", "random"), 1), cells)
    initial <- g$cells
    # Cell order in the file doesn't decide run order: shuffle it sometimes.
    others <- setdiff(names(initial), "S")
    order <- c("S", if (stats::runif(1) < 0.3) sample(others) else others)
    trace <- list(seed = seed, mode = mode, conflicts = conflicts,
                  cells = lapply(initial[order], `[[`, "code"), steps = list())
    if (extras) trace$extras <- TRUE
    g$order <- order
    for (s in seq_len(steps)) {
      if (conflicts) {
        # One edit per step, run as it is submitted, so no cell is left
        # edited but not run: staged edits are the plain trace's job (#175),
        # and here they would hide what a graph error does.
        out <- if (stats::runif(1) < 0.35) fuzz_gen_conflict_op(g) else fuzz_gen_op(g)
        g <- out$g
        op <- out$ops[[1]]
        run <- if (length(out$ops) > 1) "all"
          else if (op$op %in% c("set_code", "insert")) op$cell %||% op$id else NULL
        trace$steps[[s]] <- list(ops = out$ops, run = run)
        next
      }
      ops <- list()
      for (k in seq_len(sample(1:3, 1, prob = c(0.6, 0.3, 0.1)))) {
        out <- fuzz_gen_op(g)
        g <- out$g
        ops <- c(ops, out$ops)
      }
      if (extras && length(g$files) && stats::runif(1) < 0.25) {
        ops <- c(ops, list(list(op = "outside", file = sample(names(g$files), 1), value = sample.int(996, 1))))
      }
      live <- setdiff(g$order, "S")
      # Half the time after an edit, run something that reads the edited
      # cell: that is where a stale value can leak into a result (#169).
      edited <- intersect(unlist(lapply(ops, function(op) if (identical(op$op, "set_code")) op$cell)), live)
      below <- unique(unlist(lapply(edited, function(id) {
        fuzz_descendants(lapply(g$cells[live], `[[`, "code"), id)
      })))
      u <- stats::runif(1)
      run <- if (length(below) && stats::runif(1) < 0.5) sample(below, 1)
        else if (u < 0.6 && length(live)) sample(live, 1) else if (u < 0.8) "all" else NULL
      trace$steps[[s]] <- list(ops = ops, run = run)
    }
    trace
  })
}

with_seed <- function(seed, expr) {
  old <- if (exists(".Random.seed", globalenv())) get(".Random.seed", globalenv())
  on.exit(if (is.null(old)) rm(".Random.seed", envir = globalenv())
          else assign(".Random.seed", old, globalenv()))
  set.seed(seed)
  expr
}

fuzz_gen_new <- function() {
  list(cells = list(S = list(code = "", rank = 0, defs = character(), refs = character())),
       order = "S", next_name = 1L, next_id = 1L, extras = FALSE,
       files = list(), next_file = 1L, setters = list(), next_setter = 1L)
}

fuzz_fresh_names <- function(g, n) {
  names <- if (n) paste0("v", g$next_name + seq_len(n) - 1L) else character()
  g$next_name <- g$next_name + n
  list(g = g, names = names)
}

#' Code for a cell. One definition `v <- expr`; two, where the second uses
#' the first; or none, a cell that only shows a value. One cell in ten fails.
fuzz_code <- function(defs, refs, fail = FALSE, files = character()) {
  k <- sample.int(90, 1)
  reads <- c(refs, sprintf('as.numeric(readLines("%s"))', files))
  terms <- if (length(reads)) paste0(seq_along(reads), " * ", reads, collapse = " + ") else NULL
  expr <- if (is.null(terms)) as.character(k) else sprintf("(%d + %s) %%%% 997", k, terms)
  if (fail) expr <- sprintf('stop("fail %d")', k)
  if (!length(defs)) return(expr)
  lines <- sprintf("%s <- %s", defs[1], expr)
  if (length(defs) > 1) lines <- c(lines, sprintf("%s <- (%s * 3 + %d) %%%% 997", defs[2], defs[1], k))
  paste(lines, collapse = "\n")
}

fuzz_cell <- function(defs, refs, rank) {
  list(code = fuzz_code(defs, refs, fail = stats::runif(1) < 0.1),
       rank = rank, defs = defs, refs = refs)
}

#' A cell's code with its extras (`fuzz_add()`): a replacement function it
#' defines, or around fuzz_code(), the files it reads, a replacement call on
#' its last name, and the file it writes that name to. Either of the last
#' two ends the cell with that name, so its output stays the name's value.
fuzz_cell_code <- function(c, fail = FALSE) {
  k <- sample.int(90, 1)
  if (!is.null(c$setter)) {
    terms <- paste0(vapply(c$refs, function(r) paste0(" + ", r), ""), collapse = "")
    return(switch(c$setter_kind,
      plain = sprintf("`%s<-` <- function(x, value) (x * %d + value%s) %%%% 997\n%d", c$setter, k %% 7 + 2, terms, k),
      generic = sprintf("`%s<-` <- function(x, value) UseMethod(\"%s<-\")\n%d", c$setter, c$setter, k),
      method = sprintf("`%s<-.default` <- function(x, value) (x * %d + value) %%%% 997\n%d", c$setter, k %% 7 + 2, k)))
  }
  lines <- fuzz_code(c$defs, c$refs, fail, files = c$reads %||% character())
  if (!length(c$defs) || (is.null(c$uses) && is.null(c$writes))) return(lines)
  last <- c$defs[length(c$defs)]
  paste(c(lines,
          if (!is.null(c$uses)) sprintf("%s(%s) <- %d", c$uses, last, k),
          if (!is.null(c$writes)) sprintf('writeLines(as.character(%s), "%s")', last, c$writes),
          last), collapse = "\n")
}

#' Give a new cell of `rank` its extras, drawing only from cells ranked
#' below it, as names are, so no path through files or replacement
#' functions makes a cycle: one cell in eight defines a replacement
#' function (with no names of its own), and the rest may read a file, call
#' a replacement function on their last name, and write that name to a new
#' file.
fuzz_extras <- function(g, c) {
  below <- function(ids) Filter(function(id) !is.null(g$cells[[id]]) && g$cells[[id]]$rank < c$rank, ids)
  if (stats::runif(1) < 0.12) {
    generics <- Filter(function(s) identical(g$setters[[s]]$kind, "generic") && is.null(g$setters[[s]]$method),
                       names(g$setters))
    if (length(generics) && stats::runif(1) < 0.5) {
      s <- sample(generics, 1)
      g$setters[[s]]$method <- TRUE
      c$setter <- s; c$setter_kind <- "method"
    } else {
      s <- paste0("s", g$next_setter)
      g$next_setter <- g$next_setter + 1L
      c$setter <- s; c$setter_kind <- if (stats::runif(1) < 0.4) "generic" else "plain"
      g$setters[[s]] <- list(kind = c$setter_kind, rank = c$rank)
    }
    c$defs <- character()
    if (c$setter_kind != "plain") c$refs <- character()
    return(list(g = g, c = c))
  }
  files <- names(g$files)[vapply(g$files, function(w) w < c$rank, TRUE)]
  if (length(files) && stats::runif(1) < 0.35) c$reads <- sample(files, 1)
  setters <- names(g$setters)[vapply(g$setters, function(s) s$rank < c$rank, TRUE)]
  if (length(c$defs) && length(setters) && stats::runif(1) < 0.35) c$uses <- sample(setters, 1)
  if (length(c$defs) && stats::runif(1) < 0.3) {
    f <- paste0("f", g$next_file, ".txt")
    g$next_file <- g$next_file + 1L
    g$files[[f]] <- c$rank
    c$writes <- f
  }
  list(g = g, c = c)
}

#' Names defined by cells ranked below `rank`: a cell only refers to those,
#' so the graph never has a cycle.
fuzz_names_below <- function(g, rank) {
  unlist(lapply(g$cells, function(c) if (c$rank < rank) c$defs), use.names = FALSE)
}

fuzz_pick_refs <- function(g, rank, n = sample(0:3, 1, prob = c(0.15, 0.45, 0.3, 0.1))) {
  pool <- fuzz_names_below(g, rank)
  if (!length(pool)) return(character())
  sample(pool, min(n, length(pool)))
}

fuzz_add <- function(g, refs, ndefs = sample(0:2, 1, prob = c(0.2, 0.55, 0.25)), rank = NULL) {
  if (is.null(rank)) rank <- max(vapply(g$cells, `[[`, 0, "rank")) + 1
  id <- paste0("C", g$next_id)
  g$next_id <- g$next_id + 1L
  fresh <- fuzz_fresh_names(g, ndefs)
  g <- fresh$g
  g$cells[[id]] <- fuzz_cell(fresh$names, refs, rank)
  if (isTRUE(g$extras)) {
    # A shape's next cell reads the last one's first name, and a cell that
    # defines a replacement function has none.
    g$cells[[id]]$refs <- refs[!is.na(refs)]
    out <- fuzz_extras(g, g$cells[[id]])
    g <- out$g
    out$c$code <- fuzz_cell_code(out$c, fail = stats::runif(1) < 0.1 && is.null(out$c$setter))
    g$cells[[id]] <- out$c
  }
  list(g = g, id = id)
}

fuzz_gen_shape <- function(g, shape, n) {
  last_defs <- function(id) g$cells[[id]]$defs
  ids <- character()
  add <- function(refs, ndefs = 1) {
    out <- fuzz_add(g, refs, ndefs)
    g <<- out$g
    ids <<- c(ids, out$id)
    out$id
  }
  if (shape == "chain") {
    prev <- add(character())
    for (i in seq_len(n - 1)) prev <- add(last_defs(prev)[1], ndefs = sample(1:2, 1))
  } else if (shape == "diamond") {
    top <- add(character())
    while (length(ids) < n) {
      l <- add(last_defs(top)[1]); r <- add(last_defs(top)[1])
      top <- add(c(last_defs(l)[1], last_defs(r)[1]))
    }
  } else if (shape == "fan") {
    root <- add(character(), ndefs = 2)
    mids <- vapply(seq_len(max(1, n - 2)), function(i) add(sample(last_defs(root), 1)), "")
    add(vapply(mids, function(m) last_defs(m)[1], ""), ndefs = 0)
  } else {
    for (i in seq_len(n)) add(fuzz_pick_refs(g, Inf), ndefs = sample(0:2, 1, prob = c(0.2, 0.55, 0.25)))
  }
  g
}

#' One random edit: change a cell's code, rename one of its variables (and
#' sometimes its readers, in the same batch), delete, insert or move a cell.
fuzz_gen_op <- function(g) {
  live <- setdiff(g$order, "S")
  kind <- if (!length(live)) "insert" else
    sample(c("edit", "rename", "delete", "insert", "move"), 1, prob = c(0.4, 0.15, 0.15, 0.15, 0.15))
  set <- function(id, c) {
    g$cells[[id]] <<- c
    list(op = "set_code", cell = id, code = c$code)
  }
  if (kind == "edit") {
    id <- sample(live, 1)
    c <- g$cells[[id]]
    if (isTRUE(g$extras)) {
      # A generic or a method keeps its shape; the rest can read other names.
      if (stats::runif(1) < 0.5 && c$setter_kind %||% "plain" == "plain") c$refs <- fuzz_pick_refs(g, c$rank)
      if (is.null(c$setter) && stats::runif(1) < 0.3) {
        files <- names(g$files)[vapply(g$files, function(w) w < c$rank, TRUE)]
        c$reads <- if (length(files) && stats::runif(1) < 0.5) sample(files, 1)
      }
      c$code <- fuzz_cell_code(c, fail = stats::runif(1) < 0.1 && is.null(c$setter))
      return(list(g = g, ops = list(set(id, c))))
    }
    if (stats::runif(1) < 0.5) c$refs <- fuzz_pick_refs(g, c$rank)
    c$code <- fuzz_join(fuzz_code(c$defs, c$refs, fail = stats::runif(1) < 0.1), c)
    return(list(g = g, ops = list(set(id, c))))
  }
  if (kind == "rename") {
    has <- Filter(function(id) length(g$cells[[id]]$defs) > 0, live)
    if (!length(has)) return(fuzz_gen_op(g))
    id <- sample(has, 1)
    c <- g$cells[[id]]
    old <- sample(c$defs, 1)
    fresh <- fuzz_fresh_names(g, 1)
    g <- fresh$g
    new <- fresh$names
    c$defs[c$defs == old] <- new
    c$code <- gsub(paste0("\\b", old, "\\b"), new, c$code)
    c$extra <- gsub(paste0("\\b", old, "\\b"), new, c$extra)
    ops <- list(set(id, c))
    if (stats::runif(1) < 0.5) {
      for (r in Filter(function(r) old %in% g$cells[[r]]$refs, live)) {
        rc <- g$cells[[r]]
        rc$refs[rc$refs == old] <- new
        rc$code <- gsub(paste0("\\b", old, "\\b"), new, rc$code)
        rc$extra <- gsub(paste0("\\b", old, "\\b"), new, rc$extra)
        ops <- c(ops, list(set(r, rc)))
      }
    }
    return(list(g = g, ops = ops))
  }
  if (kind == "delete") {
    id <- sample(live, 1)
    g$cells[[id]] <- NULL
    g$order <- setdiff(g$order, id)
    return(list(g = g, ops = list(list(op = "delete", cell = id))))
  }
  if (kind == "insert") {
    ranks <- vapply(g$cells, `[[`, 0, "rank")
    rank <- stats::runif(1, 0.5, max(ranks) + 1)
    out <- fuzz_add(g, fuzz_pick_refs(g, rank), rank = rank)
    g <- out$g
    index <- sample.int(length(g$order) + 1, 1)
    g$order <- append(g$order, out$id, after = index - 1)
    return(list(g = g, ops = list(list(op = "insert", index = index, id = out$id,
                                       code = g$cells[[out$id]]$code))))
  }
  id <- sample(live, 1)
  index <- sample.int(length(g$order), 1)
  g$order <- append(setdiff(g$order, id), id, after = index - 1)
  list(g = g, ops = list(list(op = "move", cell = id, index = index)))
}

#' A cell's code with what conflict ops added to it: lines before it
#' (`c$extra`), and an unclosed bracket after it when `c$broken`. The extra
#' lines go first so the cell's last value, its output, stays its own.
fuzz_join <- function(code, c) {
  paste(c(c$extra, code, if (isTRUE(c$broken)) "("), collapse = "\n")
}

#' One edit that gives the notebook a graph error or a cell R can't run
#' the same way twice, or undoes one: define another cell's name again
#' (`v <- k`, or `v[1] <- k`, which also reads it), read a name a
#' dependent defines (a cycle), leave a bracket open, make a cell's first
#' line read its own variable (`v <- v + k`), or put a cell back as the
#' plain generator made it.
#'
#' No `rm()` of another cell's variable: Ember runs that cell and then
#' flags it ("changed a global defined elsewhere"), so what its readers see
#' follows file order, as in plain R, which the reference doesn't model.
fuzz_gen_conflict_op <- function(g) {
  live <- setdiff(g$order, "S")
  defined <- Filter(function(id) length(g$cells[[id]]$defs) > 0, live)
  if (length(live) < 2 || !length(defined)) return(fuzz_gen_op(g))
  kind <- sample(c("redefine", "replace", "cycle", "break", "self", "undo"), 1,
                 prob = c(0.15, 0.15, 0.15, 0.15, 0.15, 0.25))
  k <- sample.int(90, 1)
  set <- function(id, c) {
    g$cells[[id]] <- c
    list(g = g, ops = list(list(op = "set_code", cell = id, code = c$code)))
  }
  if (kind == "undo") {
    marked <- Filter(function(id) {
      c <- g$cells[[id]]
      length(c$extra) || isTRUE(c$broken) || isTRUE(c$self)
    }, live)
    if (!length(marked)) return(fuzz_gen_op(g))
    id <- sample(marked, 1)
    c <- g$cells[[id]]
    c$extra <- character(); c$broken <- FALSE; c$self <- FALSE
    c$code <- fuzz_code(c$defs, c$refs)
    return(set(id, c))
  }
  if (kind == "break") {
    id <- sample(live, 1)
    c <- g$cells[[id]]
    if (isTRUE(c$broken)) return(fuzz_gen_op(g))
    c$broken <- TRUE
    c$code <- paste0(c$code, "\n(")
    return(set(id, c))
  }
  if (kind == "self") {
    id <- sample(defined, 1)
    c <- g$cells[[id]]
    v <- c$defs[1]
    c$self <- TRUE
    c$code <- fuzz_join(sub(paste0("^", v, " <- (.*)$"), paste0(v, " <- (\\1 + ", v, ") %% 997"),
                            strsplit(fuzz_code(c$defs, c$refs), "\n")[[1]][1]), c)
    if (length(c$defs) > 1) c$code <- paste(c(c$code, sprintf("%s <- (%s * 3 + %d) %%%% 997", c$defs[2], c$defs[1], k)), collapse = "\n")
    return(set(id, c))
  }
  if (kind == "cycle") {
    codes <- lapply(g$cells[live], `[[`, "code")
    id <- sample(defined, 1)
    below <- Filter(function(d) length(fuzz_defs(codes[[d]])) > 0, fuzz_descendants(codes, id))
    if (!length(below)) return(fuzz_gen_op(g))
    d <- sample(below, 1)
    name <- sample(fuzz_defs(codes[[d]]), 1)
    c <- g$cells[[id]]
    c$extra <- c(c$extra, sprintf("%s + %d", name, k))
    c$code <- paste(c(sprintf("%s + %d", name, k), c$code), collapse = "\n")
    return(set(id, c))
  }
  # redefine, replace: another cell assigns a name `owner` defines.
  owner <- sample(defined, 1)
  name <- sample(g$cells[[owner]]$defs, 1)
  id <- sample(setdiff(live, owner), 1)
  line <- switch(kind,
    redefine = sprintf("%s <- %d", name, k),
    replace = sprintf("%s[1] <- %d", name, k))
  c <- g$cells[[id]]
  c$extra <- c(c$extra, line)
  c$code <- paste(c(line, c$code), collapse = "\n")
  set(id, c)
}

# Reading cells ------------------------------------------------------------

fuzz_defs <- function(code) {
  m <- regmatches(code, gregexpr("(?m)^v[0-9]+(?=(\\[[^]\n]*\\])? <-)", code, perl = TRUE))[[1]]
  # A replacement function or its default method: `s1<-`, `s1<-.default`.
  f <- regmatches(code, gregexpr("(?m)^`s[0-9]+<-(\\.default)?(?=` <-)", code, perl = TRUE))[[1]]
  unique(c(m, substring(f, 2)))
}

#' Names `code` reads from other cells: every name in it but those it
#' assigns whole. A replacement (`v[1] <- k`) reads the old value.
fuzz_refs <- function(code) {
  m <- regmatches(code, gregexpr("\\bv[0-9]+\\b", code, perl = TRUE))[[1]]
  whole <- regmatches(code, gregexpr("(?m)^v[0-9]+(?= <-)", code, perl = TRUE))[[1]]
  # `s1(v) <- k` runs `s1<-`, and through it the method another cell defines.
  calls <- regmatches(code, gregexpr("(?m)^s[0-9]+(?=\\()", code, perl = TRUE))[[1]]
  setters <- if (length(calls)) c(paste0(calls, "<-"), paste0(calls, "<-.default"))
  setdiff(unique(c(m, setters)), whole)
}

#' What `code` reads among `codes`: fuzz_refs(), less a default method
#' whose generic no cell defines. Ember counts `s1<-.default` as a method
#' only while a cell defines `s1<-` (design.md, "What counts"); otherwise
#' it is just a function, and calling `s1()` doesn't read it.
fuzz_refs_in <- function(codes, code) {
  refs <- fuzz_refs(code)
  methods <- grep("<-\\.default$", refs, value = TRUE)
  if (!length(methods)) return(refs)
  defined <- unlist(lapply(codes, fuzz_defs), use.names = FALSE)
  setdiff(refs, methods[!sub("\\.default$", "", methods) %in% defined])
}

#' Cells in an order where each comes after the cells defining what it
#' reads. `codes` is a named list of code; the graph is acyclic by
#' construction, so anything left over is a bug in the harness.
fuzz_topo <- function(codes) {
  definer <- list()
  for (id in names(codes)) for (d in fuzz_defs(codes[[id]])) definer[[d]] <- id
  ups <- lapply(names(codes), function(id) {
    setdiff(unique(unlist(lapply(fuzz_refs_in(codes, codes[[id]]), function(r) definer[[r]]), use.names = FALSE)), id)
  })
  names(ups) <- names(codes)
  out <- character()
  left <- names(codes)
  while (length(left)) {
    ready <- left[vapply(left, function(id) all(ups[[id]] %in% out), TRUE)]
    if (!length(ready)) stop("harness bug: cycle among ", paste(left, collapse = ", "))
    out <- c(out, ready)
    left <- setdiff(left, ready)
  }
  out
}

#' The cells of `codes` that can't run whatever the order, by why: code
#' that doesn't parse, a name defined in two cells, or a cell that reads,
#' through other cells, a name it defines itself (a cycle). A named list,
#' id -> "parse", "multiple_definitions" or "cycle". A cell that doesn't
#' parse defines nothing, as far as the others are concerned.
fuzz_blocked <- function(codes) {
  out <- list()
  parses <- vapply(codes, function(code) {
    !inherits(try(parse(text = code, keep.source = FALSE), silent = TRUE), "try-error")
  }, TRUE)
  for (id in names(codes)[!parses]) out[[id]] <- "parse"
  codes <- codes[parses]
  defs <- lapply(codes, fuzz_defs)
  all <- unlist(defs, use.names = FALSE)
  dup <- unique(all[duplicated(all)])
  for (id in names(codes)) {
    if (any(defs[[id]] %in% dup)) out[[id]] <- "multiple_definitions"
    if (fuzz_on_cycle(codes, id)) out[[id]] <- "cycle"
  }
  out
}

fuzz_on_cycle <- function(codes, id) {
  definers <- function(r) names(codes)[vapply(codes, function(code) r %in% fuzz_defs(code), TRUE)]
  seen <- character()
  todo <- id
  while (length(todo)) {
    c <- todo[1]; todo <- todo[-1]
    # A cell replacing part of a name only it defines reads its own value.
    ups <- setdiff(unique(unlist(lapply(fuzz_refs_in(codes, codes[[c]]), definers), use.names = FALSE)), c)
    if (id %in% ups) return(TRUE)
    new <- setdiff(ups, seen)
    seen <- c(seen, new)
    todo <- c(todo, new)
  }
  FALSE
}

#' Every cell `id` reads from, directly or not, in `codes`.
fuzz_ancestors <- function(codes, id) {
  definer <- list()
  for (c in names(codes)) for (d in fuzz_defs(codes[[c]])) definer[[d]] <- c
  seen <- character()
  todo <- id
  while (length(todo)) {
    c <- todo[1]; todo <- todo[-1]
    ups <- unlist(lapply(fuzz_refs_in(codes, codes[[c]]), function(r) definer[[r]]), use.names = FALSE)
    new <- setdiff(ups, c(seen, id))
    seen <- c(seen, new)
    todo <- c(todo, new)
  }
  seen
}

fuzz_descendants <- function(codes, id) {
  Filter(function(c) id %in% fuzz_ancestors(codes, c), setdiff(names(codes), id))
}

# The reference ------------------------------------------------------------

#' Run `codes` from scratch, in dependency order, in a new environment:
#' what each cell's status and output should be. As in Ember, a cell's
#' output is its last top-level value, and a failed cell's variables are
#' removed. A cell that can't run (`fuzz_blocked()`) is an error and
#' defines nothing. Cells that don't depend on each other run in the order
#' of `codes`, which callers give in display order.
#'
#' With `dir`, the cells run there and read its data files as they are now:
#' Ember doesn't order a writer before its readers (design.md, "Data files
#' a cell reads"), it reruns or marks a reader once the file changes, so a
#' reader that isn't stale shows what the file holds. Writes do nothing.
fuzz_reference <- function(codes, dir = NULL) {
  env <- new.env(parent = baseenv())
  if (!is.null(dir)) {
    env$writeLines <- function(...) invisible(NULL)
    old <- setwd(dir)
    on.exit(setwd(old), add = TRUE)
  }
  out <- list()
  blocked <- fuzz_blocked(codes)
  for (id in names(blocked)) out[[id]] <- list(status = "error", text = NULL)
  codes <- codes[setdiff(names(codes), names(blocked))]
  for (id in fuzz_topo(codes)) {
    code <- codes[[id]]
    if (!nzchar(code)) { out[[id]] <- list(status = "ok", text = NULL); next }
    res <- tryCatch({
      val <- NULL
      for (e in parse(text = code, keep.source = FALSE)) val <- suppressWarnings(eval(e, env))
      list(status = "ok", text = paste(utils::capture.output(print(val)), collapse = "\n"))
    }, error = function(e) {
      rm(list = intersect(fuzz_defs(code), ls(env)), envir = env)
      list(status = "error", text = NULL)
    })
    out[[id]] <- res
  }
  out
}

# Replaying and checking ---------------------------------------------------

#' Apply one op. An op naming a cell that isn't there (a shrunk trace can
#' drop the insert that made it) is skipped, and indexes are clamped.
fuzz_apply <- function(nb, op) {
  ids <- vapply(notebook_snapshot(nb)$cells, `[[`, "", "id")
  if (!is.null(op$cell) && !op$cell %in% ids) return(invisible())
  if (!is.null(op$index)) {
    op$index <- min(op$index, length(ids) + identical(op$op, "insert"))
  }
  if (identical(op$op, "outside")) {
    # Always a change: a value the file doesn't hold already.
    path <- file.path(dirname(nb$state$path), op$file)
    new <- as.character(op$value)
    if (file.exists(path) && identical(readLines(path, warn = FALSE), new)) new <- as.character(op$value + 1)
    writeLines(new, path)
    return(invisible())
  }
  e <- switch(op$op,
    set_code = set_code(op$cell, op$code),
    insert = insert_cell(op$index, op$code, id = op$id),
    delete = delete_cell(op$cell),
    move = move_cell(op$cell, op$index))
  edit_notebook(nb, e)
}

#' Replay `trace` in a real worker and check it after every step. Returns
#' NULL, or the first failure: list(step, problems).
fuzz_replay <- function(trace, timeout = 30) {
  cells <- lapply(trace$cells, cell)
  cells <- c(list(S = cell("")), cells[setdiff(names(cells), "S")])
  nb <- open_notebook(write_session_notebook(cells, on_cell_change = trace$mode))
  on.exit(close_notebook(nb), add = TRUE)
  # The code each cell last ran, which is what its output came from, and
  # whether that run succeeded.
  ran <- list()
  ran_ok <- list()
  last <- list()
  dir <- if (isTRUE(trace$extras)) dirname(nb$state$path)
  for (s in seq_along(trace$steps)) {
    step <- trace$steps[[s]]
    for (op in step$ops) {
      before <- notebook_snapshot(nb)
      ok <- tryCatch({ fuzz_apply(nb, op); TRUE }, error = function(e) conditionMessage(e))
      if (!isTRUE(ok)) return(list(step = s, problems = paste("edit refused:", ok)))
      if (identical(op$op, "outside") && !fuzz_noticed(nb, before, ran, op$file, timeout)) {
        return(list(step = s, problems = paste0("a reader of ", op$file, " never noticed it change")))
      }
    }
    res <- NULL
    if (!is.null(step$run) && (identical(step$run, "all") ||
                               step$run %in% vapply(notebook_snapshot(nb)$cells, `[[`, "", "id"))) {
      ids <- if (identical(step$run, "all")) NULL else step$run
      res <- run_cells(nb, ids, wait = TRUE, timeout = timeout)
    }
    if (!wait_for(nb, is_idle, timeout = timeout)) {
      return(list(step = s, problems = "the notebook never went idle"))
    }
    snap <- notebook_snapshot(nb)
    for (v in snap$cells) {
      if (!identical(v$last_run, last[[v$id]])) {
        ran[[v$id]] <- v$code
        ran_ok[[v$id]] <- identical(v$status, "ok")
      }
    }
    last <- stats::setNames(lapply(snap$cells, `[[`, "last_run"), vapply(snap$cells, `[[`, "", "id"))
    ran <- ran[intersect(names(ran), names(last))]
    ran_ok <- ran_ok[intersect(names(ran_ok), names(last))]
    problems <- fuzz_check(snap, ran, trace$mode, step$run, res, ran_ok, dir)
    if (length(problems)) return(list(step = s, problems = problems))
    # A cell whose result is gone defines nothing as far as Ember's next
    # submit of it goes (drop_graph_error_results() reads `old$defined`
    # only from a result it still holds).
    for (v in snap$cells) if (!v$status %in% c("ok", "error")) ran_ok[[v$id]] <- FALSE
  }
  NULL
}

#' Wait until every cell whose last run read `file` and that has a result
#' has taken in its change from outside: it is stale, queued or running, or
#' has run again since `before`. A cell edited since it ran is left out:
#' Ember watches what its code reads now, and it already shows as edited. The shell sees the change on its poll, so
#' this is what waiting for the notebook means after a file changes. FALSE
#' if one hasn't within `timeout` seconds.
fuzz_noticed <- function(nb, before, ran, file, timeout) {
  last <- stats::setNames(lapply(before$cells, `[[`, "last_run"), vapply(before$cells, `[[`, "", "id"))
  pattern <- sprintf('readLines("%s")', file)
  readers <- names(Filter(function(code) grepl(pattern, code, fixed = TRUE), ran))
  edited <- vapply(before$cells, function(v) isTRUE(v$code_differs), TRUE)
  readers <- Filter(function(id) !is.null(last[[id]]) && !id %in% vapply(before$cells, `[[`, "", "id")[edited], readers)
  if (!length(readers)) return(TRUE)
  wait_for(nb, function(snap) {
    views <- stats::setNames(snap$cells, vapply(snap$cells, `[[`, "", "id"))
    all(vapply(readers, function(id) {
      v <- views[[id]]
      is.null(v) || isTRUE(v$stale) || isTRUE(v$code_differs) || v$queued || v$running ||
        !identical(v$last_run, last[[id]])
    }, TRUE))
  }, timeout = timeout)
}

#' What's wrong with `snap`, as sentences; empty when nothing is.
#' `dir` is the notebook's folder when cells read data files.
fuzz_check <- function(snap, ran, mode, run, res, ran_ok = list(), dir = NULL) {
  problems <- character()
  say <- function(...) problems <<- c(problems, paste0(...))
  views <- stats::setNames(snap$cells, vapply(snap$cells, `[[`, "", "id"))
  views <- views[names(views) != "S"]
  current <- lapply(views, `[[`, "code")
  has_run <- function(v) v$status %in% c("ok", "error")

  if (!is.null(res) && isTRUE(res$timed_out)) say("the run timed out")

  # A cell that can't run shows why, and one that can shows no such error.
  blocked <- names(fuzz_blocked(current))
  graph_kinds <- c("parse", "multiple_definitions", "cycle")
  for (id in names(views)) {
    kinds <- vapply(views[[id]]$errors, `[[`, "", "kind")
    if (id %in% blocked && !any(kinds %in% graph_kinds)) say(id, " can't run but shows no graph error")
    if (!id %in% blocked && any(kinds %in% graph_kinds)) say(id, " can run but shows a graph error")
    # Once it is submitted, or every cell is run, it has no result left
    # (drop_graph_error_results()).
    if (id %in% blocked && (identical(run, id) || identical(run, "all")) && has_run(views[[id]])) {
      say(id, " can't run but still shows a result (", views[[id]]$status, ")")
    }
  }

  # Every output not marked stale is what running the code behind the
  # outputs from scratch gives, so the reference uses the code each cell
  # ran. A cell edited since it ran keeps its old output, marked as edited.
  shown <- Filter(function(id) has_run(views[[id]]) && !is.null(ran[[id]]), names(views))
  ref <- fuzz_reference(ran[shown], dir)
  for (id in shown) {
    v <- views[[id]]
    # A cell that can't run now keeps its last output under its graph error
    # until something runs (drop_graph_error_results()): it is marked.
    if (isTRUE(v$stale) || id %in% blocked) next
    # An edited cell's output, from code that read a file, isn't watched
    # (fuzz_noticed()).
    if (isTRUE(v$code_differs) && grepl("readLines(", ran[[id]], fixed = TRUE)) next
    reads <- fuzz_ancestors(ran[shown], id)
    want <- ref[[id]]
    got <- v$output$text
    if (!identical(v$status, want$status)) {
      say(id, " shows ", v$status, " but running from scratch gives ", want$status)
    } else if (identical(want$status, "ok") && !identical(got, want$text)) {
      say(id, " shows ", deparse(got), " but running from scratch gives ", deparse(want$text))
    }
    # Nothing it read from may be stale either.
    for (a in reads) {
      if (isTRUE(views[[a]]$stale)) say(id, " isn't stale but reads from ", a, ", which is")
    }
  }

  # In lazy mode a reader can be left stale by a run: a writer isn't an
  # upstream of its readers (design.md, "Data files a cell reads"), so a run
  # can read a file before the cell that writes it, which then marks the
  # reader stale. Autorun reruns it instead. So is what reads from it.
  excused <- character()
  if (identical(mode, "lazy")) {
    readers <- Filter(function(id) !is.null(ran[[id]]) && grepl("readLines(", ran[[id]], fixed = TRUE) &&
                        isTRUE(views[[id]]$stale), names(views))
    excused <- unique(c(readers, unlist(lapply(readers, function(r) fuzz_descendants(current, r)))))
  }
  # A cell that can't run is never fresh, and isn't expected to be.
  fresh <- function(id) {
    v <- views[[id]]
    id %in% blocked || id %in% excused || (has_run(v) && !isTRUE(v$stale) && !isTRUE(v$code_differs))
  }
  if (identical(run, "all")) {
    for (id in names(views)) if (!fresh(id)) say("after running every cell, ", id, " isn't fresh")
  } else if (!is.null(run) && run %in% names(views)) {
    # Only cells that can run are between two others: a path through one
    # that can't isn't a path anything runs along. The cell run may be one
    # that can't: it is submitted all the same.
    open <- current[setdiff(names(current), setdiff(blocked, run))]
    if (!fresh(run)) say("after running ", run, ", it isn't fresh")
    if (!run %in% blocked) {
      for (a in fuzz_ancestors(open, run)) {
        if (!fresh(a)) say("after running ", run, ", its ancestor ", a, " isn't fresh")
      }
    }
    # Autorun reruns the dependents that have a result; one that never ran
    # stays not run (step.R, invalidate_dependents()). Those of a cell
    # submitted with a graph error rerun too, and fail if they need it
    # (engine.md: a dependent of a graph-broken cell runs and fails). Its
    # dependents there are the readers of what it defined when it last ran
    # (nothing, if that run failed) and of what its code defines now
    # (nothing, if it doesn't parse), and what depends on them (#337).
    if (identical(mode, "autorun")) {
      deps <- if (run %in% blocked) {
        names <- character()
        if (!identical(fuzz_blocked(current[run])[[run]], "parse")) names <- fuzz_defs(current[[run]])
        if (isTRUE(ran_ok[[run]])) names <- union(names, fuzz_defs(ran[[run]]))
        readers <- Filter(function(c) length(intersect(fuzz_refs(open[[c]]), names)) > 0,
                          setdiff(names(open), run))
        unique(c(readers, unlist(lapply(readers, function(c) fuzz_descendants(open, c)))))
      } else fuzz_descendants(open, run)
      for (d in setdiff(deps, blocked)) {
        if (has_run(views[[d]]) && !fresh(d)) {
          if (run %in% blocked) say("after submitting ", run, " with a graph error in autorun, its dependent ", d, " isn't fresh")
          else say("after running ", run, " in autorun, its dependent ", d, " isn't fresh")
        }
      }
    }
  }
  unique(problems)
}

# Reporting and shrinking --------------------------------------------------

#' A trace as R code that rebuilds it, for a failure message or a
#' regression test.
fuzz_format <- function(trace) {
  paste(deparse(trace[intersect(c("mode", "extras", "cells", "steps"), names(trace))], width.cutoff = 100), collapse = "\n")
}

#' A problem without its cell ids and values, so shrinking keeps the same
#' kind of failure rather than drifting to another one.
fuzz_kind <- function(problems) {
  unique(gsub('"[^"]*"|\\bC[0-9]+\\b', "_", problems))
}

#' Make a failing trace smaller while it still fails the same way: drop
#' whole steps, then single edits, then runs, then cells it starts with
#' (and the edits that name them).
fuzz_shrink <- function(trace, fails = NULL) {
  if (is.null(fails)) {
    kinds <- fuzz_kind(fuzz_replay(trace)$problems)
    fails <- function(t) {
      f <- fuzz_replay(t)
      !is.null(f) && length(intersect(fuzz_kind(f$problems), kinds)) > 0
    }
  }
  try_drop <- function(t, candidates) {
    for (cand in candidates) if (!is.null(cand) && fails(cand)) return(cand)
    NULL
  }
  repeat {
    smaller <- NULL
    n <- length(trace$steps)
    smaller <- try_drop(trace, lapply(rev(seq_len(n)), function(i) {
      t <- trace; t$steps <- t$steps[-i]; t
    }))
    if (is.null(smaller)) {
      cands <- list()
      for (i in seq_len(n)) for (j in seq_along(trace$steps[[i]]$ops)) {
        t <- trace; t$steps[[i]]$ops <- t$steps[[i]]$ops[-j]; cands <- c(cands, list(t))
      }
      for (i in seq_len(n)) if (!is.null(trace$steps[[i]]$run)) {
        t <- trace; t$steps[[i]]["run"] <- list(NULL); cands <- c(cands, list(t))
      }
      smaller <- try_drop(trace, cands)
    }
    if (is.null(smaller)) {
      smaller <- try_drop(trace, lapply(names(trace$cells), function(id) fuzz_without_cell(trace, id)))
    }
    if (is.null(smaller)) return(trace)
    trace <- smaller
  }
}

fuzz_without_cell <- function(trace, id) {
  trace$cells[[id]] <- NULL
  trace$steps <- lapply(trace$steps, function(s) {
    s$ops <- Filter(function(op) !identical(op$cell, id), s$ops)
    if (identical(s$run, id)) s["run"] <- list(NULL)
    s
  })
  trace
}
