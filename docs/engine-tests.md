# Tests for build step 2 (candidate A: one state, one `step()`)

Four layers. Most tests are in the first two and start no process.

- **Pure:** `parse_notebook`/`format_notebook`, `step()`, the projections.
  The core is driven with a helper, `drive(state, ...events)`, that folds
  `step()` over events, runs `check_state()` after each one, and returns
  the final state plus every effect in order. Worker replies are written
  as events (`wk_hello(1, ...)`, `wk_done(1, token, report(...))`), with a
  `report()` builder for the done payload. Time is a counter
  (`at = t(1)`, `t(2)`, ...).
- **Shell pieces:** framing, the wire-to-event boundary, atomic writes.
  No worker.
- **Worker harness:** `worker_harness()` starts the real `inst/worker.R`
  with processx and talks frames to it directly, using blocking reads with
  a timeout. There is no server, no `later`, and no sleeps.
- **End to end:** the R API with a real worker. Waits use
  `wait_for(nb, predicate, timeout)`, never `Sys.sleep`.

## File format (test-notebook-file.R)

1. `parse_canonical_example`: parses the example in design.md and gives the header fields, 4 cells, display order, fold, learned and lock.
2. `round_trip_byte_stable`: `format_notebook(parse_notebook(x)) == x` for every file in `tests/testthat/files/format-1/`.
3. `round_trip_generated`: the same for 200 generated notebooks (random code with blank lines inside, markdown with empty lines, folds, unicode).
4. `cells_written_in_run_order`: a display order that differs from run order writes cells in run order and the display order in the footer.
5. `setup_tag_ignored`: an older Ember's `[setup]` tag is read and ignored, and the next save drops it. A `learned settings` footer block round-trips.
6. `old_setup_cell_of_text`: an old setup cell of only `#'` lines is a text cell; an empty one stays an empty code cell.
7. `markdown_prefix`: `#' ` and a bare `#'` are stripped, and a markdown line without the prefix is kept.
8. `trailing_blank_lines_normalised`: trailing blank lines in a cell are dropped on parse, and the result is then stable.
9. `plain_script_opens`: a file with no header and no markers becomes one code cell and notes `no_header`.
10. `markers_without_ids`: `# %%` lines without ids (Positron style) get ids from `new_id` and note `bad_id`.
11. `duplicate_ids_repaired`: the second cell with a repeated id gets a new id and notes `duplicate_id`. The first keeps its id.
12. `missing_footer`: display order is file order and notes `no_footer`.
13. `order_block_mismatch`: unknown ids in the order block are dropped, and unlisted cells are placed after their file predecessor.
14. `text_before_first_marker`: becomes its own cell.
15. `unknown_header_keys_kept`: unknown keys and footer blocks survive a round trip verbatim.
16. `header_optional_fields`: `bioc_version`, `[sources]` and `[extra_packages]` are written only when set.
17. `toml_strings`: values and paths with quotes, backslashes and spaces round-trip.
18. `newer_version_read_only`: `ember_version` above the running version sets `read_only` and notes `newer_version`.
19. `older_format_converted`: with a fake `converters[[1]]` and `ember_format = 2`, a format-1 file converts on parse and notes `converted`.
20. `crlf_read`: `\r\n` text parses like `\n` text.

## Core: editing (test-step-edit.R)

21. `open_requests_sourced_files`: a cell with `source("h.R")` makes `ev_open` emit `fx_read_files("h.R")`. After `ev_files_read`, the graph has the file's definitions.
22. `edit_rebuilds_graph_only`: `set_code` changes `cells` and `graph`, emits no worker effect, and marks nothing stale.
23. `edit_code_differs`: after an edit to a cell that ran, its view has `code_differs = TRUE` and keeps its output.
24. `apply_atomic_expected_mismatch`: one bad `expected` in a batch of three ops leaves the state `identical()` to before, and the reply is `ember_refused` naming the op.
25. `apply_insert_ids_from_event`: inserted ids are the ones in the ops, and the reply lists them in op order.
26. `apply_delete_first_cell`: deleting the first cell is allowed; no cell is special.
27. `apply_marker_line_refused`: code containing `# %% id=x` is refused.
28. `apply_move_and_fold`: display order and fold change, run order is unaffected, and the file text changes.
29. `delete_cell_removes_variables`: deleting a cell that ran sends `remove_cell` and drops its result. Its readers become stale, never queued: an edit (including delete) never runs anything, in either mode.
30. `delete_reader_of_removed_name`: B read `x` from A. After A is edited to stop defining `x` and A runs, B is invalidated even though the new graph has no A→B edge.
31. `read_only_refuses_everything`: apply, run and restart are refused, and no effect is emitted.
32. `seq_advances_only_on_change`: a no-op event (a stale worker message) leaves `seq` unchanged.

## Core: scheduling (test-step-run.R)

33. `first_run_allows_and_starts_worker`: `ev_run` in preview sets `allowed` and emits `fx_start_worker(gen = 1)`. Nothing is sent before `wk_hello`.
34. `run_runs_unrun_ancestors_first`: running C (A→B→C, none run) sends A, then B, then C, one per `wk_done`.
35. `fresh_ancestors_not_rerun`: an ancestor with a current ok result is not sent again.
36. `edited_ancestor_rerun`: an ancestor whose code differs is rerun before the cell.
37. `autorun_reruns_dependents`: after A reruns in autorun, its dependents that had results are queued and run. Dependents that were never run stay not run.
38. `lazy_marks_dependents_stale`: in lazy mode the same dependents get `stale = TRUE` and are not queued. Running one runs its stale ancestors first.
39. `stale_cleared_by_running`
40. `blocked_cells_skipped`: cells in a cycle or with multiple definitions, and their dependents, are not queued and come back in `skipped`.
41. `error_drops_downstream`: when A errors, its queued dependents leave `pending` and are stale.
42. `queue_follows_current_graph`: an edit during a run that adds an edge reorders the remaining queue.
43. `rerun_request_while_running`: asking for the running cell again queues it once more.
44. `learned_definitions_from_report`: `created = "fits"` from `load()` becomes a learned definition, and a cell reading `fits` gains the edge and (autorun) runs.
45. `learned_multiple_definition`: a learned name another cell defines makes a graph error, and both cells are blocked.
46. `changed_foreign_global_is_error`: `changed = "df"` (owned by another cell) gives a `multiple_definitions` run error with the fix text.
47. `settings_found_at_run_time`: a non-empty `settings` report makes the cell a settings cell (learned settings) and shows a note; two cells setting one key give `setting_conflict`.
48. `run_message_carries_settings`: the run message's `settings` lists the settings cells before the cell in run order that are enabled and didn't fail.
49. `exports_from_report_add_package_edges`: `attached = list(dplyr = "mutate")` adds an edge to the cell that calls `mutate`.
50. `formula_misses_become_references`: `formula_misses = "deg"` makes `graph_learn(references = "deg")` and an edge.
51. `source_request_allowed`: `wk_source` with a file defining a new name replies `allow = TRUE` and learns the name.
52. `source_request_conflict_refused`: a file defining another cell's name replies `allow = FALSE` with a message naming the cell.
53. `sourced_file_change_invalidates`: `ev_files_read` with a new hash for `h.R` marks the sourcing cell stale (lazy) or queues it (autorun).
54. `run_message_carries_order`: every run message has the current code-cell run order.
55. `stale_token_ignored`: a `wk_done` with an old token or generation changes nothing.

## Core: interrupt, restart, crashes (test-step-process.R)

56. `interrupt_sends_sigint_and_clears_queue`: emits `fx_interrupt` and a timer, and `pending` empties.
57. `interrupt_offer_after_grace`: `tm_offer_restart` with the running token sets `restart_offered`.
58. `late_interrupt_withdraws_offer`: `wk_done(status = "interrupted")` after the offer clears it.
59. `stale_timer_ignored`: a timer for a token that already finished does nothing.
60. `restart_leaves_all_not_run`: after `ev_restart`, `results` is empty, nothing is queued, the generation goes up, and `fx_kill_worker` comes before `fx_start_worker`.
61. `restart_refused_in_preview`
62. `old_generation_events_ignored`: `wk_done` and `wk_exited` from generation 1 after a restart to 2 change nothing.
63. `worker_crash_while_running`: `wk_exited` gives the running cell a `worker_exited` error, clears the other results, and sets status `stopped`.
64. `no_restart_loop`: after a crash, nothing starts a worker until the next `ev_run`.
65. `worker_failed_to_start`: `wk_failed` sets `stopped` and empties the queue, and the message is in the snapshot.
66. `shutdown_kills_and_closes`: emits kill and close, the reply is `TRUE` in preview, and later events are no-ops.

## Projections (test-projections.R)

67. `snapshot_fields`: each `ember_cell_view` field for a hand-built state covering every status.
68. `snapshot_running_shows_stream`: the running cell's console holds the streamed items.
69. `notifications_cell_state_ids`: only the cells whose view changed are listed.
70. `notifications_topology_changed`: listed when the edges change and absent for an edit that keeps them.
71. `notifications_execution_done`: emitted once, when the queue drains.
72. `notifications_burst_coalesced`: three events folded into one before/after pair give one `cell_state`.
73. `file_of_state_round_trips`: `parse_notebook(format_notebook(notebook_file_of(s)))` gives the same cells, order, learned definitions and settings, and lock.
74. `opening_does_not_change_text`: for an Ember-written file, `format_notebook(notebook_file_of(new_state(parse(x))))` equals `x`, so opening never writes.
75. `watched_files_literal_and_computed`

## Shell pieces (test-shell.R)

76. `take_frames_partial`: a frame split across 1-byte chunks comes out once, whole. Leftover bytes are kept.
77. `take_frames_many`: three frames in one chunk give three messages in order.
78. `take_frames_large_linear`: a 20 MB frame in 64 KB chunks is joined once (check the time is in proportion to the size).
79. `worker_event_validates`: a message with a missing field becomes `wk_failed("protocol error")`.
80. `worker_event_secret`: a hello with the wrong secret is rejected.
81. `write_atomic_replaces`: the old file is intact if the write fails midway (simulate with an unwritable temp dir).
82. `drain_not_reentrant`: an effect that enqueues an event is handled in the same drain, and the reply comes from the first event.

## Worker harness (test-worker.R, real process, no server)

83. `hello_and_secret`
84. `run_value_and_console_order`: `cat("a"); message("b"); warning("c"); 1 + 1` gives console items stdout, message and warning in that order, with output text `[1] 2`.
85. `earlier_visible_values_to_console`: `1; 2` gives output `2` and the console prints `1`.
86. `error_with_traceback`: an error inside a function gives a traceback that ends at that function, with no worker frames.
87. `rerun_removes_previous_globals`: a cell defines `x`, its code changes to define `y`, and after the rerun `x` is gone.
88. `created_changed_removed`: reports the right names. `.Random.seed` is never reported.
89. `active_binding_not_forced`: `makeActiveBinding` with a counter is not called by the comparison.
90. `options_change_reported_and_applied_in_context`: `options(digits = 3)` is reported; a later run sees 3 only when that cell is in its `settings`.
91. `settings_reset_before_each_run`: a settings cell rerun without the call goes back to the starting value; `setwd("data")` rerun doesn't nest; a deleted settings cell stops applying.
92. `package_load_changes_allowed`: `loadNamespace("tools")` plus a fake package fixture whose `.onLoad` sets an option gives no settings error. The same option set by the cell's code does give one.
93. `onattach_changes_allowed`: the same with a fixture package that sets an option in `.onAttach`.
94. `search_path_rebuilt_in_file_order`: two fixture packages that export the same name are attached by two cells. After the cell order changes, masking follows the new order.
95. `delete_attaching_cell_detaches`: after `remove_cell`, the package leaves `search()` but its namespace stays loaded.
96. `attached_reports_exports`
97. `computed_source_request`: `source(file.path(d, "h.R"))` sends a `source` request and waits. A deny makes the cell an error, and `remove_cell` messages received meanwhile are handled after the run.
98. `formula_check_symbol_data`: `lm(y ~ x + z, data = df)` with no `z` column reports `z`. A call as `data` is skipped.
99. `fresh_device_per_cell`: `par(mfrow = c(2, 2))` in one cell doesn't affect the next cell's plot.
100. `base_plot_output`: `plot(1:10)` gives a PNG output, and `render` at a new size returns a PNG of that size.
101. `data_frame_table_view`: gives the table MIME type with a text/plain form of the first rows.
102. `user_globals_cannot_shadow_worker`: a cell defining `send`, `receive` and `run_cell` doesn't break the next run.
103. `interrupt_r_code`: SIGINT during `repeat {}` gives `interrupted` within 1 s, and the globals survive.
104. `interrupt_between_runs_swallowed`
105. `sigint_reset_when_inherited_ignored`: a server process started through `sh -c "trap '' INT; exec Rscript ..."` still interrupts its worker, because `reset_sigint()` ran first.

## End to end (test-session.R, real worker through the API)

106. `open_is_safe_preview`: `open_notebook` starts no process (check `processx` children), and the snapshot process is `preview`.
107. `run_all_from_file`: open the design.md example adapted to base R, `run_cells(nb, wait = TRUE)`, and every cell is `ok` with the expected text outputs.
108. `edit_then_run_autorun`: change an upstream constant and run it. Dependents rerun, and the outputs show the new value.
109. `lazy_mode_stale_then_run`
110. `file_saved_after_edit`: the file on disk equals `format_notebook(...)` of the state, and a `file_saved` notification arrived.
111. `file_saved_learned_definitions`: after `load()` runs, the footer has the learned name. A reopened session orders cells correctly without running.
112. `no_write_on_open`: the mtime and bytes of an opened, untouched notebook are unchanged after `close_notebook`.
113. `interrupt_and_offer_restart`: a cell stuck in compiled code (the spike's `stuck.c` as a test fixture) is interrupted, and `restart_offered` turns `TRUE` after the grace period. `restart_notebook` then leaves every cell not run.
114. `crash_reported`: `tools::pskill(Sys.getpid())` in a cell gives a `worker_exited` error, and the next run starts a new worker.
115. `endeavor_calls`: apply with `expected` (refused and accepted), `run(wait = FALSE)` followed by `execution_done`, a snapshot `seq` that never goes down, and `render_png`.
116. `ui_projection_shares_unchanged`: two consecutive `notebook_state()` values share `cells[[id]]` (`identical()` and the same address via `.Internal(address)` in the test) for cells that didn't change.
117. `server_never_blocks`: during a 2 s busy cell, a `later` callback scheduled every 10 ms keeps firing (max gap under 50 ms).
