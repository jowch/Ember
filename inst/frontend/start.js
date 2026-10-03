import { html, render, useEffect, useState } from "./imports/Preact.js"
import { create_pluto_connection } from "./common/PlutoConnection.js"
import { PlutoActionsContext } from "./common/PlutoContext.js"
import { StartPage } from "./components/StartPage.js"
import { apply_theme } from "./common/theme.js"

apply_theme()

/**
 * The start page's entry point (start.html): a websocket connection with
 * no notebook id, feeding `ember_start_page`/`ember_new_notebook`/
 * `ember_open_notebook`/`ember_forget_recent` and Pluto's own
 * `completepath` (FolderField, FilePicker) through the same
 * `create_pluto_connection()` the editor uses. `client` already has
 * `.send`, so it's handed to `PlutoActionsContext` as is.
 */
const StartApp = () => {
    const [client, set_client] = useState(/** @type {any} */ (null))

    useEffect(() => {
        let mounted = true
        create_pluto_connection({
            on_unrequested_update: () => {},
            on_reconnect: async () => true,
            on_connection_status: () => {},
        }).then((c) => {
            if (mounted) set_client(c)
        })
        return () => {
            mounted = false
        }
    }, [])

    if (client == null) return null

    return html`<${PlutoActionsContext.Provider} value=${client}>
        <${StartPage} />
    </${PlutoActionsContext.Provider}>`
}

render(html`<${StartApp} />`, document.querySelector("#ember-start-root"))
