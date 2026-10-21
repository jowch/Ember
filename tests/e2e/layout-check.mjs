// Generic layout rules, checked on whatever the page shows right now:
// rules that hold for every control, so they catch a clipped or covered
// button nobody wrote a test for (#290, #286, #284). Used by
// tests/ui-sweep.test.mjs, which runs them over a notebook at several
// widths, and by the verify skill (.claude/skills/verify).
//
// Each problem is { rule, where, detail }. `where` is a short CSS-ish path
// to the element, stable enough to name in KNOWN (ui-sweep.test.mjs).
//
// The rules:
//   page-scroll    the page scrolls sideways.
//   off-screen     a control sticks out past the left or right edge.
//   clipped        a box with overflow hidden/clip cuts a control off.
//                  A box that can scroll to it (overflow auto/scroll with
//                  content past its edge) is fine: that's a table scrolled
//                  sideways, not a bug.
//   spills         a control's contents stick out of its own box, or the
//                  control sticks out of the framed box (border or
//                  background) it sits in.
//   covered        something else is on top of the control's centre.
//   scrollbar      a control sits in the bottom 14 px of a box that
//                  scrolls sideways, where an overlay scrollbar (macOS,
//                  WebKit embeds) draws over it. Checked by geometry, so
//                  it holds in Chromium's classic scrollbars too.
//   cell-mismatch  two cells in the same state show different chrome (a
//                  chip, a line number) where the other doesn't.

/** Every problem on the part of the page in the viewport now. */
export async function viewportProblems(page) {
  return page.evaluate(() => {
    const TOL = 1;
    const problems = [];
    const vw = document.documentElement.clientWidth;
    const vh = window.innerHeight;

    const where = (el) => {
      const parts = [];
      for (let e = el; e && e !== document.body && parts.length < 4; e = e.parentElement) {
        let s = e.tagName.toLowerCase();
        if (e.id && e.tagName !== "PLUTO-CELL") s += "#" + e.id;
        else if (e.tagName === "PLUTO-CELL") s += `[id=${e.id}]`;
        else if (typeof e.className === "string" && e.className.trim()) s += "." + e.className.trim().split(/\s+/).slice(0, 2).join(".");
        parts.unshift(s);
        if (e.tagName === "PLUTO-CELL") break;
      }
      return parts.join(" > ");
    };
    const shown = (el) => {
      if (el.getClientRects().length === 0) return false;
      for (let e = el; e; e = e.parentElement) {
        const cs = getComputedStyle(e);
        if (cs.visibility === "hidden" || cs.display === "none" || Number(cs.opacity) === 0) return false;
        if (e.getAttribute("aria-hidden") === "true" && e.tagName !== "SVG") return false;
      }
      return true;
    };
    const add = (rule, el, detail) => problems.push({ rule, where: where(el), detail });

    if (document.documentElement.scrollWidth > vw + TOL) {
      problems.push({ rule: "page-scroll", where: "html", detail: `scrollWidth ${document.documentElement.scrollWidth} > ${vw}` });
    }

    // Anything above this line is under the sticky header on purpose.
    const header = document.querySelector("header#pluto-nav");
    const top = header ? header.getBoundingClientRect().bottom : 0;

    const controls = [...document.querySelectorAll(
      "button, a[href], [role=button], [role=menuitem], input:not([type=hidden]), select, summary")]
      .filter(shown)
      .filter((el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && r.bottom > top && r.top < vh;
      });

    for (const el of controls) {
      const r = el.getBoundingClientRect();

      if (r.left < -TOL || r.right > vw + TOL) add("off-screen", el, `x ${Math.round(r.left)}..${Math.round(r.right)}, viewport ${vw}`);

      for (let a = el.parentElement; a && a !== document.documentElement; a = a.parentElement) {
        const cs = getComputedStyle(a);
        const ar = a.getBoundingClientRect();
        const check = (axis) => {
          const o = axis === "x" ? cs.overflowX : cs.overflowY;
          if (o === "visible") return;
          const [lo, hi, alo, ahi] = axis === "x" ? [r.left, r.right, ar.left, ar.right] : [r.top, r.bottom, ar.top, ar.bottom];
          if (lo >= alo - TOL && hi <= ahi + TOL) return;
          const scrolls = (o === "auto" || o === "scroll") &&
            (axis === "x" ? a.scrollWidth > a.clientWidth + TOL : a.scrollHeight > a.clientHeight + TOL);
          if (!scrolls) add("clipped", el, `by ${where(a)} (overflow-${axis} ${o})`);
        };
        check("x");
        check("y");
      }

      for (const d of el.querySelectorAll("*")) {
        if (!shown(d)) continue;
        const dr = d.getBoundingClientRect();
        if (dr.width === 0 || dr.height === 0) continue;
        if (dr.left < r.left - TOL || dr.right > r.right + TOL || dr.top < r.top - TOL || dr.bottom > r.bottom + TOL) {
          add("spills", el, `its ${d.tagName.toLowerCase()} reaches ${Math.round(dr.left)},${Math.round(dr.top)}..${Math.round(dr.right)},${Math.round(dr.bottom)}; box is ${Math.round(r.left)},${Math.round(r.top)}..${Math.round(r.right)},${Math.round(r.bottom)}`);
          break;
        }
      }
      const p = el.parentElement;
      if (p) {
        const ps = getComputedStyle(p);
        const framed = parseFloat(ps.borderTopWidth) > 0 || parseFloat(ps.borderBottomWidth) > 0 ||
          (ps.backgroundColor !== "rgba(0, 0, 0, 0)" && ps.backgroundColor !== "transparent");
        const pr = p.getBoundingClientRect();
        if (framed && ps.overflow === "visible" &&
            (r.left < pr.left - TOL || r.right > pr.right + TOL || r.top < pr.top - TOL || r.bottom > pr.bottom + TOL)) {
          add("spills", el, `out of its framed parent ${where(p)}`);
        }
      }

      const cx = (Math.max(r.left, 0) + Math.min(r.right, vw)) / 2;
      const cy = (Math.max(r.top, top) + Math.min(r.bottom, vh)) / 2;
      const hit = document.elementFromPoint(cx, cy);
      // The "add cell" buttons above and below the gap between two cells
      // overlap by design (Pluto's); either one adds a cell there.
      const both_add = el.matches(".add_cell") && hit?.closest(".add_cell");
      if (hit && hit !== el && !el.contains(hit) && !hit.contains(el) && !both_add) add("covered", el, `by ${where(hit)}`);
    }

    // Boxes that scroll sideways: their bottom band is where an overlay
    // scrollbar draws.
    for (const box of document.querySelectorAll("main *")) {
      const cs = getComputedStyle(box);
      if (cs.overflowX !== "auto" && cs.overflowX !== "scroll") continue;
      if (box.scrollWidth <= box.clientWidth + TOL) continue;
      const br = box.getBoundingClientRect();
      const bottom = br.top + box.clientTop + box.clientHeight;
      for (const el of controls) {
        if (!box.contains(el)) continue;
        const r = el.getBoundingClientRect();
        if (r.bottom > bottom - 14 && r.top < bottom) add("scrollbar", el, `in the bottom 14px of ${where(box)}, which scrolls sideways`);
      }
    }

    return problems;
  });
}

/** Cells in the same state should show the same chrome: a chip, a line
 * number gutter, a run button. Cells are grouped by their state classes
 * and kind; within a group, a piece of chrome most cells show and one
 * doesn't (or the other way round) is a problem. Checks every cell, on or
 * off screen, so scroll each into view first if it matters (off-screen
 * cells render a static stand-in editor). */
export async function cellProblems(page) {
  return page.evaluate(() => {
    const STATE = ["running", "queued", "errored", "code_differs", "code_folded", "show_input", "hidden-cell", "running_disabled", "depends_on_disabled_cells"];
    const CHROME = {
      chip: "ember-chip:not(.held)",
      "line numbers": ".cm-lineNumbers .cm-gutterElement",
      "run button": "pluto-runarea button",
    };
    const groups = new Map();
    for (const cell of document.querySelectorAll("pluto-cell")) {
      const kind = cell.querySelector("pluto-input .cm-editor") ? "code" : "other";
      const out = cell.querySelector("pluto-output")?.textContent.trim() || cell.querySelector("pluto-output img") ? "output" : "no-output";
      const key = [kind, out, ...STATE.filter((c) => cell.classList.contains(c))].join(" ");
      const has = {};
      for (const [name, sel] of Object.entries(CHROME)) {
        has[name] = [...cell.querySelectorAll(sel)].some((e) => e.getClientRects().length > 0);
      }
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push({ id: cell.id, has });
    }
    const problems = [];
    for (const [key, cells] of groups) {
      if (cells.length < 2) continue;
      for (const name of Object.keys(CHROME)) {
        const yes = cells.filter((c) => c.has[name]);
        const no = cells.filter((c) => !c.has[name]);
        if (yes.length === 0 || no.length === 0) continue;
        const odd = yes.length < no.length ? yes : no;
        for (const c of odd) {
          problems.push({ rule: "cell-mismatch", where: `pluto-cell[id=${c.id}]`,
            detail: `${c.has[name] ? "shows" : "has no"} ${name}, unlike ${cells.length - odd.length} other cell(s) in state "${key}"` });
        }
      }
    }
    return problems;
  });
}

/** Scroll the page top to bottom a viewport at a time, collecting
 * viewportProblems at each stop, then cellProblems. Duplicates (same
 * rule and element) are reported once. */
export async function pageProblems(page) {
  const seen = new Map();
  // Park the mouse on the header's empty edge, so no cell is hovered (a
  // hovered cell shows its buttons, mid-transition).
  const vw = await page.evaluate(() => document.documentElement.clientWidth);
  await page.mouse.move(vw - 2, 2);
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  const vh = await page.evaluate(() => window.innerHeight);
  for (let y = 0; ; y += Math.max(200, vh - 120)) {
    await page.evaluate((y) => window.scrollTo(0, y), y);
    await page.waitForTimeout(250);
    for (const p of await viewportProblems(page)) {
      const k = p.rule + " " + p.where;
      if (!seen.has(k)) seen.set(k, p);
    }
    if (y + vh >= height) break;
  }
  for (const p of await cellProblems(page)) seen.set(p.rule + " " + p.where, p);
  await page.evaluate(() => window.scrollTo(0, 0));
  return [...seen.values()];
}

/** Make the page think it runs on a Mac (⌘ shortcuts) or not (Ctrl).
 * Call before the first goto. */
export async function emulatePlatform(page, platform) {
  if (!platform) return;
  await page.addInitScript((mac) => {
    Object.defineProperty(navigator, "platform", { get: () => (mac ? "MacIntel" : "Linux x86_64") });
    Object.defineProperty(navigator, "userAgentData", { get: () => undefined });
  }, platform === "mac");
}

export function formatProblems(problems) {
  return problems.map((p) => `  [${p.rule}] ${p.where}: ${p.detail}`).join("\n");
}
