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

# Generating ---------------------------------------------------------------

#' A random trace for `seed`: a notebook shaped as a chain, diamonds, a fan
#' or a random graph, then `steps` steps of one to three edits each and a
#' run of one cell, of every cell, or of nothing.
fuzz_trace <- function(seed, mode, steps = 12, cells = 6) {
  with_seed(seed, {
    g <- fuzz_gen_new()
    g <- fuzz_gen_shape(g, sample(c("chain", "diamond", "fan", "random"), 1), cells)
    initial <- g$cells
    # Cell order in the file doesn't decide run order: shuffle it sometimes.
    others <- setdiff(names(initial), "S")
    order <- c("S", if (stats::runif(1) < 0.3) sample(others) else others)
    trace <- list(seed = seed, mode = mode,
                  cells = lapply(initial[order], `[[`, "code"), steps = list())
    g$order <- order
    for (s in seq_len(steps)) {
      ops <- list()
      for (k in seq_len(sample(1:3, 1, prob = c(0.6, 0.3, 0.1)))) {
        out <- fuzz_gen_op(g)
        g <- out$g
        ops <- c(ops, out$ops)
      }
      live <- setdiff(g$order, "S")
      u <- stats::runif(1)
      run <- if (u < 0.6 && length(live)) sample(live, 1) else if (u < 0.8) "all" else NULL
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
       order = "S", next_name = 1L, next_id = 1L)
}

fuzz_fresh_names <- function(g, n) {
  names <- if (n) paste0("v", g$next_name + seq_len(n) - 1L) else character()
  g$next_name <- g$next_name + n
  list(g = g, names = names)
}

#' Code for a cell. One definition `v <- expr`; two, where the second uses
#' the first; or none, a cell that only shows a value. One cell in ten fails.
fuzz_code <- function(defs, refs, fail = FALSE) {
  k <- sample.int(90, 1)
  terms <- if (length(refs)) paste0(seq_along(refs), " * ", refs, collapse = " + ") else NULL
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
    if (stats::runif(1) < 0.5) c$refs <- fuzz_pick_refs(g, c$rank)
    c$code <- fuzz_code(c$defs, c$refs, fail = stats::runif(1) < 0.1)
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
    ops <- list(set(id, c))
    if (stats::runif(1) < 0.5) {
      for (r in Filter(function(r) old %in% g$cells[[r]]$refs, live)) {
        rc <- g$cells[[r]]
        rc$refs[rc$refs == old] <- new
        rc$code <- gsub(paste0("\\b", old, "\\b"), new, rc$code)
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

# Reading cells ------------------------------------------------------------

fuzz_defs <- function(code) {
  m <- regmatches(code, gregexpr("(?m)^v[0-9]+(?= <-)", code, perl = TRUE))[[1]]
  unique(m)
}

fuzz_refs <- function(code) {
  m <- regmatches(code, gregexpr("\\bv[0-9]+\\b", code, perl = TRUE))[[1]]
  setdiff(unique(m), fuzz_defs(code))
}

#' Cells in an order where each comes after the cells defining what it
#' reads. `codes` is a named list of code; the graph is acyclic by
#' construction, so anything left over is a bug in the harness.
fuzz_topo <- function(codes) {
  definer <- list()
  for (id in names(codes)) for (d in fuzz_defs(codes[[id]])) definer[[d]] <- id
  ups <- lapply(codes, function(code) {
    unique(unlist(lapply(fuzz_refs(code), function(r) definer[[r]]), use.names = FALSE))
  })
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

#' Every cell `id` reads from, directly or not, in `codes`.
fuzz_ancestors <- function(codes, id) {
  definer <- list()
  for (c in names(codes)) for (d in fuzz_defs(codes[[c]])) definer[[d]] <- c
  seen <- character()
  todo <- id
  while (length(todo)) {
    c <- todo[1]; todo <- todo[-1]
    ups <- unlist(lapply(fuzz_refs(codes[[c]]), function(r) definer[[r]]), use.names = FALSE)
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
#' removed.
fuzz_reference <- function(codes) {
  env <- new.env(parent = baseenv())
  out <- list()
  for (id in fuzz_topo(codes)) {
    code <- codes[[id]]
    if (!nzchar(code)) { out[[id]] <- list(status = "ok", text = NULL); next }
    res <- tryCatch({
      val <- NULL
      for (e in parse(text = code, keep.source = FALSE)) val <- eval(e, env)
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
  # The code each cell last ran, which is what its output came from.
  ran <- list()
  last <- list()
  for (s in seq_along(trace$steps)) {
    step <- trace$steps[[s]]
    for (op in step$ops) {
      ok <- tryCatch({ fuzz_apply(nb, op); TRUE }, error = function(e) conditionMessage(e))
      if (!isTRUE(ok)) return(list(step = s, problems = paste("edit refused:", ok)))
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
      if (!identical(v$last_run, last[[v$id]])) ran[[v$id]] <- v$code
    }
    last <- stats::setNames(lapply(snap$cells, `[[`, "last_run"), vapply(snap$cells, `[[`, "", "id"))
    ran <- ran[intersect(names(ran), names(last))]
    problems <- fuzz_check(snap, ran, trace$mode, step$run, res)
    if (length(problems)) return(list(step = s, problems = problems))
  }
  NULL
}

#' What's wrong with `snap`, as sentences; empty when nothing is.
fuzz_check <- function(snap, ran, mode, run, res) {
  problems <- character()
  say <- function(...) problems <<- c(problems, paste0(...))
  views <- stats::setNames(snap$cells, vapply(snap$cells, `[[`, "", "id"))
  views <- views[names(views) != "S"]
  current <- lapply(views, `[[`, "code")
  has_run <- function(v) v$status %in% c("ok", "error")

  if (!is.null(res) && isTRUE(res$timed_out)) say("the run timed out")

  # Every output not marked stale is what running the code behind the
  # outputs from scratch gives, so the reference uses the code each cell
  # ran. A cell edited since it ran keeps its old output, marked as edited;
  # what it and its readers show depends on what ran while the edit was
  # staged, which nothing marks, so neither is checked here (#175).
  shown <- Filter(function(id) has_run(views[[id]]) && !is.null(ran[[id]]), names(views))
  ref <- fuzz_reference(ran[shown])
  edited <- Filter(function(id) isTRUE(views[[id]]$code_differs), shown)
  for (id in shown) {
    v <- views[[id]]
    if (isTRUE(v$stale) || id %in% edited) next
    reads <- fuzz_ancestors(ran[shown], id)
    if (length(intersect(reads, edited))) next
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

  fresh <- function(id) {
    v <- views[[id]]
    has_run(v) && !isTRUE(v$stale) && !isTRUE(v$code_differs)
  }
  if (identical(run, "all")) {
    for (id in names(views)) if (!fresh(id)) say("after running every cell, ", id, " isn't fresh")
  } else if (!is.null(run) && run %in% names(views)) {
    if (!fresh(run)) say("after running ", run, ", it isn't fresh")
    for (a in fuzz_ancestors(current, run)) {
      if (!fresh(a)) say("after running ", run, ", its ancestor ", a, " isn't fresh")
    }
    # Autorun reruns the dependents that have a result; one that never ran
    # stays not run (step.R, invalidate_dependents()).
    if (identical(mode, "autorun")) {
      for (d in fuzz_descendants(current, run)) {
        if (has_run(views[[d]]) && !fresh(d)) say("after running ", run, " in autorun, its dependent ", d, " isn't fresh")
      }
    }
  }
  unique(problems)
}

# Reporting and shrinking --------------------------------------------------

#' A trace as R code that rebuilds it, for a failure message or a
#' regression test.
fuzz_format <- function(trace) {
  paste(deparse(trace[c("mode", "cells", "steps")], width.cutoff = 100), collapse = "\n")
}

#' A problem without its cell ids and values, so shrinking keeps the same
#' kind of failure rather than drifting to another one.
fuzz_kind <- function(problems) {
  unique(gsub('"[^"]*"|\\bC[0-9]+\\b|\\b(ok|error|not_run)\\b', "_", problems))
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
