import { AnsiUp } from "./vendor/ansi_up-BiGs99As.js"

export const ansi_to_html = (ansi, { use_classes = true } = {}) => {
    const ansi_up = new AnsiUp()
    ansi_up.use_classes = use_classes
    return ansi_up.ansi_to_html(ansi)
}
