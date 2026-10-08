# Tests for R/protocol.R: msgpack round trips, fb_diff/fb_apply, and
# parse_request(). Pure; no sockets, no engine. (docs/ui-tests.md, section 1,
# items 1-5.)

# ---- 1. Encoding rules ---------------------------------------------------

test_that("arr() round-trips through msgpack as an array, even at length one", {
  got <- mp_decode(mp_encode(list(x = arr("a"))))
  expect_true(is.list(got$x) && is.null(names(got$x)))
  expect_equal(got$x, list("a"))
})

test_that("emptymap() round-trips as {} and list() round-trips as []", {
  got <- mp_decode(mp_encode(list(m = emptymap(), a = list())))
  expect_true(is_map(got$m))
  expect_equal(length(got$m), 0L)
  expect_true(is.list(got$a) && is.null(names(got$a)))
  expect_equal(length(got$a), 0L)
})

test_that("a NULL field round-trips as nil, keeping the key", {
  x <- list(a = 1)
  x["b"] <- list(NULL)
  got <- mp_decode(mp_encode(x))
  expect_true("b" %in% names(got))
  expect_null(got$b)
})

test_that("raw round-trips as bin", {
  bytes <- as.raw(c(1, 2, 3, 255))
  got <- mp_decode(mp_encode(list(img = bytes)))
  expect_true(is.raw(got$img))
  expect_equal(got$img, bytes)
})

test_that("integer stays integer and double stays double", {
  got <- mp_decode(mp_encode(list(i = 5L, d = 5)))
  expect_true(is.integer(got$i))
  expect_true(is.double(got$d))
  expect_equal(got$i, 5L)
  expect_equal(got$d, 5)
})

# ---- 2. fb_apply_all(old, fb_diff(old, new)) == new, on random pairs ----

# Random nested maps and arrays. A map's values may become NULL, simulating
# a field that goes missing (the documented null/missing equivalence);
# brand-new keys are never NULL, since fb_diff() has nothing to diff a new
# null key against and correctly treats it as no-op (a key that doesn't
# exist in `old` and is null in `new` is, by the convention, still absent).
# All list assignment below uses `x[k] <- list(v)`, never `x[[k]] <- v`,
# because the latter deletes the element entirely when `v` is NULL.

random_scalar <- function() {
  switch(sample(1:3, 1),
    sample(letters, 1),
    round(stats::runif(1) * 1000, 2),
    sample(c(TRUE, FALSE), 1))
}

random_value <- function(depth) {
  if (depth <= 0 || stats::runif(1) < 0.3) return(random_scalar())
  if (stats::runif(1) < 0.5) {
    n <- sample(0:3, 1)
    if (n == 0) return(emptymap())
    out <- emptymap()
    for (i in seq_len(n)) out[[paste0("k", i)]] <- random_value(depth - 1)
    out
  } else {
    n <- sample(0:3, 1)
    lapply(seq_len(n), function(i) random_value(depth - 1))
  }
}

mutate_map <- function(x, depth) {
  out <- list()
  for (nm in names(x)) {
    action <- sample(c("keep", "change", "remove"), 1, prob = c(0.45, 0.35, 0.20))
    if (action == "remove") next
    nv <- if (action == "keep") x[[nm]] else mutate(x[[nm]], depth - 1)
    out[nm] <- list(nv)
  }
  if (stats::runif(1) < 0.3) {
    newname <- paste0("new", round(stats::runif(1) * 1e6))
    if (!(newname %in% names(out))) out[newname] <- list(random_value(depth - 1))
  }
  if (length(out) == 0) emptymap() else out
}

mutate_array <- function(x, depth) {
  action <- sample(c("keep", "grow", "shrink", "change_one", "replace"), 1,
                   prob = c(0.3, 0.25, 0.15, 0.2, 0.1))
  if (action == "keep") return(x)
  if (action == "grow") return(c(x, list(random_value(depth - 1))))
  if (action == "shrink" && length(x) > 0) return(x[seq_len(length(x) - 1)])
  if (action == "change_one" && length(x) > 0) {
    i <- sample(seq_along(x), 1)
    x[i] <- list(mutate(x[[i]], depth - 1))
    return(x)
  }
  random_value(depth)
}

mutate <- function(x, depth) {
  if (is_map(x)) return(mutate_map(x, depth))
  if (is.list(x)) return(mutate_array(x, depth))
  if (stats::runif(1) < 0.15) return(NULL)
  random_scalar()
}

# A null-valued map key and a missing key are the same state by the wire's
# own convention ("Firebasey treats a null value as a missing key"), so the
# round trip is checked up to that equivalence: drop null-valued map
# entries from both sides before comparing. A key going from real to null
# removes the key outright (fb_apply's `x[[k]] <- NULL`); canonical() makes
# that the same shape as `new` representing the same change as a literal
# `list(NULL)` entry.
canonical <- function(x) {
  if (is_map(x)) {
    x <- x[!vapply(x, is.null, logical(1))]
    for (nm in names(x)) x[[nm]] <- canonical(x[[nm]])
    x
  } else if (is.list(x)) {
    lapply(x, canonical)
  } else x
}

test_that("fb_apply_all(old, fb_diff(old, new)) reproduces new, on random pairs", {
  set.seed(20261001)
  for (i in 1:200) {
    old <- random_value(4)
    if (!is_map(old) && !is.list(old)) old <- setNames(list(old), "x")  # start from a map
    new <- mutate(old, 4)
    patches <- fb_diff(old, new)
    got <- fb_apply_all(old, patches)
    expect_identical(canonical(got), canonical(new), info = sprintf("trial %d", i))
  }
})

# ---- 3. Append-only arrays (Pluto's AppendonlyMarker, for `logs`) -------

test_that("a grown array gives one add patch per new element, at its 0-based index", {
  old <- as.list(1:5)
  new <- c(old, list(6, 7))
  patches <- fb_diff(old, new)
  expect_length(patches, 2)
  expect_equal(vapply(patches, `[[`, "", "op"), c("add", "add"))
  expect_equal(patches[[1]]$path, list(5L))
  expect_equal(patches[[2]]$path, list(6L))
  expect_equal(patches[[1]]$value, 6)
  expect_equal(patches[[2]]$value, 7)
  expect_identical(fb_apply_all(old, patches), new)
})

test_that("a change to an array's first item gives one whole-array replace", {
  old <- as.list(1:5)
  new <- old
  new[[1]] <- 99
  patches <- fb_diff(old, new)
  expect_length(patches, 1)
  expect_equal(patches[[1]]$op, "replace")
  expect_equal(patches[[1]]$path, list())
  expect_equal(patches[[1]]$value, new)
  expect_identical(fb_apply_all(old, patches), new)
})

# ---- 4. Diff of identical objects is empty; the 2000-cell benchmark ----

test_that("diffing an object against an equal one gives no patches", {
  x <- list(a = 1, b = list(1, 2, list(c = "x")), m = emptymap())
  y <- list(a = 1, b = list(1, 2, list(c = "x")), m = emptymap())
  expect_identical(fb_diff(x, x), list())
  expect_identical(fb_diff(x, y), list())
})

test_that("fb_diff of a 2000-cell state with one changed cell grows linearly with the cells", {
  x <- perf_diff_pair(2000)
  patches <- fb_diff(x$old, x$new)
  touched <- vapply(patches, function(p) p$path[[2]], "")
  expect_equal(unique(touched), x$changed_id)
  expect_identical(fb_apply_all(x$old, patches), x$new)

  # Timed against the same diff at 200 cells, not a fixed budget
  # (helper-perf.R). The walk visits every cell once, so ten times the
  # cells is about nine times the cost here; a lookup by name inside that
  # walk (`new[[name]]` rather than the one match() per map) made it about
  # forty.
  y <- perf_diff_pair(200)
  r <- time_ratio(function() fb_diff(x$old, x$new), function() fb_diff(y$old, y$new),
                  inner_a = 10L, inner_b = 100L)
  cat(sprintf("\n[timing] fb_diff(), one changed: 2000 cells %.2f ms, 200 cells %.3f ms (%.1fx)\n",
              r$a * 1000, r$b * 1000, r$ratio))
  expect_lt(r$ratio, 20)
  # Backstop: about 3 ms on a cloud container.
  expect_lt(r$a, 0.05)
})

# ---- 5. parse_request() refusals ----------------------------------------

test_that("parse_request() refuses a missing type", {
  raw <- mp_encode(list(client_id = "c1", request_id = "r1"))
  expect_error(parse_request(raw), class = "ember_bad_request")
})

test_that("parse_request() refuses a non-string client_id", {
  raw <- mp_encode(list(type = "ping", client_id = 42, request_id = "r1"))
  expect_error(parse_request(raw), class = "ember_bad_request")
})

test_that("parse_request() refuses a body that is not a map", {
  raw <- mp_encode(list(type = "ping", client_id = "c1", request_id = "r1", body = list(1, 2)))
  expect_error(parse_request(raw), class = "ember_bad_request")
})

test_that("parse_request() accepts a well-formed message, with a default empty body", {
  raw <- mp_encode(list(type = "ping", client_id = "c1", request_id = "r1"))
  req <- parse_request(raw)
  expect_equal(req$type, "ping")
  expect_equal(req$client_id, "c1")
  expect_equal(req$request_id, "r1")
  expect_null(req$notebook_id)
  expect_true(is_map(req$body))
  expect_equal(length(req$body), 0L)
})
