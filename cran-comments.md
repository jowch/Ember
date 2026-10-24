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

If CRAN asks, answer with the Writing R Extensions wording above. Until
R 4.7.0 is the release, the r-release flavors on CRAN's check page will show
this NOTE.
