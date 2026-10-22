---
name: ui-audit
description: Periodic audit of Ember's notebook UI for bugs, UX weaknesses and polish. Runs the scripted journeys (tests/e2e/audit.mjs), reviews the screenshots and measurements against a rubric, explores one focus area by hand, and files deduplicated GitHub issues plus a run summary. Use when asked to audit the UI or on a schedule.
---

# Audit Ember's UI

This finds problems. It doesn't fix them: fixes go in their own PRs. One
run takes about 30-45 minutes. Its output is a few well-evidenced issues
and a summary comment, not a long list of opinions.

Setup is the same as the `verify` skill: `npm --prefix tests/e2e ci`, and
Chromium (or `EMBER_CHROMIUM`). Work from an up-to-date `main`.

## 1. Read the log

Find the open issue titled **"UI audit log"** (label `ui-audit`). Create it
if it doesn't exist (title "UI audit log", label `ui-audit`, body: a line
saying each comment is one audit run). Read its last few comments:
- which focus areas were audited, and when, so you can pick the next one (step 4);
- the **Declined** list in the log's description: findings the maintainer
  decided not to act on. Never file those again. The maintainer adds to
  it by editing the description; an issue from an earlier audit that was
  closed as not planned counts as declined too;
- the metrics from earlier runs, to spot trends (step 3).

## 2. Run the scripted journeys

```sh
cd tests/e2e
node audit.mjs --out test-results/audit-chromium
EMBER_BROWSER=webkit node audit.mjs --out test-results/audit-webkit   # where WebKit installs
node run.mjs tests/ui-sweep.test.mjs
```

`audit.mjs` walks six journeys (its header lists them) and writes a
screenshot per step plus `notes.json`: layout problems
(`layout-check.mjs` rules), layout shift, timings, tab stops, axe in dark
mode, and console errors. A journey that throws is recorded as `error` in
its notes: that's a finding too (something a person does no longer works),
unless the script itself is out of date, in which case fix the script in
the same PR as any other audit tooling change.

If WebKit can't be installed where you run, say so in the summary. Don't
skip quietly.

## 3. Review the evidence

**Read every screenshot** (the Read tool shows images) with
[rubric.md](rubric.md) open, and write down what you see that's wrong,
odd or inconsistent. Compare the same step across widths, themes and
browsers: a difference between them is often the finding.

Check `notes.json` against these thresholds:

| Measure | Fine | Finding |
|---|---|---|
| `console` | empty | any entry |
| layout problems | only those in `KNOWN` (ui-sweep.test.mjs) | any other |
| A `run-all.cls` | < 0.1 | ≥ 0.1, or up ≥ 0.05 since the last run |
| B `add-ms`, F `add-cell-ms` | < 200 | ≥ 300 (Chromium, headless) |
| F `type-10-chars-ms` | < 300 | ≥ 500 |
| F `perf.long` | none over 100 ms | any task ≥ 200 ms |
| D `tab-stops` | every stop has `ring`, none at `body` | a stop without a ring, focus lost to body, or `cells-edited-by-tabbing` non-empty with the Tab setting on "focus" |
| E `axe-dark` | empty | any serious or critical rule |

A's CLS counts every shift after the safe-preview banner has gone, so it
reads the same each run. Outputs landing and pushing the cells below them
down count: as little of the page moving as possible is the goal. Audits
up to 2026-10-22 counted only shifts more than 500 ms after the click, so
they read 0.07 to 0.17 for the same page.

Headless timings are a floor: Endeavor's WebKit pane is slower. Trends
between runs matter more than one number.

## 4. Explore one focus area by hand

Pick the area audited longest ago (from the log), unless the person asked
for one:

1. First run: start page, opening a notebook, safe preview, first run
2. Editing cells: add, move, delete, undo, hide code, disable, multi-select
3. Outputs: tables, plots, long text, errors, warnings, rich and HTML outputs
4. Packages: missing package, install cards, failures, the Packages tab
5. Help and completion: Help tab, signature tooltips, go to definition
6. Side panel and Variables
7. Menus, dialogs, settings, export, keyboard shortcuts sheet
8. Keyboard only and screen reader names
9. Narrow widths and Endeavor: 600-900 px, the open_bottom_right_panel event, WebKit
10. Big notebooks: 50+ cells, large outputs, slow cells, interrupts

Spend about 20 minutes. Drive it with a scratch script that imports the
harness (see the `verify` skill's Launch section) and push on edges: long
names, empty cells, huge or wide outputs, errors mid-run, fast repeated
clicks, reload mid-run, two tabs, dark mode, ⌘ and Ctrl labels. The feature
map in `.claude/skills/verify/features/` says how to reach each surface.
Take screenshots of anything suspicious and look at them.

## 5. Qualify each finding

A candidate becomes a finding only when:
- **It reproduces** twice, from a fresh server, with steps you can write down.
- **It's not intended.** Check the code and docs (`docs/ui*.md`, comments
  near the code) for a deliberate choice. A deliberate choice with a cost
  to users is a *suggestion*, not a bug.
- **It's new.** Search open *and* closed issues with two or three
  phrasings, and check the log's Declined list. If an open issue covers
  it, add a comment there only if you have new evidence (a new width,
  browser or a simpler repro).

Then classify it:
- **Bug**: something is broken, blocked, wrong, lost, or inaccessible
  (a control you can't reach or read, an axe serious/critical rule, a
  console error, data changed that the person didn't change).
- **UX weakness**: it works, but it's confusing, slow, inconsistent or
  easy to get wrong.
- **Polish**: alignment, spacing, wording, a visual glitch with no effect
  on use.

## 6. File

File each **bug** as its own issue, and **UX weaknesses** with strong
evidence too, at most **5 issues per run**, most severe first. Follow the
repo's issue style:

- Title: what happens, in plain words.
- **What happens.** Steps from a fixture or a short notebook, what you
  saw, at which width, theme, browser and commit. Measurements from
  `notes.json` where they apply.
- **Why** (if found): the file and line, with the mechanism.
- **Fix** (if clear): one or two options.
- **Test**: how a test would catch it. Say if `layout-check.mjs` or the
  sweep could (a new rule, a new state in `fixtures/ui-sweep.R`).
- Label `ui-audit`.

Screenshots can't be attached through the API, so describe exactly what
the screenshot shows, with the selector and its measured box.

Polish and the rest of the UX weaknesses go in the summary, not in issues.

## 7. Post the run summary

Comment on the "UI audit log" issue:

```
## Audit <date> · <short commit> · <browsers>
Focus: <area>

Filed: #n title, ...
Suggestions (not filed): one line each
Checked and fine: one line each for what you looked at and found nothing
Metrics: run-all CLS, add-cell ms (B, F), type ms, open ms (F), axe count, console errors
Couldn't check: anything skipped, and why
```

Then report the same summary, with the filed issue links, to whoever asked
for the run.

## What not to do

- Don't fix anything during an audit, or edit `KNOWN` in the sweep.
- Don't file opinions without evidence, or more than 5 issues in one run.
- Don't refile anything that's in an open issue, a closed one, or the
  Declined list.
- Don't report headless timings as user-facing latency. Report them as
  measured, and as a trend.
