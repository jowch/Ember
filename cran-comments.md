## Notes for a CRAN submission

Ember hasn't been submitted to CRAN yet. Read this before the first one.

### R_PolledEvents and R_wait_usec (src/console.c)

Under R 4.6.x, `R CMD check --as-cran` gives:

```
* checking compiled code ... NOTE
  Found non-API calls to R: 'R_PolledEvents', 'R_wait_usec'
```

R-devel (and so R 4.7.0 on) doesn't. It classes both as "emb": entry points
that Writing R Extensions documents in `R_ext/eventloop.h` "for add-on
front-ends and for packages that need to share in the R event loops (not
Windows)" (R-devel's manual, section 6.21 "Organization of header files").
`tools:::varAPI()` lists both with `apitype = emb`, and the check skips that
class unless `_R_CHECK_SO_SYMBOLS_IGNORE_EMB_` is false. Windows uses a timer
instead and gives no NOTE on any version.

There is no API-only way to do the same job. The worker must run while a cell
is busy computing, so that printed text reaches the page as it's written
(#470). R then calls only `R_ProcessEvents()`, which on Unix runs the
front-end's hook and `R_PolledEvents`. Input handlers (`addInputHandler()`,
the `later` package) run only while R waits. The full reasoning and the
checks are on #511.

If CRAN asks, answer with the Writing R Extensions wording above. The
flavors on CRAN's check page that run R 4.6 will show this NOTE: r-release
until R 4.7.0 comes out, and r-oldrel for a year after that.

### Installed size on macOS (about 5.3 MB)

On macOS (arm64, R 4.6.1), `R CMD check --as-cran` gives:

```
* checking installed package size ... INFO
  installed size is  5.3Mb
  sub-directories of 1Mb or more:
    R          2.1Mb
    frontend   2.7Mb
```

Linux (4.6 MB by `du -k`) and Windows stay under 5 MB. Other check
machines may print this as a NOTE.

`inst/frontend` is the notebook editor that Ember serves in the browser:
JavaScript, CSS and fonts, all bundled so that Ember works offline and loads
nothing from the network (a test checks that). Its largest part is the code
editor (CodeMirror), at about 650 KB. The TypeScript declaration files that
sit next to the JavaScript in the source are left out of the build
(`.Rbuildignore`). Minifying the rest is tracked on #60.

If CRAN asks, say that the size is the bundled editor, which Ember needs to
run without a network.
