// Feature flag distinguishing Ember (the R engine behind this frontend) from
// upstream Pluto (Julia). Each Julia-only feature switched off in increment 1
// reads `if (!EMBER)`, so increment 2 can find every one of them with a
// single grep for `!EMBER`.
export const EMBER = true
