# CIRRUS desktop: keep a login shell out of the shared home.
#
# The desktop's own processes inherit all of this from entrypoint.sh, so in the
# normal case this file changes nothing. It exists for the shells that do not
# inherit it: anything started with `bash -l` or `su -`, and anything launched
# after a user has edited their own dotfiles. Without it such a shell resolves
# XDG to $HOME/.cache and $HOME/.config, which are on GLADE and shared with
# Casper and Derecho.
#
# Only ever fills in a value that is missing -- a session that already set these
# is the authority, and this must not overwrite it.

if [ -n "${CIRRUS_DESKTOP_STATE_DIR:-}" ] && [ -d "${CIRRUS_DESKTOP_STATE_DIR}" ]; then
    : "${XDG_CACHE_HOME:=${CIRRUS_DESKTOP_STATE_DIR}/cache}"
    : "${XDG_STATE_HOME:=${CIRRUS_DESKTOP_STATE_DIR}/state}"
    : "${XDG_RUNTIME_DIR:=${CIRRUS_DESKTOP_STATE_DIR}/run}"
    : "${TMPDIR:=${CIRRUS_DESKTOP_STATE_DIR}/tmp}"
    export XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR TMPDIR
fi

if [ -n "${CIRRUS_DESKTOP_PERSIST_DIR:-}" ] && [ -d "${CIRRUS_DESKTOP_PERSIST_DIR}" ]; then
    : "${XDG_CONFIG_HOME:=${CIRRUS_DESKTOP_PERSIST_DIR}/config}"
    : "${XDG_DATA_HOME:=${CIRRUS_DESKTOP_PERSIST_DIR}/data}"
    export XDG_CONFIG_HOME XDG_DATA_HOME
fi
