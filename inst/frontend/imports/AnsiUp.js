import { AnsiUp } from "./vendor/ansi_up-BiGs99As.js"

const BLACK = 0
const WHITE = 7
const BRIGHT_BLACK = 8
const BRIGHT_WHITE = 15
const GREYS = [BLACK, BRIGHT_BLACK, WHITE, BRIGHT_WHITE]

const distance = (a, b) => (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2

/** For each 256-colour index from 16 to 255, the index (0-15) of the nearest base colour in ansi_up's own palette. */
const NEAREST_BASE = (() => {
    const palette = new AnsiUp().palette_256
    const nearest = (rgb, candidates) => candidates.reduce((best, i) => (distance(rgb, palette[i].rgb) < distance(rgb, palette[best].rgb) ? i : best))
    const all_bases = [...Array(16).keys()]
    return palette.map((entry, n) => {
        if (n < 16) return n
        const [r, g, b] = entry.rgb
        return nearest(entry.rgb, r === g && g === b ? GREYS : all_bases)
    })
})()

/**
 * ansi_up with every 256-colour index from 16 to 255 mapped to the nearest
 * of the 16 base colours (by RGB distance; the greys to black, bright black,
 * white or bright white), so that `use_classes` gives a theme class for every
 * colour and no inline rgb() reaches the page. Truecolor (38;2;r;g;b) is left
 * as ansi_up renders it.
 */
export const ansi_to_html = (ansi, { use_classes = true } = {}) => {
    const ansi_up = new AnsiUp()
    ansi_up.use_classes = use_classes
    for (let n = 16; n < 256; n++) {
        ansi_up.palette_256[n] = ansi_up.palette_256[NEAREST_BASE[n]]
    }
    return ansi_up.ansi_to_html(ansi)
}
