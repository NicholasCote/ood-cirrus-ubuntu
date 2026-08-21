#!/usr/bin/env bash
#
# CIRRUS Ubuntu Desktop entrypoint.  Usage: entrypoint.sh {desktop|bootstrap}
#
# What this does, in order:
#   1. give the runtime uid a real name (nss_wrapper)
#   2. keep everything this session writes out of the shared GLADE home
#   3. resolve the session password and the proxy prefix
#   4. bring up the session bus, the X server, XFCE and the password gate
#   5. supervise: cull an idle session, cap a long one, report the right status
#
# Nothing here chowns anything, and nothing writes into the image.
#
# Logging goes to stderr throughout. There is no syslog daemon in a container --
# which is not an abstract point here: dbus-launch starts the session bus as
# `dbus-daemon --syslog`, and everything it has to say is therefore discarded,
# so this script runs dbus-daemon itself. And the messages that matter most,
# the ones about a password that never arrived or a prefix that was never
# computed, are all emitted before anything binds a port.

set -euo pipefail

PROG="cirrus-desktop"
log()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
warn() { printf '%s: WARNING: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat >&2 <<USAGE
usage: entrypoint.sh desktop
       entrypoint.sh bootstrap [command...]

  desktop     Start the XFCE desktop behind KasmVNC (the OOD app path).

  bootstrap   Run the common bootstrap only -- runtime uid, home isolation,
              password, proxy prefix -- then exec command... if one was given,
              or print a summary and exit. This is what image/test/acceptance.sh
              drives, and it is the way to reproduce a session's environment by
              hand without starting an X server.
USAGE
}

MODE="${1:-desktop}"
case "$MODE" in
    desktop|bootstrap) shift || true ;;
    -h|--help) usage; exit 2 ;;
    *) printf '%s: ERROR: unknown mode: %s\n' "$PROG" "$MODE" >&2; usage; exit 2 ;;
esac

# ===========================================================================
# 1. Session-local state
# ===========================================================================

STATE_DIR="${CIRRUS_DESKTOP_STATE_DIR:-/tmp/cirrus-desktop}"
export CIRRUS_DESKTOP_STATE_DIR="$STATE_DIR"

# A pod always has $HOME set from the spec, but a bare `podman run --user N:N`
# may not, and then every ~-relative path expands to "/".
if [ -n "${HOME:-}" ] && [ ! -d "$HOME" ]; then
    mkdir -p -- "$HOME" 2>/dev/null || true
fi
if [ -z "${HOME:-}" ] || [ ! -d "${HOME:-}" ]; then
    warn "\$HOME is unset or unusable (${HOME:-<unset>}); using ${STATE_DIR}/home"
    HOME="${STATE_DIR}/home"
    export HOME
fi

mkdir -p \
    "${STATE_DIR}" \
    "${STATE_DIR}/cache" \
    "${STATE_DIR}/state" \
    "${STATE_DIR}/tmp" \
    "${STATE_DIR}/run" 2>/dev/null || true
# XDG_RUNTIME_DIR must be 0700 or dbus, and anything else that checks, complains
# on every start-up.
chmod 0700 "${STATE_DIR}/run" 2>/dev/null || true

# Both are hardcoded in libX11 and libICE, and neither exists in a fresh /tmp.
# As an unprivileged uid the failure is
#   _XSERVTransmkdir: ERROR: euid != 0,directory /tmp/.X11-unix will not be created.
# Created in the image as well; done again here because a pod may have a volume
# mounted over /tmp, and then the image's copies are not there any more.
for d in /tmp/.X11-unix /tmp/.ICE-unix; do
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
done

# ===========================================================================
# 2. Runtime uid
#
# OOD sets runAsUser/runAsGroup to the user's real NFS uid/gid, which has no
# entry in this image's /etc/passwd. A desktop needs the name in more places
# than an IDE does: the terminal prompt, `whoami`, git's committer identity,
# ssh's default user, xfce4-session's own "log out <name>" menu, and Thunar's
# idea of where home is.
# ===========================================================================

setup_nss_wrapper() {
    local uid gid lib want_name want_group cur_name cur_group
    local passwd_file group_file need_passwd=0 need_group=0
    uid="$(id -u)"
    gid="$(id -g)"

    # OOD sets USER, NB_USER and GROUP in the pod spec, and it is the authority:
    # the container has no way to know any of them.
    want_name="${USER:-${NB_USER:-}}"
    case "${want_name}" in ''|*[!a-zA-Z0-9._-]*) want_name="" ;; esac
    [ -n "$want_name" ] || want_name="desktop-${uid}"
    want_group="${GROUP:-}"
    case "${want_group}" in *[!a-zA-Z0-9._-]*) want_group="" ;; esac

    # `|| true` on both, and it is load-bearing. With no entry getent exits 2;
    # under `set -e` with `pipefail` that kills this script here -- before it
    # has logged a single line, so the session dies with an empty pod log and no
    # clue. That is precisely the Kubernetes case, where nothing has synthesised
    # an entry.
    cur_name="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1 || true)"
    cur_group="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"

    # "Does an entry exist" is the wrong test. Container runtimes synthesise one
    # whose *name is the uid* -- verified here under podman:
    #   $ podman run --user 54321:54321 --entrypoint getent <image> passwd 54321
    #   54321:*:54321:54321:container user:/:/bin/sh
    # It satisfies an existence check while being useless: getpwuid returns
    # "54321", so the prompt, whoami, git and the session's own user display all
    # show a number, and the login shell is /bin/sh. Treat an all-digits name as
    # no name at all.
    if [ -z "$cur_name" ] || [ "$cur_name" = "$uid" ]; then
        need_passwd=1
    else
        case "$cur_name" in
            *[!0-9]*) : ;;          # has a non-digit: a real name, leave it alone
            *) need_passwd=1 ;;     # all digits: the uid wearing a name's clothes
        esac
    fi

    # Likewise the group: gid 1000 resolves to the image's own "ubuntu" group,
    # so without this a user whose group is ncar reports gid=1000(ubuntu) in
    # every terminal.
    if [ -n "$want_group" ] && [ "$cur_group" != "$want_group" ]; then
        need_group=1
    fi

    if [ "$need_passwd" -eq 0 ] && [ "$need_group" -eq 0 ]; then
        CIRRUS_DESKTOP_USER="$cur_name"
        return 0
    fi

    lib="$(cat /opt/cirrus-desktop/nss_wrapper_lib 2>/dev/null || true)"
    if [ -z "$lib" ] || [ ! -r "$lib" ]; then
        warn "libnss_wrapper.so was not found; uid ${uid} will resolve as"
        warn "'${cur_name:-<unresolved>}'. Every terminal prompt will show a number and"
        warn "git will refuse to commit. This is an image bug, not a site problem."
        CIRRUS_DESKTOP_USER="${cur_name:-$want_name}"
        return 0
    fi

    passwd_file="${STATE_DIR}/passwd"
    group_file="${STATE_DIR}/group"

    # Existing entries for this uid/gid are filtered out rather than appended
    # after: nss_wrapper returns the FIRST match, so leaving the runtime's
    # numeric line in place would win over ours and nothing would change.
    #
    # `|| true` again: grep exits 1 when it filters everything out, which under
    # pipefail would end the script.
    grep -v "^[^:]*:[^:]*:${uid}:" /etc/passwd > "$passwd_file" 2>/dev/null || true
    # /bin/bash, not the synthesised /bin/sh. xfce4-terminal runs the shell from
    # the passwd entry, and /bin/sh here is dash: no readline, so the arrow keys
    # emit ^[[A instead of walking history -- a terminal that looks broken to
    # anyone who has used one before.
    printf '%s:x:%s:%s:CIRRUS desktop user:%s:/bin/bash\n' \
        "$want_name" "$uid" "$gid" "$HOME" >> "$passwd_file"

    if [ -n "$want_group" ]; then
        grep -v "^[^:]*:[^:]*:${gid}:" /etc/group > "$group_file" 2>/dev/null || true
        printf '%s:x:%s:\n' "$want_group" "$gid" >> "$group_file"
    else
        cp /etc/group "$group_file" 2>/dev/null || : > "$group_file"
        getent group "$gid" >/dev/null 2>&1 || printf '%s:x:%s:\n' "$want_name" "$gid" >> "$group_file"
    fi

    export NSS_WRAPPER_PASSWD="$passwd_file"
    export NSS_WRAPPER_GROUP="$group_file"
    export LD_PRELOAD="${lib}${LD_PRELOAD:+:${LD_PRELOAD}}"
    export USER="$want_name"
    export LOGNAME="${LOGNAME:-$want_name}"
    CIRRUS_DESKTOP_USER="$want_name"
    log "uid ${uid} resolves as '${want_name}'${want_group:+, gid ${gid} as '${want_group}'} (via nss_wrapper)"
}
CIRRUS_DESKTOP_USER=""
setup_nss_wrapper
export CIRRUS_DESKTOP_USER

# xfce4-terminal and anything else that asks reads $SHELL before the passwd
# entry. Their real login shell on this platform is often tcsh, which is not
# installed here, so it is deliberately not copied from anywhere.
export SHELL=/bin/bash

# ===========================================================================
# 3. Home isolation
#
# $HOME is GLADE over NFS, shared with Casper and Derecho. A desktop environment
# writes far more into a home than an IDE does, and this section is sized
# accordingly. Measured on this image with no redirection at all -- one XFCE
# session, nothing opened by hand, everything below appeared in $HOME:
#
#   .ICEauthority
#   .cache/sessions
#   .config/Thunar/uca.xml
#   .config/user-dirs.dirs  .config/user-dirs.locale
#   .config/xfce4/{desktop,panel,xfconf,xfwm4}/...      (13 files)
#   .dbus/session-bus/<machine-id>-1
#   .local/share
#   Desktop  Documents  Downloads  Music  Pictures  Public  Templates  Videos
#
# Five separate mechanisms are needed, because those writers do not all read the
# same variable:
#
#   XDG_*             .cache, .config, .local/share, and everything under them
#   ICEAUTHORITY      .ICEauthority, which is not XDG at all
#   the session bus   .dbus, which dbus-launch writes and dbus-daemon does not
#   /etc/xdg/user-dirs.conf + a pinned user-dirs.dirs
#                     the eight bare directories, which are the worst of it:
#                     they are visible from every login node forever
#   XAUTHORITY        .Xauthority, which nothing wrote in the measurement above
#                     but which any X client may
#
# Split between two destinations on purpose:
#
#   $HOME/cirrus-desktop/  what is worth keeping between sessions -- panel
#                          layout, theme, keyboard shortcuts, the Desktop folder
#   /tmp/cirrus-desktop/   everything else -- caches, runtime state, sockets
#
# The name is cirrus-desktop and NOT desktop: XFCE creates a Desktop folder of
# its own through the XDG user dirs, and two paths differing only in case in a
# shared home is a trap that only shows up on a case-insensitive client.
# ===========================================================================

PERSIST_DIR="${CIRRUS_DESKTOP_PERSIST_DIR:-${HOME}/cirrus-desktop}"

# Backstop, whoever set it and however. The failure this prevents is silent:
# $HOME/.config and $HOME/.local/share are read by every desktop the user runs
# anywhere, and $HOME itself would scatter everything.
persist_dir_is_safe() {
    local d="${1%/}"
    case "$d" in
        ""|"/"|"${HOME%/}") return 1 ;;   # home itself, or the root
        "${HOME%/}"/.*)     return 1 ;;   # any dotfile directly in home
        */.config|*/.config/*|*/.local|*/.local/*|*/.cache|*/.cache/*) return 1 ;;
    esac
    # Case-insensitively against the XDG user dirs XFCE would otherwise create,
    # so that "$HOME/desktop" cannot end up as a sibling of "$HOME/Desktop".
    # Two paths differing only in case in a shared home is a trap that shows up
    # for the first time on whichever client mounts it case-insensitively.
    case "$(printf '%s' "${d##*/}" | tr '[:upper:]' '[:lower:]')" in
        desktop|documents|downloads|music|pictures|public|templates|videos) return 1 ;;
    esac
    return 0
}
if ! persist_dir_is_safe "$PERSIST_DIR"; then
    warn "persist directory ${PERSIST_DIR} is a path your Casper and Derecho sessions"
    warn "also read, or collides with a folder XFCE creates itself. Using"
    warn "${HOME}/cirrus-desktop instead, which is this app's own directory."
    PERSIST_DIR="${HOME}/cirrus-desktop"
fi
if ! mkdir -p -- "$PERSIST_DIR" 2>/dev/null; then
    warn "could not create ${PERSIST_DIR}; nothing will persist past this session."
    warn "Your home directory is not writable here -- usually a failed NFS mount."
    PERSIST_DIR="${STATE_DIR}/persist"
    mkdir -p -- "$PERSIST_DIR"
fi
export CIRRUS_DESKTOP_PERSIST_DIR="$PERSIST_DIR"

# --- XDG: config and data persist, everything else is scratch --------------
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${PERSIST_DIR}/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${PERSIST_DIR}/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${STATE_DIR}/cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${STATE_DIR}/state}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${STATE_DIR}/run}"
export TMPDIR="${TMPDIR:-${STATE_DIR}/tmp}"
if ! mkdir -p -- "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" 2>/dev/null; then
    warn "could not create configuration under ${PERSIST_DIR}; desktop settings will"
    warn "not persist between sessions."
fi

# --- the X and ICE authority files, which are not XDG ----------------------
#
# .ICEauthority appeared in $HOME in the measurement above; libICE reads
# $ICEAUTHORITY first and only falls back to $HOME/.ICEauthority. .Xauthority
# did not appear -- Xkasmvnc with -SecurityTypes None writes no cookie -- but any
# X client may create one, and a variable costs nothing.
export ICEAUTHORITY="${ICEAUTHORITY:-${STATE_DIR}/ICEauthority}"
export XAUTHORITY="${XAUTHORITY:-${STATE_DIR}/Xauthority}"

# --- the session bus ------------------------------------------------------
#
# Addressed explicitly, and started by this script rather than by dbus-launch,
# for two reasons that are both about files:
#
#   * dbus-launch's autolaunch path writes
#     $HOME/.dbus/session-bus/<machine-id>-<display> -- observed in the
#     measurement above;
#   * it starts the daemon as `dbus-daemon --syslog --fork`, and there is no
#     syslog daemon in a container, so the bus's diagnostics go nowhere.
#
# The socket lives in XDG_RUNTIME_DIR, which is under /tmp.
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# --- the XDG user directories ---------------------------------------------
#
# /etc/xdg/user-dirs.conf in the image sets enabled=False, which stops
# xdg-user-dirs-update from creating the eight directories. This pins what the
# READERS see: GTK's file chooser, Thunar's sidebar and xfdesktop's icon view
# all resolve these names, and with no file they resolve to $HOME/Desktop,
# $HOME/Documents and so on -- which xfdesktop would then create itself.
#
# Only Desktop gets a real directory, inside this app's own persist directory,
# because xfdesktop genuinely needs somewhere to put icons. Everything else
# points at $HOME: the spec treats a user dir equal to $HOME as disabled, and
# GTK hides those from its sidebar, so the entries vanish rather than pointing
# somewhere wrong.
#
# Written only if absent. A user who has moved their own Downloads is the
# authority on where it goes.
seed_user_dirs() {
    local f="${XDG_CONFIG_HOME}/user-dirs.dirs"
    [ -e "$f" ] && return 0
    mkdir -p -- "$XDG_CONFIG_HOME" 2>/dev/null || return 0
    mkdir -p -- "${PERSIST_DIR}/Desktop" 2>/dev/null || true
    {
        printf '# Written by entrypoint.sh at first launch of the CIRRUS desktop.\n'
        printf '# Delete this file to have the desktop regenerate it.\n'
        printf 'XDG_DESKTOP_DIR="%s/Desktop"\n' "$PERSIST_DIR"
        # $HOME, i.e. "disabled" -- see the note above.
        local key
        for key in DOWNLOAD TEMPLATES PUBLICSHARE DOCUMENTS MUSIC PICTURES VIDEOS; do
            printf 'XDG_%s_DIR="%s"\n' "$key" "$HOME"
        done
    } > "$f" 2>/dev/null || warn "could not write ${f}; XFCE may create folders in your home"
    log "pinned the XDG user directories in ${f} (Desktop -> ${PERSIST_DIR}/Desktop)"
}
seed_user_dirs

# ===========================================================================
# 4. Session password
#
# Generated by the init-secret container into <pod>-secret, copied into the
# session ConfigMap by add-passwd-to-cfg, and projected here as a file.
# OnDemand reads the same Secret to build the Connect button, so both ends agree
# without the password ever being rendered into an app template or written to
# the user's home.
#
# The user never types it. That is the point: they have already authenticated to
# OnDemand, and the dashboard posts this on their behalf.
# ===========================================================================

PASSWORD_FILE_OUT="${STATE_DIR}/session-password"
KASM_PASSWD_FILE="${STATE_DIR}/kasmpasswd"
resolve_password() {
    local src="${CIRRUS_DESKTOP_PASSWORD_FILE:-}" i pw=""

    if [ "${CIRRUS_DESKTOP_AUTH:-password}" = "none" ]; then
        return 0
    fi
    if [ -z "$src" ]; then
        warn "CIRRUS_DESKTOP_AUTH=password but CIRRUS_DESKTOP_PASSWORD_FILE is unset."
        warn "Nobody can reach this session. Starting anyway so the log is readable."
        return 1
    fi

    # The wait is what makes this race-free. Volumes are projected before init
    # containers run, so the file is already here -- empty -- by the time
    # add-passwd-to-cfg edits the underlying ConfigMap. Kubelet re-projects
    # within a second or two, but "usually fast enough" is not a guarantee, and
    # losing that race silently produces a session whose Connect button is
    # rejected with no clue why. The startup probe in submit.yml.erb is sized to
    # cover this wait plus the X server and XFCE behind it.
    # Configurable only so the acceptance test can drive the give-up path in
    # seconds instead of two minutes. The default is the number that matters:
    # it has to be comfortably inside the startup probe's budget and comfortably
    # longer than a kubelet ConfigMap re-projection.
    local wait_secs="${CIRRUS_DESKTOP_PASSWORD_WAIT:-120}"
    case "$wait_secs" in ''|*[!0-9]*) wait_secs=120 ;; esac

    for i in $(seq 1 "$wait_secs"); do
        # `|| true` twice over: the file may not exist yet (grep exits 2) and
        # may exist with no password line (grep exits 1). Both are the normal
        # state of this loop, and both would end the script under set -e.
        pw="$(grep -m1 '^password=' "$src" 2>/dev/null | cut -d= -f2- || true)"
        [ -n "$pw" ] && break
        [ "$i" -eq 1 ] && log "waiting for the session password at ${src}"
        sleep 1
    done

    if [ -z "$pw" ]; then
        warn "no password appeared at ${src} after ${wait_secs}s."
        warn "The add-passwd-to-cfg init container did not write one. Check:"
        warn "    kubectl logs \$POD -c add-passwd-to-cfg"
        return 1
    fi

    # 0600 and in /tmp, never in the home. The gate reads this; nothing else in
    # this pod runs as anyone else.
    ( umask 077; printf '%s' "$pw" > "$PASSWORD_FILE_OUT" )
    export CIRRUS_DESKTOP_PASSWORD_FILE_RESOLVED="$PASSWORD_FILE_OUT"

    # KasmVNC's own credential store, in its own format. Written with
    # kasmvncpasswd rather than by hand: the file is a binary-ish record with a
    # per-user permission byte, and -w takes the password on stdin twice.
    #
    # -u <name> matters. It is the username the browser would have to supply for
    # HTTP Basic, and it is the username api/get_sessions reports back, which is
    # what the idle watchdog reads.
    if ! printf '%s\n%s\n' "$pw" "$pw" \
         | kasmvncpasswd -u "${CIRRUS_DESKTOP_USER:-$(id -u)}" -wo "$KASM_PASSWD_FILE" >/dev/null 2>&1; then
        warn "kasmvncpasswd could not write ${KASM_PASSWD_FILE}."
        warn "KasmVNC will refuse every request, including the gate's."
        return 1
    fi
    chmod 0600 "$KASM_PASSWD_FILE" 2>/dev/null || true
    log "session password loaded (${#pw} characters) and installed for KasmVNC"
    return 0
}
PASSWORD_OK=1
resolve_password || PASSWORD_OK=0

# ===========================================================================
# 5. Proxy prefix
#
# OnDemand ships two proxies and they are not interchangeable:
#
#   /node/HOST/PORT/...   forwards the whole path, prefix included.
#   /rnode/HOST/PORT/...  strips the prefix, and rewrites what comes back.
#
# This app is served through /rnode/, and its second half is the part that is
# easy to miss. From OnDemand's own ood-portal.conf:
#
#   Header edit Location "^([^/]+//[^/]+)|(?=/)|^([\./]{1,}(?<!/))" \
#                        "/rnode/%{MATCH_HOST}e/%{MATCH_PORT}e"
#   Header edit* Set-Cookie ";\s*(?i)Path[^;]*" ""
#   Header edit  Set-Cookie "^([^;]+)" "$1; Path=/rnode/%{MATCH_HOST}e/%{MATCH_PORT}e"
#
# So the app must serve at the root and emit UNPREFIXED redirects, and KasmVNC
# does both. Measured on this image:
#
#   * index.html references no root-absolute asset -- every one is ./assets/...
#     -- and the client builds the websocket URL and the secondary-monitor URL
#     from window.location.pathname, so a stripped prefix is invisible to it.
#   * the only Location it ever emits is a trailing-slash 301, root-relative:
#       GET /app  ->  301 Moved Permanently, Location: /app/
#     Run through the rule above, the `(?=/)` alternative matches at offset 0
#     and inserts the prefix, giving /rnode/<node>/<port>/app/. Correct. Had it
#     emitted the prefix itself the browser would get it twice and land on the
#     dashboard's 404.
#
# The prefix is still needed for exactly one thing: the gate's login form
# action, which lives in a response BODY, and bodies are not rewritten. It
# contains the node name and the assigned NodePort, neither of which exists
# until the pod is scheduled and its service created, so it cannot come from the
# pod spec. An init container computes it into the ConfigMap and this reads it.
# ===========================================================================

BASE_URL="${CIRRUS_DESKTOP_BASE_URL:-}"
if [ -z "$BASE_URL" ] && [ -n "${CIRRUS_DESKTOP_BASE_URL_FILE:-}" ]; then
    for i in $(seq 1 30); do
        # Last path-looking line, not the whole file: the init container writes
        # a ConfigMap key, and a seeded comment or a second write would
        # otherwise be concatenated into a nonsense prefix.
        #
        # `|| true`: an empty file -- exactly what a failed init container
        # leaves behind -- makes grep exit 1, which under pipefail + set -e
        # kills the session before the warning below can be printed.
        BASE_URL="$(grep -oE '^[[:space:]]*/[^[:space:]]*' "$CIRRUS_DESKTOP_BASE_URL_FILE" 2>/dev/null | tr -d '[:space:]' | tail -1 || true)"
        [ -n "$BASE_URL" ] && break
        sleep 1
    done
    if [ -n "$BASE_URL" ]; then
        log "proxy prefix read from ${CIRRUS_DESKTOP_BASE_URL_FILE}: ${BASE_URL}"
    else
        warn "no proxy prefix appeared at ${CIRRUS_DESKTOP_BASE_URL_FILE}."
        warn "The init container that computes it did not write one. Check:"
        warn "    kubectl logs \$POD -c add-baseurl-to-cfg"
        warn "The gate's login form will post to / instead. Behind the OnDemand"
        warn "proxy that is the dashboard's own root, so typing the password by"
        warn "hand lands on a 404. The Connect button still works: it posts to"
        warn "the full /rnode/<node>/<port>/cirrus-signin from the dashboard."
    fi
fi
[ -n "$BASE_URL" ] || BASE_URL="/"
# One trailing slash, so the form action is the prefix plus the sign-in path
# rather than a run-together /<port>cirrus-signin.
case "$BASE_URL" in */) ;; *) BASE_URL="${BASE_URL}/" ;; esac

PORT="${CIRRUS_DESKTOP_PORT:-8080}"
UPSTREAM_PORT="${CIRRUS_DESKTOP_UPSTREAM_PORT:-8082}"
GEOMETRY="${CIRRUS_DESKTOP_GEOMETRY:-1600x900}"
case "$GEOMETRY" in
    [0-9]*x[0-9]*) : ;;
    *)  warn "CIRRUS_DESKTOP_GEOMETRY=${GEOMETRY} is not WIDTHxHEIGHT; using 1600x900."
        GEOMETRY=1600x900 ;;
esac

# ===========================================================================
# 6. bootstrap mode -- everything above, then stop or hand over
# ===========================================================================
if [ "$MODE" = "bootstrap" ]; then
    if [ "$#" -gt 0 ]; then
        exec "$@"
    fi
    log "bootstrap complete"
    log "  user             : $(id -un 2>/dev/null || echo '<no passwd entry>') (uid $(id -u), gid $(id -g))"
    log "  HOME             : ${HOME}"
    log "  persist dir      : ${PERSIST_DIR}"
    log "  XDG_CONFIG_HOME  : ${XDG_CONFIG_HOME}"
    log "  XDG_DATA_HOME    : ${XDG_DATA_HOME}"
    log "  XDG_CACHE_HOME   : ${XDG_CACHE_HOME}"
    log "  XDG_STATE_HOME   : ${XDG_STATE_HOME}"
    log "  XDG_RUNTIME_DIR  : ${XDG_RUNTIME_DIR}"
    log "  TMPDIR           : ${TMPDIR}"
    log "  ICEAUTHORITY     : ${ICEAUTHORITY}"
    log "  XAUTHORITY       : ${XAUTHORITY}"
    log "  session bus      : ${DBUS_SESSION_BUS_ADDRESS}"
    log "  geometry         : ${GEOMETRY}"
    log "  proxy prefix     : ${BASE_URL} (gate login form only)"
    log "  port             : ${PORT} (gate), ${UPSTREAM_PORT} (KasmVNC, loopback)"
    exit 0
fi

# ===========================================================================
# 7. The desktop
# ===========================================================================

# --- who holds the port ---------------------------------------------------
#
# KasmVNC does authenticate for real -- HTTP Basic on every request, the
# websocket upgrade included, with brute-force blacklisting. What it cannot do
# is be signed into without the user typing something: Basic auth is a header
# the browser will only send after its own native dialog, so the dashboard's
# Connect button (a form POST) has no way to supply it. Browsers also cache
# Basic credentials per ORIGIN, and every session on this site shares the
# OnDemand origin, so two concurrent desktops would fight over one cached
# credential.
#
# So the gate holds the public port, turns one POST from the dashboard into a
# cookie, and adds the Authorization header on the way through to a KasmVNC
# bound to loopback. The user has already authenticated to OnDemand; they type
# nothing here.
#
# KasmVNC's own auth stays ON behind the gate. It is not decoration: every
# response is `Connection: close` (verified -- the server closes even when the
# request asked for keep-alive), so there is exactly one request per connection
# and the gate can add the header to all of them.
GATE=/usr/local/bin/cirrus-desktop-gate
USE_GATE=0
if [ "${CIRRUS_DESKTOP_AUTH:-password}" = "password" ]; then
    if [ "$PASSWORD_OK" -eq 1 ]; then
        USE_GATE=1
    else
        # Refuse rather than fall back to no auth. A session that silently drops
        # its password check is worse than one that does not start: the pod
        # looks healthy and the exposure is invisible -- and what is exposed
        # here is a desktop with a terminal in the user's home directory.
        warn "CIRRUS_DESKTOP_AUTH=password but no session password is available."
        warn "Refusing to start an unauthenticated desktop. The reason is above;"
        warn "set CIRRUS_DESKTOP_AUTH=none deliberately if that is really wanted."
        exit 1
    fi
fi

if [ "$USE_GATE" -eq 1 ]; then
    KASM_ADDRESS=127.0.0.1
    KASM_PORT="$UPSTREAM_PORT"
    export CIRRUS_DESKTOP_ROOT_PATH="$BASE_URL"
    export CIRRUS_DESKTOP_UPSTREAM_PORT="$UPSTREAM_PORT"
    export CIRRUS_DESKTOP_BASIC_USER="${CIRRUS_DESKTOP_USER:-$(id -u)}"
else
    KASM_ADDRESS=0.0.0.0
    KASM_PORT="$PORT"
    warn "CIRRUS_DESKTOP_AUTH=none: anyone who can reach this port gets a desktop"
    warn "and a terminal in your home directory. Only appropriate behind"
    warn "something else that authenticates."
fi

# --- the session bus ------------------------------------------------------
#
# Started before X, because xfce4-session and xfconfd both want it and a bus
# that appears late shows up as "Failed to connect to session bus" followed by a
# desktop with no settings daemon.
#
# --nofork so this script owns the process and can take it down; --nosyslog
# because there is no syslog here and the alternative is losing every message.
rm -f "${XDG_RUNTIME_DIR}/bus"
dbus-daemon --session --nofork --nopidfile --nosyslog \
            --address="${DBUS_SESSION_BUS_ADDRESS}" \
            >/dev/null 2>&1 &
DBUS_PID=$!
log "session bus on ${DBUS_SESSION_BUS_ADDRESS}"

# --- the X server and the web front end -----------------------------------
#
# One process for the X server, the RFB encoder, the HTTP server, the websocket
# endpoint and the web client. That is the reason KasmVNC is here rather than
# TigerVNC plus websockify plus noVNC: OnDemand's proxy gives one TCP port
# carrying HTTP and WebSocket, which is exactly what this binds.
#
# -displayfd, rather than a fixed :1 and a poll for the socket: the server
# writes the display number to that descriptor when it is ready to accept
# connections, which is the server itself telling us, not a guess about timing.
#
# -publicIP 127.0.0.1 is not cosmetic. Left unset, start-up queries a public
# STUN server to discover the pod's address for the optional UDP transport --
# observed in the log:
#     ICE: Querying public IP...
#     ICE: Trying 'stun.l.google.com', port 19302
#     ICE: My public IP is 128.117.66.102
# An outbound call to the internet on the start-up path, inside a startup-probe
# budget, for a transport OnDemand's proxy cannot carry anyway.
#
# -SecurityTypes None is the RFB-level setting and is not "no authentication":
# the websocket carrying that RFB stream is the thing that is authenticated, by
# HTTP Basic, before a single RFB byte flows. The X server itself listens on
# unix sockets only -- verified, the only TCP listener in this pod is the web
# port -- so there is no second door.
XKASM=/usr/bin/Xkasmvnc
DISPFIFO="${STATE_DIR}/displayfd"
rm -f "$DISPFIFO"; mkfifo "$DISPFIFO"

kasm_args=(
    -displayfd 3
    -geometry "$GEOMETRY"
    -depth 24
    -httpd /usr/share/kasmvnc/www
    -websocketPort "$KASM_PORT"
    -interface "$KASM_ADDRESS"
    # No raw RFB port. The browser is the only client, and it arrives over the
    # websocket.
    -rfbport 0
    -SecurityTypes None
    -publicIP 127.0.0.1
    # Deliberately NOT -MaxDisconnectionTime / -MaxIdleTime, which would let
    # KasmVNC end the session itself. Its exit status would then be whatever it
    # chooses, and restart_policy is OnFailure -- a nonzero status brings the
    # pod straight back. The watchdog below owns that decision so the exit
    # status can be 0.
    -Log "*:stderr:${CIRRUS_DESKTOP_LOG_LEVEL:-30}"
)
if [ "$PASSWORD_OK" -eq 1 ] && [ -r "$KASM_PASSWD_FILE" ]; then
    kasm_args+=(-KasmPasswordFile "$KASM_PASSWD_FILE")
else
    kasm_args+=(-DisableBasicAuth)
fi

log "starting KasmVNC on ${KASM_ADDRESS}:${KASM_PORT}, geometry ${GEOMETRY}"
"$XKASM" "${kasm_args[@]}" 3>"$DISPFIFO" &
KASM_PID=$!

DISPNUM=""
if read -r -t 120 DISPNUM < "$DISPFIFO"; then
    :
else
    warn "the X server did not report a display within 120s."
    warn "Its own messages are above; the session cannot continue."
    kill -TERM "$KASM_PID" "$DBUS_PID" 2>/dev/null || true
    exit 1
fi
rm -f "$DISPFIFO"
export DISPLAY=":${DISPNUM}"
log "X server ready on ${DISPLAY}"

# --- XFCE -----------------------------------------------------------------
/usr/local/bin/cirrus-desktop-session &
SESSION_PID=$!

# --- the gate -------------------------------------------------------------
GATE_PID=""
if [ "$USE_GATE" -eq 1 ]; then
    # Started last so a connection it accepts has somewhere to go. It does not
    # wait for the desktop: the startup probe hits the gate, and a gate that is
    # up while XFCE is still starting answers with the login page, which is a
    # correct answer.
    "$GATE" &
    GATE_PID=$!
    log "password gate on :${PORT}, KasmVNC on 127.0.0.1:${UPSTREAM_PORT}"
fi

# ===========================================================================
# 8. Supervision: idle culling and a hard ceiling
#
# Nothing outside the pod will reclaim this, and a desktop holds more CPU and
# memory than an IDE does: an idle XFCE session is a dozen processes and the
# framebuffer for a 1600x900 screen.
#
# The signal is whether a client is connected, which KasmVNC reports directly:
#
#   $ curl -u <user>:<pw> http://127.0.0.1:8082/api/get_sessions
#   {"users":[]}                                              nobody attached
#   {"users": [{"username":"ncote","connected_since":"..."}]}  a real client
#
# Measured: a websocket that upgrades but never completes the RFB handshake does
# NOT appear, which is the right answer -- that is a probe, not a session. So
# the startup probe's own requests cannot keep a session alive, and neither can
# a half-open connection.
#
# The credentials go in a curl config file rather than on the command line: the
# password would otherwise be in `ps` output for every process in this pod.
# ===========================================================================

IDLE_TIMEOUT="${CIRRUS_DESKTOP_IDLE_TIMEOUT:-3600}"
IDLE_CHECK="${CIRRUS_DESKTOP_IDLE_CHECK:-300}"
MAX_LIFETIME="${CIRRUS_DESKTOP_MAX_LIFETIME:-43200}"

# All three come from the environment, and `[ "$x" -gt 0 ]` on anything that is
# not an integer is a fatal error under set -e -- which would end the session at
# the one point where it is otherwise completely up and working. A bad value
# falls back to the default and says so.
check_int() {
    local name="$1" value="$2" fallback="$3"
    case "$value" in
        ''|*[!0-9]*)
            warn "${name}=${value} is not a whole number of seconds; using ${fallback}."
            printf '%s' "$fallback" ;;
        *)  printf '%s' "$value" ;;
    esac
}
IDLE_TIMEOUT="$(check_int CIRRUS_DESKTOP_IDLE_TIMEOUT "$IDLE_TIMEOUT" 3600)"
IDLE_CHECK="$(check_int CIRRUS_DESKTOP_IDLE_CHECK "$IDLE_CHECK" 300)"
MAX_LIFETIME="$(check_int CIRRUS_DESKTOP_MAX_LIFETIME "$MAX_LIFETIME" 43200)"
# A zero check interval would spin.
[ "$IDLE_CHECK" -gt 0 ] || IDLE_CHECK=300
CULLED="${STATE_DIR}/culled"
rm -f "$CULLED"
STARTED="$(date +%s)"

CURLRC="${STATE_DIR}/api-curlrc"
if [ -s "$PASSWORD_FILE_OUT" ]; then
    ( umask 077
      printf 'user = "%s:%s"\n' \
        "${CIRRUS_DESKTOP_USER:-$(id -u)}" "$(cat "$PASSWORD_FILE_OUT")" > "$CURLRC" )
else
    # No password at all, which is CIRRUS_DESKTOP_AUTH=none: KasmVNC is running
    # with -DisableBasicAuth and wants no credential. An empty file is right;
    # `user = ":"` would send an empty Basic header instead.
    ( umask 077; : > "$CURLRC" )
fi

# The endpoint is on the loopback port KasmVNC binds, never through the gate:
# the gate would answer this with its login page, and a login page contains no
# "username" either, so a broken gate would read as a permanently idle session
# and cull a desktop somebody was using.
API_URL="http://127.0.0.1:${KASM_PORT}/api/get_sessions"

client_connected() {
    local body
    body="$(curl -sS -m 10 -K "$CURLRC" "$API_URL" 2>/dev/null || true)"
    case "$body" in
        *'"username"'*) return 0 ;;
        # An empty body is not "idle": it is a KasmVNC that has not started
        # answering yet, or one that has died. Treated as connected so a
        # transient failure cannot cull a live session; a dead KasmVNC ends the
        # session through `wait -n` below instead, which is the honest way for
        # it to end.
        "") return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$IDLE_TIMEOUT" -gt 0 ] || [ "$MAX_LIFETIME" -gt 0 ]; then
    (
        LAST_SEEN="$STARTED"
        while sleep "$IDLE_CHECK"; do
            kill -0 "$KASM_PID" 2>/dev/null || exit 0
            NOW="$(date +%s)"

            if [ "$MAX_LIFETIME" -gt 0 ] && [ $(( NOW - STARTED )) -ge "$MAX_LIFETIME" ]; then
                # Reported in whichever unit is not a lie. Integer hours read as
                # "0h" for any limit under an hour, which is what a short test
                # or a deliberately brief session looks like.
                if [ "$MAX_LIFETIME" -ge 3600 ]; then
                    warn "this session has run for $(( (NOW - STARTED) / 3600 ))h, the maximum."
                else
                    warn "this session has run for $(( NOW - STARTED ))s, the maximum."
                fi
                warn "Ending it. Relaunch from OnDemand; your files and your desktop"
                warn "settings are in ${PERSIST_DIR}."
                : > "$CULLED"
                kill -TERM "$KASM_PID" 2>/dev/null || true
                exit 0
            fi

            if [ "$IDLE_TIMEOUT" -gt 0 ]; then
                if client_connected; then
                    LAST_SEEN="$NOW"
                elif [ $(( NOW - LAST_SEEN )) -ge "$IDLE_TIMEOUT" ]; then
                    warn "no client has been connected for $(( NOW - LAST_SEEN ))s"
                    warn "(limit ${IDLE_TIMEOUT}s). Ending this session so it stops holding"
                    warn "its CPU and memory. Relaunch from OnDemand when you need it;"
                    warn "your files and your desktop settings are in ${PERSIST_DIR}."
                    : > "$CULLED"
                    kill -TERM "$KASM_PID" 2>/dev/null || true
                    exit 0
                fi
            fi
        done
    ) &
    WATCHDOG_PID=$!
else
    WATCHDOG_PID=""
fi

# Pod deletion sends SIGTERM to this shell, since this shell is PID 1. Forward
# it, so ending a session from the OnDemand dashboard shuts the desktop down
# instead of leaving it to be SIGKILLed when the grace period expires.
shutdown_all() {
    local pid
    for pid in "$SESSION_PID" "$KASM_PID" ${GATE_PID:+"$GATE_PID"} \
               ${WATCHDOG_PID:+"$WATCHDOG_PID"} "$DBUS_PID"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
}
trap 'shutdown_all; exit 0' TERM INT

# `wait -n`, not `wait "$KASM_PID"`: three processes can end this session and a
# pod that has lost any one of them is holding resources for nothing. KasmVNC
# dying takes the picture away; the gate dying leaves a port that answers
# nothing; XFCE exiting is the user choosing Log Out, which should end the
# session rather than leave a blank desktop.
RC=0
wait -n "$KASM_PID" "$SESSION_PID" ${GATE_PID:+"$GATE_PID"} || RC=$?

# Which one went, decided BEFORE shutdown_all runs. Asking afterwards races
# against our own SIGTERMs and reads as whichever we happened to signal first.
WENT="unknown"
kill -0 "$SESSION_PID" 2>/dev/null || WENT="session"
kill -0 "$KASM_PID"    2>/dev/null || WENT="kasmvnc"
[ -z "${GATE_PID:-}" ] || kill -0 "$GATE_PID" 2>/dev/null || WENT="gate"

shutdown_all

# Exit 0 after a cull. restart_policy is OnFailure, so a nonzero exit restarts
# the container and the session comes straight back -- which for an idle cull
# would mean never releasing anything and the pod cycling forever. Exiting 0
# leaves the pod Completed. A genuine crash still exits nonzero and still gets
# its restart.
if [ -f "$CULLED" ]; then
    log "session ended by the watchdog (exit 0 so the pod completes rather than restarting)"
    exit 0
fi
# Log Out from the XFCE menu is a deliberate end to the session, not a failure,
# and must not be restarted into a fresh desktop the user did not ask for.
if [ "$WENT" = "session" ]; then
    log "the XFCE session exited (Log Out); ending the pod with status 0"
    exit 0
fi
log "session ending: ${WENT} exited with status ${RC}"
exit "$RC"
