#!/usr/bin/env bash
#
# Acceptance checks for the CIRRUS Ubuntu Desktop image, run with podman against
# a throwaway home. Everything here is reproducible in a few minutes and covers
# the failures that are expensive to find in OnDemand:
#
#   1. an arbitrary uid with a runtime-synthesised numeric passwd entry
#   2. an arbitrary uid with NO passwd entry at all (the Kubernetes case)
#   3. the port answering, and only the ports that should be listening
#   4. the password gate: wrong refused, right accepted, unprefixed redirect
#   5. a websocket upgrade with a foreign Origin relayed end to end, and the
#      desktop actually reachable behind it -- a full RFB handshake and real
#      framebuffer pixels, not a 101 and a hope
#   6. home isolation: nothing new outside $HOME/cirrus-desktop and every
#      pre-existing file byte-identical
#   7. the idle watchdog: no false positive while a client is attached, and an
#      exit 0 when none is
#   8. the versions recorded in the image
#
# Usage: image/test/acceptance.sh [image-ref]
set -uo pipefail

IMAGE="${1:-localhost/cirrus-desktop:dev}"
WORK="$(mktemp -d)"
PORT="${CIRRUS_TEST_PORT:-19099}"
NAME="desktop-acceptance-$$"
PASSWORD="TestPass123"
PREFIX="/rnode/fakenode/30123"
UA="Mozilla/5.0 (X11; Linux x86_64) Chrome/140"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  note %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

cleanup() {
    podman rm -f "$NAME" "${NAME}-cull" "${NAME}-live" "${NAME}-nopw" >/dev/null 2>&1
    # The throwaway home is written by a uid inside the container's user
    # namespace, so the host user cannot remove it directly.
    podman unshare rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK" 2>/dev/null
}
# EXIT alone is not enough. An untrapped SIGTERM -- which is what `timeout`
# sends, and what a Ctrl-C in a wrapper delivers -- kills the shell without
# running the EXIT trap, and the leftovers are containers holding a port and a
# bind mount into a temp directory that then cannot be removed either. Observed
# exactly that after a run under `timeout`.
trap cleanup EXIT
trap 'cleanup; exit 130' TERM INT HUP

# ---------------------------------------------------------------------------
# A home that already looks like a real GLADE home: dotfiles the user's Casper
# and Derecho sessions read, and a directory of their own work. Every one of
# these must come out the other side byte-identical.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/home/.config" "$WORK/home/.local/share" "$WORK/home/work" "$WORK/ood"
printf 'export PS1="[hpc] "\n' > "$WORK/home/.bashrc"
printf '[user]\n\tname = Real Name\n'     > "$WORK/home/.gitconfig"
printf 'Host derecho\n  User ncote\n'     > "$WORK/home/.ssh_config_sample"
printf '{"editor":"vim"}\n'               > "$WORK/home/.config/pre-existing.json"
printf 'shared data\n'                    > "$WORK/home/.local/share/MARKER"
printf 'x <- 1\n'                         > "$WORK/home/work/analysis.R"
chmod -R 777 "$WORK/home"
( cd "$WORK/home" && find . -type f | sort | xargs md5sum ) > "$WORK/home-before.md5"
( cd "$WORK/home" && find . | sort ) > "$WORK/home-before.list"

printf '# seeded\npassword=%s\n' "$PASSWORD" > "$WORK/ood/csenv"
printf '%s/\n' "$PREFIX" > "$WORK/ood/base_url"
chmod -R 755 "$WORK/ood"

# ---------------------------------------------------------------------------
head_ "1. arbitrary uid, runtime-synthesised numeric passwd entry"
# podman appends an entry whose NAME IS THE UID -- 54321:*:54321:54321:container
# user:/:/bin/sh -- which is why "does an entry exist" is the wrong test.
# --entrypoint, so this reads /etc/passwd as the runtime left it. Through the
# normal entrypoint the answer would be nss_wrapper's, which is the next check.
synth="$(podman run --rm --user 54321:54321 --entrypoint getent "$IMAGE" passwd 54321 2>/dev/null)"
case "$synth" in
    54321:*) ok "the runtime does synthesise a numeric entry: ${synth}" ;;
    *)       note "the runtime did not synthesise an entry (${synth:-none})" ;;
esac
out="$(podman run --rm --user 54321:54321 -e HOME=/tmp/h -e USER=ncote -e GROUP=ncar \
        -e CIRRUS_DESKTOP_AUTH=none "$IMAGE" bootstrap id -un 2>/dev/null)"
[ "$out" = "ncote" ] && ok "id -un is ncote, not 54321" || bad "id -un is '${out}', expected ncote"
out="$(podman run --rm --user 54321:54321 -e HOME=/tmp/h -e USER=ncote -e GROUP=ncar \
        -e CIRRUS_DESKTOP_AUTH=none "$IMAGE" bootstrap id -gn 2>/dev/null)"
[ "$out" = "ncar" ] && ok "id -gn is ncar, not the image's own group" || bad "id -gn is '${out}', expected ncar"
# The login shell in the entry XFCE's terminal will read. /bin/sh here is dash:
# no readline, so the arrow keys emit ^[[A instead of walking history.
out="$(podman run --rm --user 54321:54321 -e HOME=/tmp/h -e USER=ncote -e GROUP=ncar \
        -e CIRRUS_DESKTOP_AUTH=none "$IMAGE" bootstrap sh -c 'getent passwd $(id -u) | cut -d: -f7' 2>/dev/null)"
[ "$out" = "/bin/bash" ] && ok "the passwd entry's shell is /bin/bash" || bad "shell is '${out}'"

head_ "2. arbitrary uid with NO passwd entry at all"
# /etc/passwd mounted read-only without the uid, so the runtime cannot add one.
# This is the Kubernetes case, and it is the one where a `getent` under `set -e`
# with `pipefail` kills the entrypoint before it logs anything.
podman run --rm --user 54321:54321 -e CIRRUS_DESKTOP_AUTH=none "$IMAGE" bootstrap cat /etc/passwd 2>/dev/null \
    | grep -v '^[^:]*:[^:]*:54321:' > "$WORK/passwd-noentry"
chmod 644 "$WORK/passwd-noentry"
out="$(podman run --rm --user 54321:54321 -v "$WORK/passwd-noentry:/etc/passwd:ro,z" \
        -e HOME=/tmp/h -e USER=ncote -e GROUP=ncar -e CIRRUS_DESKTOP_AUTH=none \
        "$IMAGE" bootstrap id -un 2>/dev/null)"
[ "$out" = "ncote" ] && ok "id -un is ncote with no entry to start from" || bad "id -un is '${out}'"

head_ "3. a session with no password refuses to start"
# The alternative -- falling back to no authentication -- would leave a pod that
# looks healthy while exposing a terminal in someone's home directory.
podman run --rm --name "${NAME}-nopw" --user 54321:54321 -e HOME=/tmp/h -e USER=ncote \
    -e GROUP=ncar -e CIRRUS_DESKTOP_PASSWORD_FILE=/nonexistent \
    -e CIRRUS_DESKTOP_PASSWORD_WAIT=3 \
    "$IMAGE" desktop > "$WORK/nopw.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'Refusing to start an unauthenticated desktop' "$WORK/nopw.log"; then
    ok "no password: refuses to start, exit ${rc}, and says why"
else
    bad "no password: exit ${rc} and no refusal in the log"
fi

# ---------------------------------------------------------------------------
head_ "4. the desktop starts and the gate holds the port"
podman rm -f "$NAME" >/dev/null 2>&1
start=$(date +%s)
podman run -d --name "$NAME" --user 54321:54321 -p "${PORT}:8080" \
  -v "$WORK/home:/home/ncote:z" -v "$WORK/ood:/ood:z" \
  -e HOME=/home/ncote -e USER=ncote -e NB_USER=ncote -e GROUP=ncar \
  -e CIRRUS_DESKTOP_PASSWORD_FILE=/ood/csenv \
  -e CIRRUS_DESKTOP_BASE_URL_FILE=/ood/base_url \
  "$IMAGE" desktop >/dev/null || { bad "container did not start"; exit 1; }

for _ in $(seq 1 240); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:${PORT}/" 2>/dev/null && break
    sleep 0.5
done
elapsed=$(( $(date +%s) - start ))
ok "port answered ${elapsed}s after container start (startup probe budget is 305s)"

# Only the gate is public. KasmVNC is on loopback, and the X server is on unix
# sockets only -- there must be no X TCP port (6000+display) for anything else
# in the cluster to reach.
listeners="$(podman exec "$NAME" bash -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk "\$4==\"0A\"{print \$2}"' \
             | while read -r a; do printf '%s:%d\n' "${a%:*}" "$((16#${a#*:}))"; done | sort -u | tr '\n' ' ')"
case "$listeners" in
    *"00000000:8080"*) ok "the gate listens on 0.0.0.0:8080" ;;
    *)                 bad "nothing listening on 0.0.0.0:8080 (${listeners})" ;;
esac
case "$listeners" in
    *"0100007F:8082"*) ok "KasmVNC listens on 127.0.0.1:8082 only" ;;
    *)                 bad "KasmVNC is not loopback-only (${listeners})" ;;
esac
case "$listeners" in
    *:600[0-9]*) bad "an X TCP port is open: ${listeners}" ;;
    *)           ok "no X TCP port is open (unix sockets only)" ;;
esac

head_ "5. the password gate"
code=$(curl -s -o "$WORK/login.html" -w '%{http_code}' -A "$UA" "http://127.0.0.1:${PORT}/")
if [ "$code" = "200" ] && grep -q "action=\"${PREFIX}/cirrus-signin\"" "$WORK/login.html"; then
    ok "no cookie: login page, form posting to ${PREFIX}/cirrus-signin"
else
    bad "no cookie: got ${code} and an unexpected page"
fi
# No WWW-Authenticate, ever. That header is what summons the browser's own
# credential dialog, which is the whole thing this gate exists to avoid.
if curl -s -D - -o /dev/null -A "$UA" "http://127.0.0.1:${PORT}/" | grep -qi '^www-authenticate:'; then
    bad "the gate sent WWW-Authenticate; the browser would prompt for a password"
else
    ok "the gate never sends WWW-Authenticate (no native browser prompt)"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -A "$UA" -X POST -d "password=WRONG" \
        "http://127.0.0.1:${PORT}/cirrus-signin")
[ "$code" = "401" ] && ok "wrong password refused (401)" || bad "wrong password gave ${code}, expected 401"

hdrs=$(curl -s -D - -o /dev/null -A "$UA" -X POST -d "password=${PASSWORD}" \
        "http://127.0.0.1:${PORT}/cirrus-signin" | tr -d '\r')
COOKIE=$(printf '%s\n' "$hdrs" | grep -i '^set-cookie:' | sed 's/.*: //; s/;.*//')
[ -n "$COOKIE" ] && ok "correct password accepted, cookie issued" || bad "correct password issued no cookie"

# The 302 must NOT carry the prefix: OnDemand's /rnode/ block prepends the
# prefix to every Location it forwards, so a prefixed one arrives at the browser
# doubled -- /rnode/<node>/<port>/rnode/<node>/<port>/ -- which is a 404 on the
# dashboard.
# The requirement is that it is UNPREFIXED, not that it is literally "/": the
# gate also carries the websocket path parameter here so the ordinary Connect
# flow needs no second redirect. What must never appear is the /rnode/ prefix,
# which the proxy would then apply a second time.
loc=$(printf '%s\n' "$hdrs" | grep -i '^location:' | sed 's/.*: //')
case "$loc" in
    "${PREFIX}"*) bad "sign-in redirect '${loc}' already carries the prefix; the proxy doubles it" ;;
    /\?path=*|/)  ok "sign-in redirects to '${loc}', unprefixed, so the proxy's rewrite lands under ${PREFIX}/" ;;
    *)            bad "sign-in redirect is '${loc}', expected an unprefixed root path" ;;
esac

head_ "6. what the proxy will do to what KasmVNC emits"
# KasmVNC emits exactly one kind of Location: a trailing-slash 301 on a
# directory path. Simulated against the real rule from ood-portal.conf:
#   Header edit Location "^([^/]+//[^/]+)|(?=/)|^([\./]{1,}(?<!/))" \
#                        "/rnode/%{MATCH_HOST}e/%{MATCH_PORT}e"
loc=$(curl -s -D - -o /dev/null -A "$UA" -H "Cookie: ${COOKIE}" \
        "http://127.0.0.1:${PORT}/app" | tr -d '\r' | grep -i '^location:' | sed 's/.*: //')
if [ -n "$loc" ]; then
    rewritten=$(python3 - "$loc" "$PREFIX" <<'PY'
import re, sys
loc, prefix = sys.argv[1], sys.argv[2]
# Apache's `Header edit` substitutes the FIRST match only; `edit*` would be all.
print(re.sub(r"^([^/]+//[^/]+)|(?=/)|^([./]{1,}(?<!/))", prefix, loc, count=1))
PY
)
    case "$rewritten" in
        "${PREFIX}/app/") ok "301 '${loc}' rewrites to '${rewritten}'" ;;
        *)                bad "301 '${loc}' rewrites to '${rewritten}', expected ${PREFIX}/app/" ;;
    esac
else
    bad "GET /app sent no Location; the trailing-slash redirect has changed"
fi

# The client document, fetched the way the browser ends up fetching it: with the
# websocket path parameter the gate injects. Without it the gate answers 302, so
# every check below that reads the page has to come after this.
DOC="/?path=${PREFIX#/}/websockify"

# Any Authorization the client sends must be dropped, not honoured. Every
# browser that another session on this OnDemand host has ever prompted holds a
# stale Basic credential for this origin, and KasmVNC reads the first one.
code=$(curl -s -o /dev/null -w '%{http_code}' -A "$UA" -H "Cookie: ${COOKIE}" \
        -u "wrong:wrong" "http://127.0.0.1:${PORT}${DOC}")
[ "$code" = "200" ] \
    && ok "a stale client Authorization header is replaced, not forwarded (200)" \
    || bad "a bogus client Authorization broke the request (${code})"

code=$(curl -s -o "$WORK/index.html" -w '%{http_code}' -A "$UA" -H "Cookie: ${COOKIE}" \
        "http://127.0.0.1:${PORT}${DOC}")
[ "$code" = "200" ] && ok "the KasmVNC client page loads through the gate (200)" \
                    || bad "client page: got ${code}"
# Root-absolute references are the one thing that cannot survive being served at
# / behind a prefix-stripping proxy that rewrites headers only: the browser
# would request them from the OnDemand host itself.
abs=$(grep -oE '(src|href)="/[^"]*"' "$WORK/index.html" | sort -u | tr '\n' ' ')
[ -z "$abs" ] \
    && ok "the client page references no root-absolute asset (safe to serve at /)" \
    || bad "root-absolute references the proxy will not rewrite: ${abs}"
# host, port and encrypt come from window.location, so they survive the proxy.
js=$(grep -oE 'assets/[A-Za-z0-9._-]+\.js' "$WORK/index.html" | head -1)
if [ -n "$js" ] && podman exec "$NAME" \
       grep -q 'initSetting("host",window.location.hostname)' "/usr/share/kasmvnc/www/${js}"; then
    ok "the client reads host/port from window.location (survives the proxy)"
else
    bad "the client no longer reads its host from window.location"
fi

# The websocket URL does NOT. It is assembled root-absolutely from a `path`
# setting whose default is the bare string "websockify", which behind /rnode/
# asks for wss://<ondemand host>/websockify and loses the prefix entirely. This
# asserts the construction is still what the gate's injection compensates for --
# if upstream ever makes it relative, the injection should be revisited rather
# than left in place forever.
if [ -n "$js" ] && podman exec "$NAME" \
       grep -q 'initSetting("path","websockify")' "/usr/share/kasmvnc/www/${js}"; then
    ok "the client still defaults its websocket path to a bare 'websockify'"
else
    note "the client's default websocket path has changed; re-read the gate's injection"
fi

# So the gate has to hand the prefix to the document. Unprefixed Location as
# always -- the proxy prepends.
red=$(curl -s -D - -o /dev/null -A "$UA" -H "Cookie: ${COOKIE}" "http://127.0.0.1:${PORT}/" | tr -d '\r')
status=$(printf '%s\n' "$red" | head -1)
loc=$(printf '%s\n' "$red" | grep -i '^location:' | sed 's/.*: //')
case "${status}|${loc}" in
    *302*"|/?path=${PREFIX#/}/websockify")
        ok "the document is redirected to '${loc}' so the client learns the prefix" ;;
    *)  bad "expected a 302 to /?path=${PREFIX#/}/websockify, got '${status}' '${loc}'" ;;
esac

# And it must not loop: once the parameter is there the request is proxied. That
# is the ${DOC} fetch above, which returned 200 -- restated here because "no
# infinite redirect" is the property, not an incidental fact about one fetch.
code=$(curl -s -o /dev/null -w '%{http_code}' -A "$UA" -H "Cookie: ${COOKIE}" \
        "http://127.0.0.1:${PORT}${DOC}")
[ "$code" = "200" ] \
    && ok "a document that already carries path= is served, not redirected again" \
    || bad "the path= injection loops (${code})"

head_ "7. websocket upgrade with a foreign Origin, and the desktop behind it"
# Not a 101 and a hope: this completes the RFB 3.8 handshake through the gate
# and reads real framebuffer pixels back. The Origin is foreign on purpose --
# behind the OnDemand proxy every request carries one.
cat > "$WORK/rfb.py" <<'PY'
import base64, hashlib, os, socket, struct, sys, time
PORT = int(sys.argv[1]); COOKIE = sys.argv[2]; HOLD = float(sys.argv[3])
# The request path is an argument on purpose. Writing "/websockify" here by hand
# is exactly how the client's own root-absolute URL construction was missed: the
# probe connected to a path the real client never asks for.
WSPATH = sys.argv[4] if len(sys.argv) > 4 else "/websockify"
key = base64.b64encode(os.urandom(16)).decode()
req = (f"GET {WSPATH} HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nUpgrade: websocket\r\n"
       f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
       "Sec-WebSocket-Protocol: binary\r\nOrigin: https://ondemand.ucar.edu\r\n"
       "User-Agent: Mozilla/5.0 Chrome/140\r\n")
if COOKIE:
    req += f"Cookie: {COOKIE}\r\n"
req += "\r\n"
s = socket.create_connection(("127.0.0.1", PORT), timeout=30)
s.sendall(req.encode())
buf = b""
while b"\r\n\r\n" not in buf:
    d = s.recv(4096)
    if not d:
        print("NOUPGRADE server closed"); sys.exit(2)
    buf += d
head, _, rest = buf.partition(b"\r\n\r\n")
text = head.decode("latin-1"); status = text.split("\r\n")[0]
acc = next((l.split(":", 1)[1].strip() for l in text.split("\r\n")[1:]
            if l.lower().startswith("sec-websocket-accept:")), None)
exp = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
if acc != exp:
    print("NOUPGRADE %s" % status); sys.exit(2)
print("UPGRADED %s" % status)

inbuf = bytearray(rest); appbuf = bytearray()
def ws_send(p):
    m = os.urandom(4); masked = bytes(b ^ m[i % 4] for i, b in enumerate(p)); n = len(p)
    h = (struct.pack("!BB", 0x82, 0x80 | n) if n < 126 else
         struct.pack("!BBH", 0x82, 0xFE, n) if n < 65536 else struct.pack("!BBQ", 0x82, 0xFF, n))
    s.sendall(h + m + masked)
def pump():
    global inbuf
    while True:
        if len(inbuf) < 2:
            d = s.recv(65536)
            if not d: raise EOFError
            inbuf += d; continue
        b1, ln, off = inbuf[0], inbuf[1] & 0x7F, 2
        if ln == 126:
            if len(inbuf) < 4: inbuf += s.recv(65536); continue
            ln, off = struct.unpack("!H", inbuf[2:4])[0], 4
        elif ln == 127:
            if len(inbuf) < 10: inbuf += s.recv(65536); continue
            ln, off = struct.unpack("!Q", inbuf[2:10])[0], 10
        if len(inbuf) < off + ln:
            d = s.recv(65536)
            if not d: raise EOFError
            inbuf += d; continue
        payload = bytes(inbuf[off:off + ln]); del inbuf[:off + ln]
        if (b1 & 0x0F) == 0x8: raise EOFError
        appbuf.extend(payload); return
def rd(n):
    while len(appbuf) < n: pump()
    out = bytes(appbuf[:n]); del appbuf[:n]; return out
ver = rd(12)
if not ver.startswith(b"RFB "):
    print("NORFB %r" % ver); sys.exit(3)
ws_send(b"RFB 003.008\n")
types = rd(rd(1)[0])
if 1 not in types:
    print("NORFB security types %s" % list(types)); sys.exit(3)
ws_send(bytes([1]))
if struct.unpack("!I", rd(4))[0] != 0:
    print("NORFB security refused"); sys.exit(3)
ws_send(bytes([1]))
w, h = struct.unpack("!HH", rd(4)); pf = rd(16)
name = rd(struct.unpack("!I", rd(4))[0]).decode("latin-1")
ws_send(struct.pack("!BBHi", 2, 0, 1, 0))                      # SetEncodings: Raw
ws_send(struct.pack("!BBHHHH", 3, 0, 0, 0, 16, 16))            # FramebufferUpdateRequest
if rd(1)[0] != 0:
    print("NOFB not a FramebufferUpdate"); sys.exit(4)
rd(1); nrects = struct.unpack("!H", rd(2))[0]
rx, ry, rw, rh, enc = struct.unpack("!HHHHi", rd(12))
px = rd(rw * rh * (pf[0] // 8))
print("DESKTOP %dx%d depth=%d name=%s rects=%d pixelbytes=%d" % (w, h, pf[1], name, nrects, len(px)))
if HOLD: time.sleep(HOLD)
PY
# The path is derived, not written: take what the gate told the client to use,
# build the URL the way the client does, then strip the prefix the way
# OnDemand's /rnode/ RewriteRule does. Whatever is left is what the pod must
# answer on. Writing "/websockify" here by hand is what hid the bug that this
# whole injection exists to fix.
client_path=$(printf '%s\n' "$loc" | sed -n 's/.*[?&]path=\([^&]*\).*/\1/p')
client_url="/${client_path}"                         # scheme://host + "/" + path
stripped="${client_url#${PREFIX}}"                   # what /rnode/ forwards
printf '  client would open ws://<host>%s ; the proxy forwards %s\n' "$client_url" "$stripped"
[ "$stripped" = "/websockify" ] \
    && ok "the client-computed path arrives at the pod as /websockify" \
    || bad "the client-computed path arrives as '${stripped}', which the pod does not serve"

out=$(python3 "$WORK/rfb.py" "$PORT" "" 0 "$stripped" 2>&1 | head -1)
case "$out" in
    NOUPGRADE*) ok "no cookie: refused, no upgrade (${out#NOUPGRADE })" ;;
    *)          bad "no cookie: the gate upgraded anyway (${out})" ;;
esac
out=$(python3 "$WORK/rfb.py" "$PORT" "$COOKIE" 0 "$stripped" 2>&1)
printf '%s\n' "$out" | grep -q '^UPGRADED HTTP/1.1 101' \
    && ok "with the session cookie: 101, valid Sec-WebSocket-Accept, foreign Origin" \
    || bad "with the cookie: $(printf '%s' "$out" | head -1)"
dsk=$(printf '%s\n' "$out" | grep '^DESKTOP ' || true)
if [ -n "$dsk" ]; then
    ok "the desktop is reachable: ${dsk#DESKTOP }"
else
    bad "the RFB handshake did not complete: $(printf '%s' "$out" | tail -1)"
fi

head_ "8. the home directory afterwards"
extra=$(podman exec "$NAME" bash -c 'ls -A /home/ncote | sort | tr "\n" " "')
printf '  contents: %s\n' "$extra"
case " $extra " in
    *" cirrus-desktop "*) ok "\$HOME/cirrus-desktop was created" ;;
    *)                    bad "\$HOME/cirrus-desktop was not created" ;;
esac
# The eight directories xdg-user-dirs creates unasked. Every one of them would
# be visible from Casper and Derecho forever, and Desktop differs from this
# app's own directory only by case.
strays=""
for d in Desktop Documents Downloads Music Pictures Public Templates Videos \
         .cache .local/share/xfce4 .config/xfce4 .dbus .ICEauthority .Xauthority \
         .config/user-dirs.dirs .config/user-dirs.locale; do
    podman exec "$NAME" test -e "/home/ncote/$d" 2>/dev/null && strays="${strays} ${d}"
done
# .local/share existed before the run; the check above targets what is under it.
[ -z "$strays" ] \
    && ok "none of the XDG user dirs, .cache, .dbus, .ICEauthority or .config/xfce4 in \$HOME" \
    || bad "the session wrote into the shared home:${strays}"

# The whole-tree comparison, which catches anything the named list above missed.
podman exec "$NAME" bash -c 'cd /home/ncote && find . -path ./cirrus-desktop -prune -o -print | sort' \
    > "$WORK/home-after.list"
if diff -q "$WORK/home-before.list" "$WORK/home-after.list" >/dev/null 2>&1; then
    ok "nothing new anywhere outside \$HOME/cirrus-desktop"
else
    bad "new paths outside \$HOME/cirrus-desktop:"
    diff "$WORK/home-before.list" "$WORK/home-after.list" | grep '^>' | sed 's/^/       /'
fi
if ( cd "$WORK/home" && md5sum -c "$WORK/home-before.md5" >/dev/null 2>&1 ); then
    ok "every pre-existing file is byte-identical (md5)"
else
    bad "a pre-existing file changed:"
    ( cd "$WORK/home" && md5sum -c "$WORK/home-before.md5" 2>&1 | grep -v ': OK' | sed 's/^/       /' )
fi

head_ "9. idle watchdog"
# The false positive first, because it is the failure that matters: a watchdog
# that kills a desktop somebody is using is worse than one that never fires. A
# client is held attached for longer than the idle timeout.
podman rm -f "${NAME}-live" >/dev/null 2>&1
podman run -d --name "${NAME}-live" --user 54321:54321 -p "$((PORT+1)):8080" \
  -v "$WORK/ood:/ood:z" -e HOME=/tmp/h -e USER=ncote -e GROUP=ncar \
  -e CIRRUS_DESKTOP_PASSWORD_FILE=/ood/csenv \
  -e CIRRUS_DESKTOP_IDLE_TIMEOUT=15 -e CIRRUS_DESKTOP_IDLE_CHECK=5 \
  -e CIRRUS_DESKTOP_MAX_LIFETIME=0 "$IMAGE" desktop >/dev/null
for _ in $(seq 1 120); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$((PORT+1))/" 2>/dev/null && break
    sleep 0.5
done
livecookie=$(curl -s -D - -o /dev/null -X POST -d "password=${PASSWORD}" \
    "http://127.0.0.1:$((PORT+1))/cirrus-signin" | tr -d '\r' | grep -i '^set-cookie:' | sed 's/.*: //; s/;.*//')
# No BASE_URL file on this container, so it has no prefix -- and with nothing to
# fix the gate must NOT redirect, or a direct connection would loop.
livecode=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: ${livecookie}" \
            "http://127.0.0.1:$((PORT+1))/")
[ "$livecode" = "200" ] \
    && ok "with no proxy prefix the document is served directly, not redirected" \
    || bad "no-prefix document got ${livecode}, expected 200"
python3 "$WORK/rfb.py" "$((PORT+1))" "$livecookie" 45 /websockify >/dev/null 2>&1 &
holder=$!
sleep 40
state=$(podman inspect "${NAME}-live" --format '{{.State.Status}}' 2>/dev/null)
[ "$state" = "running" ] \
    && ok "a session with a client attached survives past its idle timeout" \
    || bad "an attached session was culled anyway (state=${state})"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# And now with nobody attached at all.
podman rm -f "${NAME}-cull" >/dev/null 2>&1
podman run -d --name "${NAME}-cull" --user 54321:54321 \
  -v "$WORK/ood:/ood:z" -e HOME=/tmp/h -e USER=ncote -e GROUP=ncar \
  -e CIRRUS_DESKTOP_PASSWORD_FILE=/ood/csenv \
  -e CIRRUS_DESKTOP_IDLE_TIMEOUT=15 -e CIRRUS_DESKTOP_IDLE_CHECK=5 \
  -e CIRRUS_DESKTOP_MAX_LIFETIME=0 "$IMAGE" desktop >/dev/null
for _ in $(seq 1 36); do
    state=$(podman inspect "${NAME}-cull" --format '{{.State.Status}}' 2>/dev/null)
    [ "$state" = "exited" ] && break
    sleep 5
done
rc=$(podman inspect "${NAME}-cull" --format '{{.State.ExitCode}}' 2>/dev/null)
if [ "$state" = "exited" ] && [ "$rc" = "0" ]; then
    ok "an idle session ends itself and exits 0 (so OnFailure does not restart it)"
else
    bad "idle session state=${state} exit=${rc}, expected exited/0"
fi

head_ "10. the appearance defaults point at things that exist"
# This is the check that would have caught a desktop that looked broken. XFCE
# ships an xsettings.xml naming Greybird and elementary-xfce-dark, both of them
# Recommends -- so with no-install-recommends it asked for a theme and an icon
# set that were not in the image, GTK fell back to its built-in default with no
# icon theme, and the session came up looking like a fault. Nothing failed; there
# was no log line. So: every name the appearance defaults mention has to resolve
# to a directory in the image, and every icon theme those inherit from too.
cfg=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
gtk_theme=$(podman exec "$NAME" sed -n 's/.*"ThemeName".*value="\([^"]*\)".*/\1/p'     "$cfg/xsettings.xml")
icon_theme=$(podman exec "$NAME" sed -n 's/.*"IconThemeName".*value="\([^"]*\)".*/\1/p' "$cfg/xsettings.xml")
curs_theme=$(podman exec "$NAME" sed -n 's/.*"CursorThemeName".*value="\([^"]*\)".*/\1/p' "$cfg/xsettings.xml")
wm_theme=$(podman exec "$NAME" sed -n 's/.*"theme".*value="\([^"]*\)".*/\1/p'           "$cfg/xfwm4.xml")

podman exec "$NAME" test -d "/usr/share/themes/${gtk_theme}/gtk-3.0"     && ok "GTK theme '${gtk_theme}' has a gtk-3.0 directory"     || bad "GTK theme '${gtk_theme}' is named in xsettings.xml but not installed"
# The one that is easy to miss: xfwm4 draws the window borders from its OWN
# theme directory, and most GTK themes do not ship one. Without it the frames
# fall back to "Default" while every widget inside them is themed.
podman exec "$NAME" test -d "/usr/share/themes/${wm_theme}/xfwm4"     && ok "window manager theme '${wm_theme}' has an xfwm4 directory"     || bad "xfwm4 theme '${wm_theme}' is named in xfwm4.xml but ships no xfwm4/ directory"
podman exec "$NAME" test -f "/usr/share/icons/${icon_theme}/index.theme"     && ok "icon theme '${icon_theme}' is installed"     || bad "icon theme '${icon_theme}' is named in xsettings.xml but not installed"
podman exec "$NAME" test -d "/usr/share/icons/${curs_theme}/cursors"     && ok "cursor theme '${curs_theme}' ships cursors"     || bad "cursor theme '${curs_theme}' is named in xsettings.xml but ships no cursors"

# Icon themes inherit, and a missing link in the chain is the same bug one level
# down. yaru-theme-icon declares no dependencies at all, so nothing but this
# check keeps Humanity in the image.
missing=""
for parent in $(podman exec "$NAME" sed -n 's/^Inherits=//p' "/usr/share/icons/${icon_theme}/index.theme" 2>/dev/null | tr ',' ' '); do
    podman exec "$NAME" test -f "/usr/share/icons/${parent}/index.theme" || missing="${missing} ${parent}"
done
[ -z "$missing" ]     && ok "every icon theme '${icon_theme}' inherits from is installed"     || bad "'${icon_theme}' inherits from missing theme(s):${missing}"

# The interface font, likewise: a name nothing resolves gets silently replaced.
ui_font=$(podman exec "$NAME" sed -n 's/.*"FontName".*value="\([^"]*\)".*/\1/p' "$cfg/xsettings.xml" | sed 's/ [0-9]*$//')
podman exec "$NAME" bash -c "fc-list : family | grep -qi '${ui_font}'"     && ok "interface font '${ui_font}' is installed"     || bad "interface font '${ui_font}' is named in xsettings.xml but no such family exists"

# And no launcher on the default panel may point at a program this image lacks.
# The stock layout ships a Web Browser launcher running `exo-open --launch
# WebBrowser`; with no browser and no xdg-open that button is dead on arrival.
dead=""
for d in $(podman exec "$NAME" sed -n 's/.*value="\([a-z0-9-]*\.desktop\)".*/\1/p' /etc/xdg/xfce4/panel/default.xml 2>/dev/null); do
    exe=$(podman exec "$NAME" sed -n 's/^Exec=//p' "/usr/share/applications/$d" 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$exe" ] && podman exec "$NAME" bash -c "command -v '$exe' >/dev/null" || dead="${dead} ${d}"
done
[ -z "$dead" ]     && ok "no launcher on the default panel points at a missing program"     || bad "dead launcher(s) on the default panel:${dead}"

head_ "11. versions recorded in the image"
podman run --rm -e CIRRUS_DESKTOP_AUTH=none "$IMAGE" bootstrap desktop-versions 2>/dev/null \
    | grep -v '^#' | sed 's/^/  /'
if podman run --rm -e CIRRUS_DESKTOP_AUTH=none "$IMAGE" bootstrap desktop-versions --check >/dev/null 2>&1; then
    ok "desktop-versions --check agrees with the record"
else
    bad "desktop-versions --check disagrees with the record:"
    podman run --rm -e CIRRUS_DESKTOP_AUTH=none "$IMAGE" bootstrap desktop-versions --check 2>/dev/null \
        | grep '^DIFF' | sed 's/^/       /'
fi

printf '\n== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
