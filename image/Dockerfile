# CIRRUS Ubuntu Desktop image
#
# One Open OnDemand Batch Connect app: a full XFCE desktop on Ubuntu 24.04,
# served to the browser by KasmVNC, running as a pod on the CIRRUS mlc1
# Kubernetes cluster with the user's GLADE home mounted.
#
# ---------------------------------------------------------------------------
# Why KasmVNC, and why one component rather than a stack
#
# OnDemand's node proxy carries HTTP and WebSocket over one TCP port and nothing
# else. That rules out the WebRTC desktops (Selkies and friends): they need a
# UDP path, and without one they need a TURN server to relay over TCP, which
# this site does not have.
#
# So a websocket-framed RFB stream it is, and KasmVNC is that in one process --
# X server, RFB encoder, HTTP server, websocket endpoint and the web client all
# in Xkasmvnc. The alternative (TigerVNC + websockify + noVNC) is three
# components, two of which exist only to bridge what KasmVNC does natively.
#
# Verified against the KasmVNC in this image (1.5.0), not taken from
# documentation:
#
#   * It serves the web client and accepts the websocket on the SAME port:
#       vncext: Listening for websocket connections on 0.0.0.0 interface(s), port 8080
#     One port is all the OnDemand proxy gives us.
#
#   * It authenticates for real. Every request, the /websockify upgrade
#     included, is HTTP Basic against -KasmPasswordFile, with brute-force
#     blacklisting (-BlacklistThreshold, default 5):
#       $ curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/         -> 401
#       $ curl -o /dev/null -w '%{http_code}' -u ncote:WRONG   .../          -> 401
#       $ curl -o /dev/null -w '%{http_code}' -u ncote:right   .../          -> 200
#       GET /websockify with no Authorization                                -> 401
#       GET /websockify with it, Origin: https://ondemand.ucar.edu            -> 101
#
#   * Its own HTML is safe to serve at the root behind a prefix-stripping
#     proxy: index.html references nothing root-absolute -- every asset is
#     ./assets/... -- and host, port and encrypt are all read from
#     window.location.
#
#   * With ONE exception, which is the whole reason bin/cirrus-desktop-gate
#     injects a query parameter: the client's websocket URL is assembled
#     root-absolutely from a `path` setting defaulting to "websockify", so
#     behind /rnode/ it asks for wss://<ondemand host>/websockify and the
#     prefix is gone. The symptom is a client page that paints and then reports
#     a failed connection. A `?path=` query parameter overrides it and is not
#     persisted to localStorage, so it cannot go stale across sessions. See the
#     module docstring in bin/cirrus-desktop-gate for the code this was read
#     out of.
#
#     All of the above is asserted in image/test/acceptance.sh, which drives
#     the websocket over the path the CLIENT would compute rather than a
#     hand-written one -- writing that path by hand is exactly how this was
#     missed the first time.
#
#   * The only Location header it ever emits is a 301 on a directory path
#     without its trailing slash, and it is root-relative and unprefixed:
#       GET /app  ->  301, Location: /app/
#     which is exactly what /rnode/ wants; the proxy prepends its prefix and
#     the browser lands on /rnode/<node>/<port>/app/.
#
#   * Every response carries `Connection: close` and the server does close,
#     even when the request asked for keep-alive. That is what makes the gate
#     in bin/cirrus-desktop-gate a COMPLETE check rather than a first-request
#     one: there is no second request on an already-authorised connection.
#
#   * api/get_sessions reports connected clients, which is the signal the idle
#     watchdog needs. Empty with nobody attached, populated by a real RFB
#     client:
#       {"users":[]}
#       {"users": [{"username":"ncote", "connected_since":"2026-08-21 16:49:29"}]}
#     A websocket that upgrades but never completes the RFB handshake does NOT
#     count, which is correct -- that is not a session.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

ARG BASE_IMAGE=docker.io/library/ubuntu:24.04

# Pinned, never floating. Bump deliberately and re-run image/test/acceptance.sh:
# the acceptance checks assert things about KasmVNC's own HTML and headers that
# a new release could change.
ARG KASMVNC_VERSION=1.5.0
ARG KASMVNC_DEB=kasmvncserver_noble_1.5.0_amd64.deb
ARG KASMVNC_SHA256=

ENV CIRRUS_DESKTOP_HOME=/opt/cirrus-desktop

# ---------------------------------------------------------------------------
# Packages.
#
# XFCE core plus a terminal, a file manager and a text editor, and nothing else.
# That is the deliberate scope: the reason to open a desktop here is to look at
# and manipulate files on GLADE, and everything a user needs beyond that they
# already have in their home directory. A fuller desktop is mostly a larger
# image to pull on every cold node.
#
# Notes on individual choices, each of which cost something to find out:
#
# dbus-x11        provides dbus-launch, and pulls in dbus for dbus-daemon.
#                 The entrypoint does NOT use dbus-launch: it runs dbus-daemon
#                 itself, because dbus-launch starts it as
#                   /usr/bin/dbus-daemon --syslog --fork ...
#                 and there is no syslog daemon in a container, so everything
#                 the session bus has to say is discarded. dbus-launch also
#                 writes $HOME/.dbus/session-bus/<machine-id>-<display>, which
#                 is a write into the shared GLADE home.
# xauth           Xkasmvnc writes an X authority file; without xauth the
#                 cookie is never created and every client is refused.
# openssh-client  ssh, ssh-agent and ssh-add: git over ssh from the desktop
#                 terminal, and bao-getkey (below). The entrypoint starts the
#                 session's one ssh-agent; xfce4-session's own is switched off
#                 in etc/xdg/.../xfce4-session.xml so it cannot replace it.
# curl, jq        required by bao-getkey. curl is also the watchdog's client.
# libnss-wrapper  the arbitrary-uid case. The pod runs as the user's NFS uid,
#                 which has no passwd entry, and XFCE, the terminal prompt,
#                 git and ssh all call getpwuid().
# python3         the gate and the preference seeding. Standard library only.
# procps          pgrep/pkill for the supervisor.
# xdg-user-dirs   installed for the `xdg-user-dir` command; its automatic
#                 directory creation is switched off in etc/xdg/user-dirs.conf
#                 below, which is the whole point of installing it explicitly.
#
# yaru-theme-gtk  Ubuntu's own theme, and the reason the desktop does not look
# yaru-theme-icon broken. xfce4-settings ships an xsettings.xml naming Greybird
# and elementary-xfce-dark, both of which are Recommends -- so with
#                 --no-install-recommends XFCE was asking for a theme and an
#                 icon set that were not in the image. GTK fell back to its
#                 built-in Adwaita with no icon theme at all: stock GTK icons,
#                 a grey square for "File System", raw window frames. Confirmed
#                 from a screenshot of a live session, not from taste.
#
#                 Yaru is the pick because it is the only GTK theme in the
#                 archive that also ships an xfwm4 variant, so the window
#                 decorations match rather than falling back to "Default":
#                   themes/Yaru-dark/{gtk-2.0,gtk-3.0,gtk-4.0,metacity-1,xfwm4}
#                 It is also literally what an Ubuntu GNOME desktop looks like,
#                 which is the target. 30 MB with fonts-ubuntu.
#
# fonts-ubuntu    Ubuntu's interface font, so the typography matches too. The
#                 image otherwise has three font families (DejaVu Sans, Mono,
#                 Serif) and 8 font files.
#
# humanity-icon-theme
# adwaita-icon-theme
#                 The rest of the icon chain, named explicitly because leaving
#                 it implicit is the bug this whole block exists to fix.
#                 yaru-theme-icon declares NO dependencies at all, and every
#                 Yaru variant's index.theme reads
#                   Inherits=Yaru,Humanity,hicolor
#                 so a missing Humanity puts the icons straight back to
#                 fallbacks. Humanity happened to be in the image already, as a
#                 dependency of something else -- which is exactly the kind of
#                 accident that stops being true after an unrelated package
#                 change. Adwaita is kept as a final fallback for applications
#                 that ask for GNOME icon names Yaru does not carry.
#
# GNOME Shell itself is NOT an option here, and this was tested rather than
# assumed. Built into a probe image and run under this same X server, it exits:
#   Gjs-CRITICAL: JS ERROR: Gio.IOErrorEnum: Could not connect: No such file or
#     directory
#     LoginManagerSystemd@resource:///org/gnome/shell/misc/loginManager.js:96:9
#     getLoginManager@resource:///org/gnome/shell/misc/loginManager.js:84:29
# It requires systemd-logind, which needs systemd as PID 1 -- not available to an
# unprivileged pod. And separately mutter gets no acceleration here:
#   libEGL warning: DRI3 error: Could not get DRI3 device
#   libEGL warning: Ensure your X server supports DRI3 to get accelerated rendering
# So the approach is XFCE wearing Ubuntu's GNOME theme, which is the look without
# the login manager and the GL compositor.
#
# ---------------------------------------------------------------------------
# Letting a user help themselves.
#
# There is no root in this session and there cannot be: the pod runs as the
# user's own uid so that files written to GLADE belong to them, and /usr, /opt,
# /var and /etc are all read-only. Measured:
#   $ apt-get install -y cowsay
#   E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)
#   E: Unable to acquire the dpkg frontend lock, are you root?
# Only /tmp, /var/tmp and $HOME are writable.
#
# So whatever a user needs beyond this image, they install into their home - and
# the packages below are what makes that possible at all rather than merely
# theoretically possible. Each one closes a specific dead end that was measured
# in the image without it:
#
# xz-utils      tar could not read a .tar.xz, which is how most upstream
# bzip2         releases ship. The image had gzip and nothing else: `tar -J`
# zstd          and `tar -j` both failed outright. Note dpkg -x was always fine
# unzip         - dpkg-deb links liblzma itself - so this was specifically about
#               source tarballs and release archives.
# wget          because a great many install scripts assume it. curl was already
#               here; this is one package and it removes a class of "command not
#               found" halfway through somebody else's shell script.
#
# python3-pip   `python3 -m venv` FAILED in this image: Debian strips ensurepip,
# python3-venv  so venv could not provision pip and there was no pip to fall
#               back on. Two packages, and the whole Python ecosystem opens up.
#
# build-essential
# python3-dev   A compiler, because "install it yourself" without one means
#               "only if somebody shipped you a binary". python3-dev comes with
#               it rather than after it: pip building any package with a C
#               extension fails on a missing Python.h, which is a confusing
#               error to hit when a compiler is demonstrably present.
#
# 72 MB of download for the set, 66 MB of that the compiler. Weigh that against
# a session where the answer to "can I install X" is no.
#
# IMPORTANT, and it applies to everything built here: this is glibc 2.39 on
# Ubuntu 24.04. $HOME is GLADE, shared with Casper and Derecho, and a binary
# compiled in this container will generally NOT run on those systems - nor the
# reverse. It is the same hazard the sibling RStudio app's R library isolation
# exists to prevent, and there is no equivalent hook to catch it for a compiler.
# Build into $HOME/cirrus-desktop/ and treat the result as this container's.
# ---------------------------------------------------------------------------

# epiphany-browser
# xdg-utils      A browser, because without one the desktop has a control that
#                fails. XFCE's stock panel ships a Web Browser launcher running
#                `exo-open --launch WebBrowser`, and with nothing to launch that
#                call does not error out - it blocks on a GTK dialog. Measured:
#                `exo-open --launch WebBrowser https://example.com` never
#                returned. Clicking a URL anywhere does the same thing, so
#                removing the launcher would not have been enough.
#
#                GNOME Web (epiphany) rather than Firefox or Chromium, and that
#                is forced rather than chosen: in the noble archive both of those
#                are snap transition packages -
#                  firefox           1:1snap1-0ubuntu5
#                  chromium-browser  2:1snap1-0ubuntu2
#                - and snap does not work in a container. epiphany-browser 46.5
#                is a real deb, it is GNOME's own browser, and exo already ships
#                a helper naming its binary
#                  epiphany.desktop  X-XFCE-Binaries=epiphany;org.gnome.Epiphany;
#                so exo-open finds it with no configuration at all. Verified:
#                exit 0, and WebKit's bwrap sandbox works unprivileged.
#
#                xdg-utils for xdg-open, which is what GTK apps and terminal
#                workflows call rather than exo-open.
#
#                ~200 MB installed. If that is not wanted, drop both packages
#                AND leave the panel default without a browser launcher - the
#                two go together.
#
# Deliberately NOT installed: tumbler. Thunar Recommends it for thumbnails, and
# --no-install-recommends leaves it out. Thumbnails are a cache written per
# image file, and the cost of them is an extra writer aimed at the home
# directory. Image previews in Thunar are the visible loss.
# ---------------------------------------------------------------------------
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dbus-x11 \
        git \
        jq \
        less \
        libnss-wrapper \
        nano \
        openssh-client \
        procps \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        unzip \
        wget \
        xauth \
        xz-utils \
        zstd \
        xdg-user-dirs \
        adwaita-icon-theme \
        bzip2 \
        build-essential \
        fonts-dejavu-core \
        fonts-ubuntu \
        humanity-icon-theme \
        libgl1 \
        libglx-mesa0 \
        mousepad \
        epiphany-browser \
        thunar \
        xdg-utils \
        xfce4-appfinder \
        xfce4-panel \
        xfce4-session \
        xfce4-settings \
        xfce4-terminal \
        xfconf \
        xfdesktop4 \
        xfwm4 \
        yaru-theme-gtk \
        yaru-theme-icon \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# KasmVNC.
#
# The .deb, not a build from source: the release assets include a noble amd64
# package, and it pulls its X and perl dependencies through apt like anything
# else. Installed with `apt-get install ./file.deb` rather than dpkg -i so those
# dependencies resolve in one step.
#
# The checksum is verified when KASMVNC_SHA256 is set, and the build fails if it
# is set and does not match. It is empty by default rather than fabricated --
# a wrong-but-present hash that nobody has checked is worse than an honest
# absence, and the version above is pinned regardless.
# ---------------------------------------------------------------------------
RUN set -eu; \
    curl -fsSL -o /tmp/kasmvnc.deb \
        "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/${KASMVNC_DEB}"; \
    if [ -n "${KASMVNC_SHA256}" ]; then \
        echo "${KASMVNC_SHA256}  /tmp/kasmvnc.deb" | sha256sum -c -; \
    fi; \
    DEBIAN_FRONTEND=noninteractive apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/kasmvnc.deb; \
    rm -f /tmp/kasmvnc.deb; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# The X and ICE socket directories.
#
# Both are hardcoded in libX11/libICE and neither is created by the packages.
# Without them, as an unprivileged uid:
#   _XSERVTransmkdir: ERROR: euid != 0,directory /tmp/.X11-unix will not be created.
#   _IceTransmkdir:   ERROR: euid != 0,directory /tmp/.ICE-unix will not be created.
# The session survives on abstract sockets, but any client that only speaks the
# filesystem path does not. 1777, like /tmp itself.
#
# The entrypoint creates them again at runtime, because a pod may have something
# mounted over /tmp and then the image's copies are invisible.
# ---------------------------------------------------------------------------
RUN mkdir -p /tmp/.X11-unix /tmp/.ICE-unix && chmod 1777 /tmp/.X11-unix /tmp/.ICE-unix

# ---------------------------------------------------------------------------
# Switch off automatic XDG user-directory creation, site-wide.
#
# This is the trap in a shared home. Left alone, xdg-user-dirs-update runs from
# the XFCE session start-up and creates eight directories directly in $HOME --
# measured on this image with no configuration at all:
#   Desktop Documents Downloads Music Pictures Public Templates Videos
# all of them straight into the user's GLADE home, shared with Casper and
# Derecho.
#
# `enabled=False` in /etc/xdg/user-dirs.conf stops the creation. The entrypoint
# additionally pins user-dirs.dirs inside this app's own configuration
# directory, so the values GTK and xfdesktop read are ours and not defaults
# resolved against $HOME. Two mechanisms because they fail differently: this one
# stops the writer, that one fixes the readers.
# ---------------------------------------------------------------------------
COPY --chmod=0644 etc/xdg/user-dirs.conf /etc/xdg/user-dirs.conf

# ---------------------------------------------------------------------------
# Appearance and layout defaults.
#
# System-wide xfconf defaults and a panel layout, not a runtime seeding step.
# xfconf reads these through XDG_CONFIG_DIRS and copies them into the user's own
# channel files on first launch, so a user who changes anything in Settings >
# Appearance keeps it -- in $HOME/cirrus-desktop/config, like the rest of their
# desktop state. There is no code to run and nothing to un-seed.
#
# Each file says in its own header what it fixes and why. Two of the four are
# about this transport rather than taste: grayscale antialiasing instead of
# subpixel, and a flat desktop colour instead of a photograph.
# ---------------------------------------------------------------------------
COPY --chmod=0644 etc/xdg/xfce4/xfconf/xfce-perchannel-xml/ \
     /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/
COPY --chmod=0644 etc/xdg/xfce4/panel/default.xml /etc/xdg/xfce4/panel/default.xml

# ---------------------------------------------------------------------------
# Our scripts. /usr/local/bin is on PATH for the entrypoint and for every
# terminal the desktop spawns.
# ---------------------------------------------------------------------------
COPY --chmod=0755 bin/entrypoint.sh           /usr/local/bin/entrypoint.sh
COPY --chmod=0755 bin/cirrus-desktop-gate     /usr/local/bin/cirrus-desktop-gate
COPY --chmod=0755 bin/cirrus-desktop-session  /usr/local/bin/cirrus-desktop-session
COPY --chmod=0755 bin/desktop-versions        /usr/local/bin/desktop-versions

# --- bao-getkey -------------------------------------------------------------
# HSG's OpenBao client (NCAR/hsg-openbao-scripts, MIT). One password+Duo login
# mints a short-lived signed SSH certificate and loads it into ssh-agent, so
# ssh to Casper/Derecho stops prompting for ncar-two-factor.
#
# Vendored because the upstream repo is internal to the NCAR org and an
# unauthenticated build cannot fetch it. Verbatim copy of bin/bao-getkey at
# commit ef6b7a7503c911977865df50df3b4d4fc223c25b, sha256
# 9fee1714bd7b149dec56798304350642167cae3eb9236aecfbc44fd39dc7bf9e (CI checks
# it). The entrypoint starts the ssh-agent it loads into.
COPY bao-getkey /usr/local/bin/bao-getkey
RUN chmod 0755 /usr/local/bin/bao-getkey

# Read by any login shell inside the session. The desktop's own processes
# inherit their environment from the entrypoint, so this is the belt-and-braces
# path: a `bash -l` started from somewhere that did not inherit it still lands
# on the same XDG redirection instead of writing to the shared home.
COPY --chmod=0644 etc/profile.d/cirrus-desktop.sh /etc/profile.d/cirrus-desktop.sh

# ---------------------------------------------------------------------------
# Resolved versions, recorded once at build time so a bug report can name them.
# `desktop-versions` prints this file; `desktop-versions --check` re-runs each
# component and diffs against the record.
#
# The nss_wrapper library path is resolved here too. Finding it at runtime would
# mean running ldconfig in every session, and a miss would surface at the worst
# possible moment -- after the desktop is already up, as a terminal prompt
# showing a bare uid.
# ---------------------------------------------------------------------------
RUN set -eu; \
    mkdir -p "${CIRRUS_DESKTOP_HOME}"; \
    { \
      echo "# CIRRUS Ubuntu Desktop image -- resolved versions"; \
      echo "# name<TAB>expected version"; \
      printf 'base-image\t%s\n'  "${BASE_IMAGE}"; \
      printf 'ubuntu\t%s\n'      "$(. /etc/os-release; echo "${VERSION_ID}")"; \
      printf 'kasmvnc\t%s\n'     "$(dpkg-query -W -f='${Version}' kasmvncserver)"; \
      printf 'xkasmvnc\t%s\n'    "$(Xkasmvnc -version 2>&1 | sed -n 's/^Xvnc KasmVNC \([^ ]*\).*/\1/p' | head -1)"; \
      printf 'xfce4-session\t%s\n' "$(dpkg-query -W -f='${Version}' xfce4-session)"; \
      printf 'xfwm4\t%s\n'       "$(dpkg-query -W -f='${Version}' xfwm4)"; \
      printf 'thunar\t%s\n'      "$(dpkg-query -W -f='${Version}' thunar)"; \
      printf 'python3\t%s\n'     "$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"; \
      printf 'git\t%s\n'         "$(git --version | awk '{print $3}')"; \
      printf 'epiphany\t%s\n'    "$(dpkg-query -W -f='${Version}' epiphany-browser)"; \
      printf 'gcc\t%s\n'         "$(gcc -dumpfullversion)"; \
      printf 'glibc\t%s\n'       "$(ldd --version | head -1 | awk '{print $NF}')"; \
      printf 'pip\t%s\n'         "$(pip3 --version | awk '{print $2}')"; \
    } > "${CIRRUS_DESKTOP_HOME}/versions.txt"; \
    lib="$(ldconfig -p | awk -F'=> ' '/libnss_wrapper/ {print $2; exit}' | tr -d ' ')"; \
    if [ -z "$lib" ] || [ ! -r "$lib" ]; then \
        lib="$(find /usr/lib /lib -name 'libnss_wrapper.so*' -print -quit 2>/dev/null)"; \
    fi; \
    test -n "$lib" && test -r "$lib"; \
    echo "$lib" > "${CIRRUS_DESKTOP_HOME}/nss_wrapper_lib"; \
    chmod -R a+rX "${CIRRUS_DESKTOP_HOME}"

# ---------------------------------------------------------------------------
# Runtime defaults.
#
# These exist so the image runs standalone for local testing; in the OOD path
# submit.yml.erb sets them. CIRRUS_DESKTOP_BASE_URL is deliberately NOT given a
# default: "/" from an operator and "/" because nothing was computed are
# different things, and conflating them turns a broken init container into a
# sign-in form that posts to the OnDemand dashboard's own root.
# ---------------------------------------------------------------------------
ENV CIRRUS_DESKTOP_PORT=8080 \
    CIRRUS_DESKTOP_STATE_DIR=/tmp/cirrus-desktop \
    CIRRUS_DESKTOP_AUTH=password \
    CIRRUS_DESKTOP_GEOMETRY=1600x900 \
    NO_AT_BRIDGE=1 \
    GTK_A11Y=none \
    GSK_RENDERER=cairo

# GSK_RENDERER=cairo is load-bearing for every GTK4 application in this image,
# and its absence fails in the worst possible way: silently.
#
# GTK4 renders through GSK, whose default backend is GL. This X server provides
# no DRI3 -
#   libEGL warning: DRI3 error: Could not get DRI3 device
#   libEGL warning: Ensure your X server supports DRI3 to get accelerated rendering
# - so GSK cannot bring up a GL context, and the window never maps. Measured on
# GNOME Web: the process ran, its WebKit processes ran under bwrap, nothing was
# logged, and the screen stayed empty. With GSK_RENDERER=cairo the same command
# renders the page.
#
# Nothing else in this image showed it, because XFCE, Thunar and Mousepad are all
# GTK3 - which uses cairo on X11 already. So this only appears the first time a
# GTK4 application is added, which is exactly when nobody is looking for it.
#
# GTK_A11Y=none for the log rather than the screen: every GTK application
# otherwise opens with
#   Unable to acquire the address of the accessibility bus ... org.a11y.Bus was
#   not provided by any .service files
# There is no accessibility bus in a session pod, and GTK says so itself in that
# message: set GTK_A11Y to none.

# Matches the fixed containerPort/NodePort of the other CIRRUS OOD apps.
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["desktop"]
