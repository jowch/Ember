# Times bench/cases.R against two installed embers, alternating between
# them so drift on the machine hits both, and reports how much slower or
# faster the second is per case:
#
#   Rscript bench/compare.R <base-lib> <base-checkout> <head-lib> <head-checkout> [rounds]
#
# where each library holds the ember installed from that checkout.
# Each round runs one fresh R process per side (order swapped every round)
# and records each case's median; the reported time is the median over
# rounds. Exits 1 when any case is more than THRESHOLD slower on head.

THRESHOLD <- 1.25

args <- commandArgs(trailingOnly = TRUE)
libs <- c(base = args[[1]], head = args[[3]])
checkouts <- c(base = args[[2]], head = args[[4]])
rounds <- if (length(args) >= 5) as.integer(args[[5]]) else 5L
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))))
rscript <- file.path(R.home("bin"), "Rscript")

results <- list()
for (r in seq_len(rounds)) {
  order <- if (r %% 2 == 1) c("base", "head") else c("head", "base")
  for (side in order) {
    out <- tempfile(fileext = ".csv")
    status <- system2(rscript, c(file.path(here, "cases.R"), libs[[side]], checkouts[[side]], out))
    if (status != 0 || !file.exists(out)) stop("bench/cases.R failed for ", side, " in round ", r)
    d <- utils::read.csv(out)
    d$side <- side; d$round <- r
    results[[length(results) + 1]] <- d
  }
}
all <- do.call(rbind, results)

med <- function(side) {
  d <- all[all$side == side, ]
  tapply(d$seconds, d$case, function(x) if (all(is.na(x))) NA_real_ else stats::median(x, na.rm = TRUE))
}
base <- med("base"); head <- med("head")
cases <- unique(all$case)
ratio <- head[cases] / base[cases]
verdict <- ifelse(is.na(ratio), "not compared",
           ifelse(ratio > THRESHOLD, "SLOWER", ifelse(ratio < 1 / THRESHOLD, "faster", "same")))

fmt <- function(x) ifelse(is.na(x), "n/a", sprintf("%.2f ms", x * 1000))
table <- c(
  sprintf("Benchmark: head against base, median of %d alternating rounds; flagged above %.0f%% slower.", rounds, (THRESHOLD - 1) * 100),
  "",
  "| case | base | head | head / base | |",
  "|---|---|---|---|---|",
  sprintf("| %s | %s | %s | %s | %s |", cases, fmt(base[cases]), fmt(head[cases]),
          ifelse(is.na(ratio), "n/a", sprintf("%.2f", ratio)), verdict))
writeLines(table)
summary_file <- Sys.getenv("GITHUB_STEP_SUMMARY")
if (nzchar(summary_file)) cat(table, sep = "\n", file = summary_file, append = TRUE)

slower <- cases[!is.na(ratio) & ratio > THRESHOLD]
if (length(slower) > 0) {
  for (s in slower) cat(sprintf("::error title=Slower than base::%s takes %.2fx as long as on the base branch\n", s, ratio[[s]]))
  quit(status = 1)
}
