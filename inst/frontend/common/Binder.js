export const BackendLaunchPhase = {
    wait_for_user: 0,
    requesting: 0.4,
    created: 0.6,
    responded: 0.7,
    notebook_running: 0.9,
    ready: 1.0,
}

export const trailingslash = (s) => (s.endsWith("/") ? s : s + "/")
