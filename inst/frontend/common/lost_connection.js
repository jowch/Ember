import { connection_lost_message } from "./PlutoConnection.js"
import { t } from "./lang.js"

/**
 * What a form shows when the request it awaits failed because the socket
 * closed before the reply, or was closed when it was sent (#584). The
 * request may still have reached the server, so the text says to check.
 * Any other error is thrown on.
 */
export const lost_connection_text = (/** @type {any} */ e) => {
    if (e?.message === connection_lost_message) return t("t_ember_connection_lost")
    throw e
}
