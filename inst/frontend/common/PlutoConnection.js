import { Promises } from "../common/SetupCellEnvironment.js"
import { is_backend_server_loaded, is_desktop } from "../components/DesktopInterface.js"
import { pack, unpack } from "./MsgPack.js"
import "./Polyfill.js"
import { Stack } from "./Stack.js"
import { with_query_params } from "./URLTools.js"
import { ask, dismiss, reload_prompt, tell } from "./dialogs.js"
import { t } from "./lang.js"

const reconnect_after_close_delay = 500

/** The error a request fails with when its socket closes before the reply, or is closed when it is sent (#584). */
export const connection_lost_message = "The connection to Ember was lost before it answered"

// Most requests are sent without waiting on the reply (an edit's
// update_notebook, a folded cell), so nothing catches this failure. It
// says only that the reconnect, which resyncs, is under way: not an error
// to report. The forms that wait on a reply catch it and say so.
if (typeof window !== "undefined") {
    window.addEventListener("unhandledrejection", (e) => {
        if (e.reason?.message === connection_lost_message) e.preventDefault()
    })
}

/**
 * After a failed connect the page waits before the next try: 1 s, then
 * twice as long each time, up to 5 s (#33).
 */
const retry_delay = (/** @type {number} */ failures) => Math.min(1000 * 2 ** (failures - 1), 5000)

/**
 * How long connects may keep failing before the page stops saying
 * "Reconnecting" and says it can't reach Ember at its address: a tab left
 * open after Ember stopped, after it started again on another port, or
 * after the tunnel to it closed has nothing to reconnect to (#33). Ember restarting on the same port
 * takes a few seconds, so this is well past that.
 */
const unreachable_after = 30 * 1000

/** Once the page has said so, it still tries this often, so it reconnects by itself if Ember comes back at the same address. */
const unreachable_retry_delay = 10 * 1000

/** How long one try may take to open its socket before it counts as failed. */
const connect_timeout_ms = 30 * 1000

/** The close code Ember's server uses when it refuses this page's secret: `WS_CLOSE_KEY_REFUSED` in R/server.R. */
const key_refused_close_code = 4403

const is_key_refused = (/** @type {any} */ e) => e instanceof CloseEvent && e.code === key_refused_close_code

/** Ember restarted (a new key) under this open page: retrying with the old key can never succeed. */
const tell_key_refused = () => {
    dismiss("ember-unreachable")
    return tell({ title: t("t_ember_key_refused_title"), body: t("t_ember_key_refused"), key: "ember-key-refused" })
}

/**
 * Nothing has answered at this page's address for `unreachable_after`.
 * "Try again" tries at once instead of waiting for the next background try.
 */
const ask_unreachable = (/** @type {() => void} */ retry_now) =>
    ask({
        title: t("t_ember_unreachable_title"),
        body: t("t_ember_unreachable", { address: window.location.host }),
        actions: [
            { label: t("t_ember_unreachable_retry"), value: "retry", primary: true },
            { label: t("t_close"), value: "close" },
        ],
        cancel_value: "close",
        key: "ember-unreachable",
    }).then((value) => {
        if (value === "retry") retry_now()
    })

/**
 * A delay that `wake()` can end early: the wait between connect tries,
 * which "Try again" cuts short.
 */
const wakeable_delay = () => {
    let wake_current = () => {}
    return {
        wait: (/** @type {number} */ ms) =>
            new Promise((resolve) => {
                const handle = setTimeout(resolve, ms)
                wake_current = () => {
                    clearTimeout(handle)
                    resolve(undefined)
                }
            }),
        wake: () => wake_current(),
    }
}

/**
 * Return a promise that resolves to:
 *  - the resolved value of `promise`
 *  - an error after `time_ms` milliseconds
 * whichever comes first.
 * @template T
 * @param {Promise<T>} promise
 * @param {number} time_ms
 * @returns {Promise<T>}
 */
export const timeout_promise = (promise, time_ms) =>
    Promise.race([
        promise,
        new Promise((resolve, reject) => {
            setTimeout(() => {
                reject(new Error("Promise timed out."))
            }, time_ms)
        }),
    ])

/**
 * Keep calling @see f until it resolves, with a delay before each try.
 * @param {Function} f Function that returns a promise
 * @param {Number} time_ms Timeout for each call to @see f
 */
const retry_until_resolved = (f, time_ms) =>
    timeout_promise(f(), time_ms).catch((e) => {
        console.error(e)
        console.error("godverdomme")
        return retry_until_resolved(f, time_ms)
    })

/**
 * @template T
 * @returns {{current: Promise<T>, resolve: (value: T) => void, reject: (error: any) => void }}
 */
export const resolvable_promise = () => {
    let resolve = () => {}
    let reject = () => {}
    const p = new Promise((_resolve, _reject) => {
        //@ts-ignore
        resolve = _resolve
        reject = _reject
    })
    return {
        current: p,
        resolve: resolve,
        reject: reject,
    }
}

export const assert_not_null = (x) => {
    if (x == null) throw new Error("Unexpected null value")
    return x
}

/**
 * @returns {string}
 */
const get_unique_short_id = () => assert_not_null(crypto.getRandomValues(new Uint32Array(1))[0]).toString(36)

const socket_is_alright = (socket) => socket.readyState == WebSocket.OPEN || socket.readyState == WebSocket.CONNECTING

const socket_is_alright_with_grace_period = (socket) =>
    new Promise((res) => {
        if (socket_is_alright(socket)) {
            res(true)
        } else {
            setTimeout(() => {
                res(socket_is_alright(socket))
            }, 1000)
        }
    })

const try_close_socket_connection = (/** @type {WebSocket} */ socket) => {
    socket.onopen = () => {
        try_close_socket_connection(socket)
    }
    socket.onmessage = socket.onclose = socket.onerror = null
    try {
        socket.close(1000, "byebye")
    } catch (ex) {}
}

/**
 * Open a 'raw' websocket connection to an API with MessagePack serialization. The method is asynchonous, and resolves to a @see WebsocketConnection when the connection is established.
 * @typedef {{socket: WebSocket, send: Function}} WebsocketConnection
 * @param {string} address The WebSocket URL
 * @param {{on_message: Function, on_socket_close:Function}} callbacks
 * @param {number} timeout_s Timeout for creating the websocket connection (seconds)
 * @returns {Promise<WebsocketConnection>}
 */
const create_ws_connection = (address, { on_message, on_socket_close, on_event = (/** @type {string} */ what) => {} }, timeout_s = connect_timeout_ms / 1000) => {
    return new Promise((resolve, reject) => {
        const socket = new WebSocket(address)
        // Messages arrive already read, as ArrayBuffers, not as Blobs to read
        // later. WebKit fails a Blob read that a reload or navigation
        // interrupts, which showed as "Failed to unpack message" and a page
        // error when a reload caught a message being read (#385).
        socket.binaryType = "arraybuffer"

        let has_been_open = false

        const timeout_handle = setTimeout(() => {
            console.warn("Creating websocket timed out", new Date().toLocaleTimeString())
            on_event(`socket timed out, ready state ${socket.readyState}`)
            try_close_socket_connection(socket)
            reject("Socket timeout")
        }, timeout_s * 1000)

        const send_encoded = (message) => {
            const encoded = pack(message)
            if (socket.readyState === WebSocket.CLOSED || socket.readyState === WebSocket.CLOSING) throw new Error("Socket is closed")
            socket.send(encoded)
        }

        let last_task = Promise.resolve()
        socket.onmessage = (event) => {
            // they arrive in order (WS guarantees this), i.e. this socket.onmessage event gets fired with the message events in the right order
            // the task queue keeps them handled in that order
            // `event.data` is already an ArrayBuffer (`binaryType` above), so there is no async read left to fail or to finish out of order
            const data = event.data
            last_task = last_task.then(async () => {
                try {
                    const message = unpack(new Uint8Array(data))

                    try {
                        on_message(message)
                    } catch (process_err) {
                        console.error(
                            "Failed to process message from websocket. Please open an issue on https://github.com/JuliaPluto/Pluto.jl with this info:",
                            process_err,
                            { message }
                        )
                        reload_prompt()
                    }
                } catch (unpack_err) {
                    console.error(
                        "Failed to unpack message from websocket. Please open an issue on https://github.com/JuliaPluto/Pluto.jl with this info:",
                        unpack_err,
                        { event }
                    )
                    reload_prompt()
                }
            })
        }

        socket.onerror = async (e) => {
            console.error(`Socket did an oopsie - ${e.type}`, new Date().toLocaleTimeString(), "was open:", has_been_open, e)
            on_event(`socket error, was open: ${has_been_open}`)

            const alright = await socket_is_alright_with_grace_period(socket)
            on_event(`socket error, after its grace period: ${alright ? "recovered" : has_been_open ? "closing" : "failing the try"}`)
            if (alright) {
                console.log("The socket somehow recovered from an error?! Onbegrijpelijk")
                console.log(socket)
                console.log(socket.readyState)
            } else {
                if (has_been_open) {
                    on_socket_close()
                    try_close_socket_connection(socket)
                } else {
                    reject(e)
                }
            }
        }
        socket.onclose = async (e) => {
            console.warn(`Socket did an oopsie - ${e.type}`, new Date().toLocaleTimeString(), "was open:", has_been_open, e)
            on_event(`socket close ${e.code}, was open: ${has_been_open}`)

            if (has_been_open) {
                on_socket_close(e)
                try_close_socket_connection(socket)
            } else {
                reject(e)
            }
        }
        socket.onopen = () => {
            console.log("Socket opened", new Date().toLocaleTimeString())
            on_event("socket open")
            clearInterval(timeout_handle)
            has_been_open = true
            resolve({
                socket: socket,
                send: send_encoded,
            })
        }
        console.log("Waiting for socket to open...", new Date().toLocaleTimeString())
    })
}

let next_tick_promise = () => {
    return new Promise((resolve) => setTimeout(resolve, 0))
}

/**
 * batched_updates(send) creates a wrapper around the real send, and understands the update_notebook messages.
 * Whenever those are sent, it will wait for a "tick" (basically the end of the code running now)
 * and then send all updates from this tick at once. We use this to fix https://github.com/fonsp/Pluto.jl/issues/928
 *
 * I need to put it here so other code,
 * like running cells, will also wait for the updates to complete.
 * I SHALL MAKE IT MORE COMPLEX! (https://www.youtube.com/watch?v=aO3JgPUJ6iQ&t=195s)
 * @param {import("./PlutoConnectionSendFn").SendFn} send
 * @returns {import("./PlutoConnectionSendFn").SendFn}
 */
const batched_updates = (send) => {
    let current_combined_updates_promise = null
    let current_combined_updates = []
    let current_combined_notebook_id = null

    let batched = async (message_type, body, metadata, no_broadcast) => {
        if (message_type === "update_notebook") {
            if (current_combined_notebook_id != null && current_combined_notebook_id != metadata.notebook_id) {
                // prettier-ignore
                throw new Error("Switched notebook inbetween same-tick updates??? WHAT?!?!")
            }
            current_combined_updates = [...current_combined_updates, ...body.updates]
            current_combined_notebook_id = metadata.notebook_id

            if (current_combined_updates_promise == null) {
                current_combined_updates_promise = next_tick_promise().then(async () => {
                    let sending_current_combined_updates = current_combined_updates
                    current_combined_updates_promise = null
                    current_combined_updates = []
                    current_combined_notebook_id = null
                    return await send(message_type, { updates: sending_current_combined_updates }, metadata, no_broadcast)
                })
            }

            return await current_combined_updates_promise
        } else {
            return await send(message_type, body, metadata, no_broadcast)
        }
    }

    return batched
}

export const ws_address_from_base = (/** @type {string | URL} */ base_url) => {
    const ws_url = new URL("./", base_url)
    ws_url.protocol = ws_url.protocol.replace("http", "ws")

    // if the original URL had a secret in the URL, we can also add it here:
    const ws_url_with_secret = with_query_params(ws_url, { secret: new URL(base_url).searchParams.get("secret") })

    return ws_url_with_secret
}

export const auth_check_url_from_ws = (/** @type {string | URL} */ ws_url) => {
    const auth_url = new URL("./auth-check", ws_url)
    auth_url.protocol = auth_url.protocol.replace("ws", "http")
    return auth_url.toString()
}

const default_ws_address = () => ws_address_from_base(window.location.href)

/**
 * @typedef PlutoConnection
 * @type {{
 *  session_options: Record<string,any>,
 *  send: import("./PlutoConnectionSendFn").SendFn,
 *  kill: (allow_reconnect?: boolean) => void,
 *  version_info: {
 *      julia: string,
 *      pluto: string,
 *      dismiss_update_notification: boolean,
 *  },
 *  notebook_exists: boolean,
 *  message_log: import("./Stack.js").Stack<any>,
 * }}
 */

/**
 * @typedef PlutoMessage
 * @type {any}
 */

/**
 * Open a connection with Pluto, that supports a question-response mechanism. The method is asynchonous, and resolves to a @see PlutoConnection when the connection is established.
 *
 * The server can also send messages to all clients, without being requested by them. These end up in the @see on_unrequested_update callback.
 *
 * @param {{
 *  on_unrequested_update: (message: PlutoMessage, by_me: boolean) => void,
 *  on_reconnect: () => Promise<boolean>,
 *  on_connection_status: (connection_status: boolean, hopeless: boolean) => void,
 *  on_key_refused?: () => void,
 *  on_unreachable?: (unreachable: boolean) => void,
 *  connect_metadata?: Object,
 *  ws_address?: String,
 * }} options
 * @return {Promise<PlutoConnection>}
 */
export const create_pluto_connection = async ({
    on_unrequested_update,
    on_reconnect,
    on_connection_status,
    on_key_refused = () => {},
    on_unreachable = () => {},
    connect_metadata = {},
    ws_address = default_ws_address(),
}) => {
    let ws_connection = /** @type {WebsocketConnection?} */ (null) // will be defined later i promise
    const message_log = new Stack(100)
    // @ts-ignore
    window.pluto_get_message_log = () => message_log.get()
    // Where the connection is, for a test to wait on instead of a fixed
    // time (tests/e2e/tests/dead-port.test.mjs): "trying" while a try is
    // out, "waiting" between tries, "syncing" while a reconnect catches up,
    // "connected", or "key refused"; and how many key checks (which run
    // beside the wait after a failed try) are still out. Like
    // window.ember_docs (LiveDocsTab.js).
    // `events`: the last 200 things that happened to the connection
    // (sockets opening, erroring and closing, key checks and what they
    // found), oldest first, for a test that fails to say why (#491).
    const connection = { state: "trying", key_checks_out: 0, events: /** @type {string[]} */ ([]) }
    // @ts-ignore
    window.ember_connection = connection
    const note_event = (/** @type {string} */ what) => {
        connection.events.push(`${Date.now()} ${connection.state}: ${what}`)
        if (connection.events.length > 200) connection.events.shift()
    }
    let auto_reconnect = true

    // Connect tries that failed in a row, how long they have been failing,
    // and whether the page has said it can't reach Ember here (#33).
    //
    // `failing_for` is counted from the page's own waits and tries, each
    // at most as long as it can take, not from the wall clock: a computer
    // that sleeps mid-outage wakes with the clock moved on by the whole
    // sleep, and its first try fails while the network comes back, which
    // must not count as 30 s of failures (#99). A sleep during a wait adds
    // at most that wait; one during a pending try can still count as a
    // full try (`connect_timeout_ms`), since the try's own timeout fires
    // late on wake. Tries rarely hang: a dead port or a dropped tunnel
    // refuses at once, and a try only hangs when the network is gone.
    let failures = 0
    let failing_for = 0
    let try_started_at = Date.now()
    let unreachable = false
    let retried_by_hand = false
    let reconnecting = false
    const between_tries = wakeable_delay()
    const retry_now = () => {
        retried_by_hand = true
        between_tries.wake()
    }
    const connected_again = () => {
        connection.state = reconnecting ? "syncing" : "connected"
        failures = 0
        failing_for = 0
        retried_by_hand = false
        if (unreachable) {
            unreachable = false
            dismiss("ember-unreachable")
            on_unreachable(false)
        }
    }
    const stop_unreachable = () => {
        if (unreachable) {
            unreachable = false
            on_unreachable(false)
        }
    }
    /** After a failed try that wasn't a refused key: say Ember can't be reached here once it has failed long enough, and again after a "Try again" that failed. */
    const note_failure = () => {
        failures += 1
        // From the first failure on, as before: the try that found the
        // outage doesn't count.
        if (failures > 1) failing_for += Math.max(0, Math.min(Date.now() - try_started_at, connect_timeout_ms))
        const long_enough = failing_for >= unreachable_after
        if ((long_enough && !unreachable) || (unreachable && retried_by_hand)) {
            unreachable = true
            on_unreachable(true)
            ask_unreachable(retry_now)
        }
        retried_by_hand = false
    }
    /** The wait before the next try, counted as at most its own length. */
    const wait_between_tries = async () => {
        connection.state = "waiting"
        const ms = unreachable ? unreachable_retry_delay : retry_delay(failures)
        const started = Date.now()
        await between_tries.wait(ms)
        failing_for += Math.max(0, Math.min(Date.now() - started, ms))
    }

    /** The page's key was refused: Ember restarted at this address. Stop retrying and say so. */
    const say_key_refused = () => {
        note_event("key refused")
        stop_unreachable()
        connection.state = "key refused"
        on_key_refused()
        tell_key_refused()
    }
    /**
     * After a try that failed before Ember's "connect" reply, whether it
     * failed because the key was refused; otherwise counts the failure and
     * waits for the next try. A socket that never opened and one that
     * opened and then dropped are the same failure here: a 4403 close can
     * reach the page as a 1006 drop either way (#491).
     *
     * The key check runs alongside the retry delay, not before it, so a
     * check that hangs never holds up the retry. If it finds the key
     * refused before the delay is up, that is the same restart as a 4403
     * close.
     */
    const failed_try_found_key_refused = async (/** @type {any} */ ex) => {
        note_event(`failed try: ${ex instanceof CloseEvent ? `close ${ex.code}` : ex == null ? "no event" : String(ex?.type ?? ex)}`)
        if (is_key_refused(ex)) return true
        note_failure()
        connection.key_checks_out += 1
        return await Promise.race([
            key_check_refused(ws_address, ex, note_event)
                .catch((e) => {
                    note_event(`key check failed: ${e}`)
                    return false
                })
                .finally(() => (connection.key_checks_out -= 1))
                .then((r) => (r ? true : new Promise(() => {}))),
            wait_between_tries().then(() => {
                note_event("waited for the next try")
                return false
            }),
        ])
    }

    const client = {
        // send: null,
        // session_options: null,
        version_info: {
            julia: "unknown",
            pluto: "unknown",
            dismiss_update_notification: false,
        },
        notebook_exists: true,
        // kill: null,
        message_log,
    } // same

    const client_id = get_unique_short_id()
    const sent_requests = new Map()

    /** @type {import("./PlutoConnectionSendFn").SendFn} */
    const send = async (message_type, body = {}, metadata = {}, no_broadcast = true) => {
        if (ws_connection == null) {
            throw new Error("No connection established yet")
        }
        const request_id = get_unique_short_id()

        // This data will be sent:
        const message = {
            type: message_type,
            client_id: client_id,
            request_id: request_id,
            body: body,
            ...metadata,
        }

        let p = resolvable_promise()

        sent_requests.set(request_id, {
            type: message_type,
            answer: (response_message) => {
                p.resolve(response_message)
                if (no_broadcast === false) {
                    on_unrequested_update(response_message, true)
                }
            },
            lose: () => p.reject(new Error(connection_lost_message)),
        })

        try {
            ws_connection.send(message)
        } catch (e) {
            // The socket closed and the next one isn't open yet.
            sent_requests.delete(request_id)
            throw new Error(connection_lost_message)
        }
        return await p.current
    }

    client.send = batched_updates(send)

    const connect = async () => {
        // Whether this socket got its "connect" reply: one that opens and
        // closes before that is a failed try, like one that never opens.
        let said_hello = false
        try_started_at = Date.now()
        connection.state = "trying"
        try {
            ws_connection = await create_ws_connection(String(ws_address), {
                on_event: note_event,
                on_message: (update) => {
                    message_log.push(update)

                    const by_me = update.initiator_id == client_id
                    const request_id = update.request_id

                    if (by_me && request_id) {
                        const request = sent_requests.get(request_id)
                        if (request) {
                            request.answer(update)
                            sent_requests.delete(request_id)
                            return
                        }
                    }
                    on_unrequested_update(update, by_me)
                },
                on_socket_close: async (/** @type {CloseEvent=} */ e) => {
                    note_event(`socket lost: ${e ? `close ${e.code}` : "no event"}, said hello: ${said_hello}`)
                    // No reply comes on a closed socket, so a request still
                    // waiting for one fails now rather than never settling and
                    // leaving whatever awaits it (a dialog's Save) stuck (#584).
                    // Not the hello: this handler reconnects for that one.
                    for (const [id, request] of sent_requests) {
                        if (request.type === "connect") continue
                        sent_requests.delete(id)
                        request.lose()
                    }
                    on_connection_status(false, false)
                    if (is_key_refused(e)) {
                        say_key_refused()
                        return
                    }
                    if (!auto_reconnect) {
                        console.log("Auto-reconnect is disabled, so we're not reconnecting")
                        on_connection_status(false, true)
                        return
                    }

                    console.log(`Starting new websocket`, new Date().toLocaleTimeString())
                    reconnecting = true
                    if (said_hello) {
                        connection.state = "waiting"
                        await Promises.delay(reconnect_after_close_delay)
                    } else if (await failed_try_found_key_refused(e)) {
                        say_key_refused()
                        return
                    }
                    await connect() // reconnect!
                    // A try that found the key refused ends the reconnect:
                    // there is no socket to resync on, and sending on the
                    // one that closed throws (#510).
                    if (connection.state === "key refused") return

                    console.log(`Starting state sync`, new Date().toLocaleTimeString())
                    const accept = await on_reconnect()
                    console.log(`State sync ${accept ? "" : "not "}successful`, new Date().toLocaleTimeString())
                    reconnecting = false
                    if (connection.state === "syncing") connection.state = "connected"
                    on_connection_status(accept, false)
                    if (!accept) {
                        reload_prompt()
                    }
                },
            })

            // let's say hello
            console.log("Hello?")
            const u = await send("connect", {}, connect_metadata)
            console.log("Hello!")
            said_hello = true
            connected_again()
            client.kill = (allow_reconnect = true) => {
                auto_reconnect = allow_reconnect
                if (ws_connection) ws_connection.socket.close()
            }
            client.session_options = u.message.session_options
            client.version_info = u.message.version_info
            client.notebook_exists = u.message.notebook_exists

            console.log("Client object: ", client)

            if (connect_metadata.notebook_id != null && !u.message.notebook_exists) {
                on_connection_status(false, true)
                return {}
            }
            on_connection_status(true, false)

            const ping = () => {
                send("ping", {}, {})
                    .then(() => {
                        // Ping faster than timeout?
                        setTimeout(ping, 28 * 1000)
                    })
                    .catch(() => undefined)
            }
            ping()

            return u.message
        } catch (ex) {
            console.error("connect() failed", ex)
            note_event("try failed")
            if (await failed_try_found_key_refused(ex)) {
                on_connection_status(false, false)
                say_key_refused()
                return {}
            }
            return await connect()
        }
    }

    await connect()

    return /** @type {PlutoConnection} */ (client)
}

/**
 * Whether a connection that failed with 1006 did so because the server
 * refuses this page's key. Ember's server refuses only a key from an
 * earlier session, so this is the same restart a 4403 close reports. It
 * can arrive first: a socket that dropped while the old server was gone
 * gets its answer from the new one.
 */
const key_check_refused = async (/** @type {string | URL} */ ws_url, ex, note = (/** @type {string} */ what) => {}) => {
    if (!(ex instanceof CloseEvent) || ex.code !== 1006) {
        note("no key check: not a 1006 close")
        return false
    }
    const response = await fetch(auth_check_url_from_ws(ws_url))
    note(`key check: ${response.status}`)
    if (response.status !== 403 && response.status !== 401) return false
    return !is_desktop() || (await is_backend_server_loaded())
}
