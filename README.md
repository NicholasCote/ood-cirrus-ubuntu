# Ubuntu Desktop on CIRRUS (Open OnDemand)

An Open OnDemand Batch Connect app that launches a full **XFCE desktop on Ubuntu
24.04** in the browser, as a pod on the CIRRUS `mlc1` Kubernetes cluster, with
the user's GLADE home mounted. The desktop is served by [KasmVNC].

The repository root **is** the OOD app root. `image/` holds the container we
build and OOD ignores it.

```
manifest.yml  form.yml  submit.yml.erb  view.html.erb  info.md.erb
template/.keep              # required; the built-in "basic" template is used
icon.png                    # 490x490, square
image/Dockerfile            # the image; built and pushed by CI
image/bin/entrypoint.sh     # identity, home isolation, start-up, supervision
image/bin/cirrus-desktop-gate     # the password gate in front of KasmVNC
image/bin/cirrus-desktop-session  # the XFCE session
image/bin/desktop-versions        # what is actually in this image
image/bao-getkey                  # vendored OpenBao SSH-certificate client
image/etc/xdg/user-dirs.conf      # stops XFCE creating folders in a shared home
image/etc/profile.d/              # XDG redirection and SSH_AUTH_SOCK for a login shell
image/etc/xdg/xfce4/xfconf/       # appearance defaults; xfce4-session's own agent off
image/test/acceptance.sh    # the 30 checks below, runnable with podman
.github/workflows/build.yml
```

`manifest.yml` has to be at the root. One directory down, OOD reports
"Manifest is missing, add a title and description", which reads like a broken
manifest rather than a misplaced one.

[KasmVNC]: https://github.com/kasmtech/KasmVNC

## SSH to Casper and Derecho without the two-factor prompt

Open a terminal on the desktop and run `bao-getkey` once. It asks for your
password and a Duo approval, then loads a short-lived SSH certificate into
this session's ssh-agent:

```bash
bao-getkey
ssh derecho.hpc.ucar.edu      # no ncar-two-factor prompt
```

Every terminal you open in the session uses the same agent, so you only do
this once. When ssh starts prompting again, the certificate has expired: run
`bao-getkey` again. The key is kept only in the session's memory and is never
written to `~/.ssh`; it is gone when the session ends.

The first ssh to a host asks you to confirm its host key. That is expected;
answer `yes`.

### Troubleshooting

**`bao-getkey` says "error in libcrypto".** Your account does not have the
OpenBao `ssh-client-signer` policy yet, so no certificate was issued. This is
not a bug in the app; ask for the policy to be added to your account.

**`bao-getkey` worked, but a new terminal still prompts.** Your `~/.bashrc`
(or `~/.bash_profile`) probably starts its own `ssh-agent`, which replaces the
session's agent in each new terminal. Start one there only when no agent is
already set, for example:

```bash
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval "$(ssh-agent -s)" >/dev/null
fi
```

**`ssh-add -l` says "Could not open a connection to your authentication
agent".** Something in your shell start-up unset `SSH_AUTH_SOCK`. A login shell
(`bash -l`) puts it back; or check `echo $SSH_AUTH_SOCK`, which should be
`/tmp/cirrus-desktop/ssh-agent.sock`.

### How it is wired (for administrators)

- **`bao-getkey` is vendored** at `image/bao-getkey`, because its upstream repo
  (`NCAR/hsg-openbao-scripts`) is internal to the NCAR org and an
  unauthenticated build cannot fetch it. It is a verbatim copy of
  `bin/bao-getkey` at commit `ef6b7a7503c911977865df50df3b4d4fc223c25b`
  (sha256 `9fee1714bd7b149dec56798304350642167cae3eb9236aecfbc44fd39dc7bf9e`),
  and CI checks the hash. To update it, copy the file again and update the hash
  in the Dockerfile comment, the workflow and `image/test/acceptance.sh`.
- **The entrypoint starts one ssh-agent per session**, on container-local
  `/tmp/cirrus-desktop/ssh-agent.sock` (never the NFS home), and exports
  `SSH_AUTH_SOCK` before `xfce4-session` starts, so every terminal inherits it.
  It is stopped with the rest of the session.
- **Nothing in the desktop replaces it.** xfce4-session 4.18 starts its own
  ssh-agent unless it recognises one as already running, and looks for a
  gpg-agent too (`/startup/ssh-agent/enabled` and `/startup/gpg-agent/enabled`
  in the `xfce4-session` channel, both on by default). It did reuse ours in
  testing, but only because `SSH_AGENT_PID` was exported and alive, so
  `image/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml` turns
  both off. That file replaces the package's, so it carries the package's
  Failsafe session too. gnome-keyring is not installed and has no autostart
  entry, so its ssh component cannot take over either.
  `image/test/acceptance.sh` checks all of this in a running desktop.
- **`/etc/profile.d/cirrus-desktop.sh`** sets `SSH_AUTH_SOCK` for a login shell
  that lost it, and only when it is unset.

## Why KasmVNC

OnDemand's node proxy carries HTTP and WebSocket over one TCP port and nothing
else. That rules out the WebRTC desktops — Selkies and its relatives — which
want a UDP path and, without one, need a TURN server to relay over TCP. This
site does not have one.

So: a websocket-framed RFB stream. KasmVNC is that in **one process**. Xkasmvnc
is the X server, the RFB encoder, the HTTP server, the websocket endpoint and
the host of the web client, all at once. The alternative — TigerVNC plus
websockify plus noVNC — is three components, two of which exist only to bridge
what KasmVNC does natively.

Every claim below was measured against the KasmVNC in this image (1.5.0), not
taken from documentation. `image/test/acceptance.sh` asserts the ones a KasmVNC
bump could quietly break.

**One port carries everything.** From the start-up log:

```
vncext: Listening for websocket connections on 0.0.0.0 interface(s), port 8080
```

and the X server itself listens on unix sockets only — the only TCP listener in
a running session is the web port. There is no `600N` X port for anything else
in the cluster to reach.

**`-publicIP` has to be set.** Left alone, start-up calls out to the internet:

```
ICE: Querying public IP...
ICE: Trying 'stun.l.google.com', port 19302
ICE: My public IP is 128.117.66.102
```

That is a STUN query for the optional UDP transport, on the start-up path,
inside a startup-probe budget, for a transport OnDemand's proxy cannot carry
anyway. The entrypoint passes `-publicIP 127.0.0.1`, and the log then says
`ICE: Using public IP 127.0.0.1 from args`.

**`-displayfd`, not a fixed display and a poll.** The X server writes its display
number to that descriptor when it is ready to accept connections. That is the
server telling us, rather than a guess about how long an X server takes.

**Deliberately not `-MaxDisconnectionTime` / `-MaxIdleTime`.** KasmVNC can end
its own session on those, but then its exit status is whatever it chooses — and
`restart_policy: OnFailure` turns a nonzero status into a fresh pod. The
watchdog in the entrypoint owns that decision instead, so the status can be 0.

## Authentication, and why there is a gate in front of it

**KasmVNC authenticates for real.** HTTP Basic against `-KasmPasswordFile`, on
every request including the websocket upgrade, with brute-force blacklisting
behind it (`-BlacklistThreshold`, default 5):

```
$ curl -o /dev/null -w '%{http_code}'                 http://127.0.0.1:8082/   -> 401
$ curl -o /dev/null -w '%{http_code}' -u ncote:WRONG  http://127.0.0.1:8082/   -> 401
$ curl -o /dev/null -w '%{http_code}' -u ncote:right  http://127.0.0.1:8082/   -> 200
GET /websockify  without Authorization                                         -> 401
GET /websockify  with Authorization, Origin: https://ondemand.ucar.edu         -> 101
```

with `WWW-Authenticate: Basic realm="Websockify"` on the refusals. So the
question was never whether it is strong enough. It is the *shape* of the
credential that does not fit:

1. **HTTP Basic cannot be pre-supplied.** It is a header the browser sends only
   after its own native credential dialog. The dashboard's Connect button is a
   form POST, and a form cannot set that header. The user has already
   authenticated to OnDemand; being asked to type a second password into a
   browser dialog is the thing this app exists not to do.
2. **Browsers cache Basic credentials per origin.** Every session on this site
   shares `ondemand.ucar.edu`, so two concurrent desktops would contend for one
   cached credential and the loser gets 401s it cannot explain. This one is
   reasoning from documented browser behaviour rather than something measured
   here — but it is the reason to prefer a cookie even if the first point were
   somehow solved.

So `bin/cirrus-desktop-gate` holds the public port, turns one POST from the
dashboard into a cookie, and adds the `Authorization` header itself on the way
through to a KasmVNC bound to loopback. The user types nothing.

**KasmVNC's own auth stays on behind the gate**, and that is affordable because
of one measured detail: every response KasmVNC sends carries `Connection: close`
and the server *does* close, even when the request asked for keep-alive.

```
$ printf 'GET / HTTP/1.1\r\nHost: x\r\nAuthorization: Basic ...\r\nConnection: keep-alive\r\n\r\n'
HTTP/1.1 200 OK
Connection: close          <- and the socket ends after one response
```

One request per connection means checking the first request head **is** checking
every request, and adding the header to that one head covers all of them. A
server that reused connections would need a full HTTP parser in the gate, and
would get `-DisableBasicAuth` instead.

Two further properties of the gate are load-bearing:

* **Any `Authorization` header the client sent is removed, not appended after.**
  A browser that has been prompted by some other session on this OnDemand host
  holds a stale Basic credential for the origin and will send it; KasmVNC reads
  the first one. Asserted in the acceptance test by sending `-u wrong:wrong`
  alongside a valid cookie and requiring a 200.
* **It never sends `WWW-Authenticate`.** That header is precisely what summons
  the browser dialog. Also asserted.

The relay costs nothing measurable. 64 MiB through this design moves at
2877 MiB/s (24 Gbit/s) on loopback against 10517 MiB/s direct; a KasmVNC stream
is tens of Mbit/s. The pixel path is not where the time goes.

`CIRRUS_DESKTOP_AUTH=none` removes the gate and gives KasmVNC the public port
with `-DisableBasicAuth`. It exists for a session behind something else that
authenticates, and the entrypoint says loudly what it means. Exercised: `GET /`
answers 200 with no credential, the only listener is `0.0.0.0:8080`, the RFB
handshake completes, and the log carries
`WARNING: CIRRUS_DESKTOP_AUTH=none: anyone who can reach this port gets a
desktop`. With
`AUTH=password` and no password available the session **refuses to start** rather
than falling back — a pod that looks healthy while exposing a terminal in
someone's home directory is worse than one that does not come up.

## The proxy: `/rnode/`, not `/node/`

`/node/HOST/PORT/` forwards the whole path. `/rnode/HOST/PORT/` strips its
prefix inbound **and rewrites the response headers outbound**. From OnDemand's
`ood-portal.conf`:

```apache
Header edit Location "^([^/]+//[^/]+)|(?=/)|^([\./]{1,}(?<!/))" \
                     "/rnode/%{MATCH_HOST}e/%{MATCH_PORT}e"
Header edit* Set-Cookie ";\s*(?i)Path[^;]*" ""
Header edit  Set-Cookie "^([^;]+)" "$1; Path=/rnode/%{MATCH_HOST}e/%{MATCH_PORT}e"
```

So the app has to serve at the root and emit **unprefixed** redirects. Anything
that already carries the prefix gets it twice and the browser lands on
`.../rnode/host/port/rnode/host/port/` and the dashboard's 404.

Both halves were checked for KasmVNC.

**Serving at the root.** The client page references no root-absolute asset —
every one is `./assets/...` — and `host`, `port` and `encrypt` all come from
`window.location`:

```js
o.initSetting("host", window.location.hostname)
o.initSetting("port", r)                            // location.port, else 443/80
o.initSetting("encrypt", window.location.protocol === "https:")
```

So all of that survives the proxy. **The websocket URL does not**, and that is
the one place KasmVNC is not prefix-agnostic — see below.

**Unprefixed redirects.** The only `Location` KasmVNC ever emits is a
trailing-slash 301 on a directory path, and it is root-relative:

```
GET /app  ->  301 Moved Permanently
              Location: /app/
```

Run through the rule above, the `(?=/)` alternative matches zero-width at offset
0 and inserts the prefix, giving `/rnode/<node>/<port>/app/`. The acceptance test
does exactly that substitution against the real header, with `count=1` because
`Header edit` (not `edit*`) replaces the first match only:

```
ok   301 '/app/' rewrites to '/rnode/fakenode/30123/app/'
```

The gate's own 302 after a correct password is plain `/`, and its cookie `Path`
is `/`, for the same reason — the proxy supplies both.

**The prefix is still needed for exactly one thing:** the gate's login form
`action`. That lives in a response *body*, and bodies are not rewritten, so the
browser resolves it against the OnDemand host. It contains the node name and the
assigned NodePort, neither of which exists until the pod is scheduled and its
service created — so it cannot come from the pod spec. `add-baseurl-to-cfg`
computes it into the ConfigMap and the entrypoint reads it.

That page is a fallback nobody should reach; the Connect button posts straight
to `/rnode/<node>/<port>/cirrus-signin`. But when someone does reach it, a form
posting to the dashboard's own root is a 404 with nothing to read.

### The websocket path, which the first live launch found

Everything above is about what the *server* emits. The client has one URL it
builds root-absolutely, and it is the important one. From the bundle in this
image:

```js
a = o.getSetting("encrypt") ? "wss" : "ws";
a += "://" + t;          // window.location.hostname
r && (a += ":" + r);     // window.location.port, or 443/80
a += "/" + i;            // o.getSetting("path"), default "websockify"
```

Behind `/rnode/` that is `wss://ondemand.ucar.edu/websockify`. The
`/rnode/<node>/<port>` prefix is simply gone, and the handshake goes to the
OnDemand dashboard's own root rather than to the pod.

**The symptom is misleading**, which is why it is worth writing down: the client
page loads perfectly — every asset is relative, so the whole UI paints — and
then reports a failed connection. Nothing in the pod log says anything, because
the handshake never arrived.

The settings resolver is what makes it fixable from inside the pod:

```js
function hr(n,e){ const t = IA(n); return t===null ? CA(n,e) : t }   // query param first
function Zb(n,e){ Mr[n] = e }                                        // in-memory only
```

`hr` checks a URL query parameter **before** localStorage or the default, and
`Zb` — what `initSetting` uses to record the resolved value — writes to an
in-memory map rather than to `localStorage`. Both halves matter. The first means
a `?path=` parameter wins; the second means it is not persisted, so a value from
an earlier session (carrying an earlier session's NodePort) cannot come back to
haunt a later one on the same origin.

So the gate answers a GET for the client document that has no `path=` of its own
with a 302 to the same document carrying one:

```
GET /                             ->  302, Location: /?path=rnode/<node>/<port>/websockify
GET /?path=rnode/…/websockify     ->  200, proxied to KasmVNC
GET /screen.html?windowId=abc     ->  302, Location: /screen.html?windowId=abc&path=…
```

Root-relative and unprefixed as always, so the proxy prepends the prefix to the
Location. Done on **every** document request rather than only after sign-in, so a
reload gets the right value too instead of reverting to the default — and
`screen.html` too, which is the secondary-monitor window the client opens
itself.

The whole chain, simulated against the real rewrite rule:

```
pod emits          : /?path=rnode/mlc1w9.k8s.ucar.edu/32072/websockify
browser is sent to : /rnode/mlc1w9.k8s.ucar.edu/32072/?path=rnode/mlc1w9.k8s.ucar.edu/32072/websockify
client opens       : wss://ondemand.ucar.edu/rnode/mlc1w9.k8s.ucar.edu/32072/websockify
proxy forwards     : ws://mlc1w9.k8s.ucar.edu:32072/websockify
```

`CIRRUS_DESKTOP_ROOT_PATH` therefore has two consumers inside the pod: this, and
the login form's action.

**Why the acceptance test missed it, and what changed.** The old check asserted
that the string `window.location.pathname` appeared *somewhere* in the bundle.
It does — in the QOI worker loader and the secondary-monitor URL — so the check
passed for the wrong reason. Worse, the websocket probe connected to a
hand-written `/websockify`, a path the real client never asks for, so the one
thing that mattered was the one thing not exercised.

The test now derives the path instead of writing it: it reads the `path` the gate
handed the client, builds the URL the way the client does, strips the prefix the
way the `/rnode/` rule does, and requires the remainder to be what the pod
serves — then drives the RFB handshake over exactly that. It also asserts the
injection does not loop, and that a session with no prefix is *not* redirected.

## Keeping out of the shared home

`$HOME` is GLADE over NFS, shared with Casper and Derecho. **A desktop writes
far more into a home than an IDE does**, and this is where most of the effort in
this app went. Measured on this image, one XFCE session with no redirection at
all and nothing opened by hand:

```
.ICEauthority
.cache/sessions
.config/Thunar/uca.xml
.config/user-dirs.dirs   .config/user-dirs.locale
.config/xfce4/desktop/…  .config/xfce4/panel/…  .config/xfce4/xfconf/…  (13 files)
.dbus/session-bus/<machine-id>-1
.local/share
Desktop  Documents  Downloads  Music  Pictures  Public  Templates  Videos
```

Those eight bare directories are the worst of it. Nobody asked for them, they
are visible from every login node forever, and one of them — `Desktop` — differs
from this app's own directory only by case, which in a shared home is its own
trap.

If they are already in a home, this app is not necessarily what put them there:
`enabled=False` has been in the image since its first build, and
`xdg-user-dirs-update` under it leaves an empty home empty. GLADE is shared, so a
GNOME session or an `xdg-user-dirs` run on Casper or Derecho will have done the
same thing at some point. `stat -c '%y  %n' ~/Desktop ~/Documents ...` settles
which. Removing them is deliberately not this app's business — nothing here
deletes anything in a home it does not own, even an empty directory — but
`rmdir` refuses a non-empty directory, so

```bash
for d in Desktop Documents Downloads Music Pictures Public Templates Videos; do
    rmdir "$HOME/$d" 2>/dev/null && echo "removed empty ~/$d"
done
```

is safe to run by hand. **That is why the persist directory is `~/cirrus-desktop/` and not
`~/desktop`.** The entrypoint refuses a persist directory whose last component
case-insensitively matches any of the eight, whoever set it.

Five mechanisms, because those writers do not all read the same variable:

| what | how |
| --- | --- |
| `.cache`, `.config`, `.local/share` and everything under them | `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`, `XDG_RUNTIME_DIR`, `TMPDIR` |
| `.ICEauthority`, which is not XDG at all | `ICEAUTHORITY`, which libICE reads before falling back to `$HOME` |
| `.Xauthority` | `XAUTHORITY` — nothing wrote it in the measurement, but any X client may |
| `.dbus/session-bus/…` | not `dbus-launch`. See below. |
| the eight directories | `/etc/xdg/user-dirs.conf` with `enabled=False`, **and** a pinned `user-dirs.dirs` |

Split between two destinations:

| | |
| --- | --- |
| `$HOME/cirrus-desktop/config/` | `XDG_CONFIG_HOME` — panel layout, theme, keyboard shortcuts, Thunar |
| `$HOME/cirrus-desktop/data/` | `XDG_DATA_HOME` — application data, trash, recently-used |
| `$HOME/cirrus-desktop/{Desktop,Downloads,Documents,Music,Pictures,Videos,Templates,Public}/` | the XDG user dirs |
| `/tmp/cirrus-desktop/` | everything else: caches, runtime state, sockets, the session bus, the X and ICE authority files, the resolved password |

### The session bus is not started with `dbus-launch`

Two reasons, both about files. `dbus-launch`'s autolaunch path writes
`$HOME/.dbus/session-bus/<machine-id>-<display>` — that is where the `.dbus`
line in the measurement above comes from. And it starts the daemon as

```
/usr/bin/dbus-daemon --syslog --fork --print-pid 6 --print-address 8 --session
```

There is no syslog daemon in a container, so everything the session bus has to
say is discarded. The entrypoint runs `dbus-daemon --session --nofork
--nopidfile --nosyslog --address=unix:path=$XDG_RUNTIME_DIR/bus` instead: this
script owns the process, the socket is under `/tmp`, and the diagnostics land on
stderr like everything else.

### Both halves of the user-directory problem

`enabled=False` stops the **writer**. Pinning `user-dirs.dirs` fixes the
**readers** — GTK's file chooser, Thunar's sidebar and xfdesktop's icon view all
resolve these names, and with no file they resolve to `$HOME/Desktop`,
`$HOME/Documents` and so on, which xfdesktop would then create itself.

**All eight point inside `$HOME/cirrus-desktop/`, and all eight are created.**
Every one is still on GLADE and still visible from Casper and Derecho — they are
just under one predictable prefix instead of scattered across the top of the
home. Eight empty directories inside the app's own directory is a deliberate
trade against eight of them in `$HOME`.

They are created rather than left dangling because an application told its
Downloads directory is somewhere that does not exist either creates it or fails,
and which one it does is not worth discovering per application.

An earlier version pointed the seven non-Desktop entries at `$HOME` itself, which
the spec treats as "disabled" and GTK hides from its sidebar. That kept them out
of the way, but it meant a browser download landed loose in the home — so the
arrangement above replaced it.

The file carries a version marker, and rewriting it is conservative in three
steps:

* no file → write the current layout;
* a file this app wrote, with every path still where this app put it → upgrade it
  and say so in the log;
* anything else — a file without our header, or one of ours with a path pointing
  somewhere we would not have chosen — → left exactly as it is.

The middle case matters more than it looks: the first version of that file
carried no version marker at all, so it is recognised by the header text it wrote
instead. Without that, every session created before the marker existed would be
treated as hand-written and would keep the old layout forever — which is the
exact population the upgrade is for. All three paths are covered by tests.

### What is deliberately *not* redirected

`~/.gitconfig`. A user running `git config --global user.name` is configuring
their git identity, and sharing that with Casper and Derecho is the correct
outcome, not a leak. The acceptance test's home listing shows it appearing after
the desktop is driven, and that is expected. The same goes for `~/.ssh`.

### Proved, not assumed

The acceptance test runs a real session against a pre-populated home that looks
like an HPC user's — `.bashrc`, `.gitconfig`, `.config/pre-existing.json`,
`.local/share/MARKER`, a work directory — and afterwards asserts three separate
things:

```
ok   none of the XDG user dirs, .cache, .dbus, .ICEauthority or .config/xfce4 in $HOME
ok   nothing new anywhere outside $HOME/cirrus-desktop
ok   every pre-existing file is byte-identical (md5)
```

The middle one is a whole-tree `find` diff, so it catches anything the named
list missed. The last is `md5sum -c`, byte for byte.

Driving the desktop by hand — Thunar, Mousepad, `xfce4-appfinder`, and a real
`xfce4-terminal` running `whoami`, `git config --global`, and `touch` — added
nothing to `$HOME` beyond the files those commands were told to create.

## The runtime uid has no name

The pod runs as the user's real NFS uid, which has no `/etc/passwd` entry — and
a container runtime may synthesise a useless one whose **name is the uid**:

```
$ podman run --user 54321:54321 --entrypoint getent <image> passwd 54321
54321:*:54321:54321:container user:/:/bin/sh
```

So "does an entry exist" is the wrong test; an all-digits name is treated as no
name. `USER`, `NB_USER` and `GROUP` come from the pod spec and are the only
authority. The entrypoint writes a passwd/group pair under `/tmp` and
`LD_PRELOAD`s `libnss-wrapper`, filtering out any existing entry for the uid
rather than appending after it — nss_wrapper returns the first match.

A desktop needs this in more places than an IDE does: the terminal prompt,
`whoami`, git's committer identity (`fatal: unable to look up current user in
the passwd file` without it), ssh's default user, the session's own Log Out
menu, and Thunar's idea of where home is. Measured inside a session running as
uid 54321 with no entry of its own:

```
whoami                          -> ncote
bash -lc 'PS1="\u"; …'           -> ncote
getent passwd $(id -u) | cut -d: -f7  -> /bin/bash
git commit --allow-empty        -> succeeds; author resolves
ssh -G example.com | grep user  -> user ncote
```

The shell in that entry is `/bin/bash`, not the synthesised `/bin/sh`.
xfce4-terminal runs the shell from the passwd entry, and `/bin/sh` here is dash:
no readline, so the arrow keys emit `^[[A` instead of walking history — a
terminal that looks broken to anyone who has used one before. Asserted.

Nothing in this image is chowned.

## Idle culling and session length

Nothing outside the pod will reclaim an abandoned desktop, and a desktop holds
more than an IDE does: an idle XFCE session is a dozen processes plus the
framebuffer for the screen.

The signal is whether a client is connected, and KasmVNC reports it directly:

```
$ curl -u <user>:<pw> http://127.0.0.1:8082/api/get_sessions
{"users":[]}                                                    nobody attached
{"users": [{"username":"ncote","connected_since":"2026-08-21 17:07:38"}]}
```

Measured: a websocket that upgrades but never completes the RFB handshake does
**not** appear in that list. That is the right answer — a probe is not a session
— and it means neither the startup probe nor a half-open connection can keep an
abandoned desktop alive.

Polled over loopback, never through the gate: the gate would answer with its
login page, and a login page contains no `"username"` either, so a broken gate
would read as a permanently idle session and cull a desktop somebody was using.
An empty response is likewise treated as *connected*, not idle — a KasmVNC that
has stopped answering ends the session through `wait -n` instead, which is the
honest way for it to end. The credentials go in a `curl` config file rather than
on the command line, so the password is not in `ps` output.

Defaults: **1 hour** idle, checked every 5 minutes; **12 hours** maximum. Both
are enforced by the watchdog inside the pod, and the 12 hours is *also* a
`pod.kubernetes.io/lifetime` annotation via `wall_time` — which means something
only because OSC's `job-pod-reaper` is deployed on this cluster, whereas the
watchdog needs nothing deployed and can choose its exit status.

A culled session exits **0** so the pod completes; `restart_policy: OnFailure`
would otherwise bring it straight back and never release anything. Choosing Log
Out from the XFCE menu also exits 0 — that is a deliberate end to a session, not
a failure to restart into a fresh desktop nobody asked for. Which process ended
is decided *before* the shutdown signals go out, because asking afterwards races
against our own `SIGTERM`s.

The acceptance test covers the false positive as well as the cull: a session
with a client held attached past its idle timeout must still be running.

## Verifying it

```
podman build -t localhost/cirrus-desktop:dev -f image/Dockerfile image
image/test/acceptance.sh
```

Last run, 52 checks, all passing:

```
== 1. arbitrary uid, runtime-synthesised numeric passwd entry ==
  ok   the runtime does synthesise a numeric entry: 54321:*:54321:54321:container user:/:/bin/sh
  ok   id -un is ncote, not 54321
  ok   id -gn is ncar, not the image's own group
  ok   the passwd entry's shell is /bin/bash
== 2. arbitrary uid with NO passwd entry at all ==
  ok   id -un is ncote with no entry to start from
== 3. a session with no password refuses to start ==
  ok   no password: refuses to start, exit 1, and says why
== 4. the desktop starts and the gate holds the port ==
  ok   port answered 0s after container start (startup probe budget is 305s)
  ok   the gate listens on 0.0.0.0:8080
  ok   KasmVNC listens on 127.0.0.1:8082 only
  ok   no X TCP port is open (unix sockets only)
== 5. the password gate ==
  ok   no cookie: login page, form posting to /rnode/fakenode/30123/cirrus-signin
  ok   the gate never sends WWW-Authenticate (no native browser prompt)
  ok   wrong password refused (401)
  ok   correct password accepted, cookie issued
  ok   sign-in redirects to '/?path=rnode/fakenode/30123/websockify', unprefixed, so the proxy's rewrite lands under /rnode/fakenode/30123/
== 6. what the proxy will do to what KasmVNC emits ==
  ok   301 '/app/' rewrites to '/rnode/fakenode/30123/app/'
  ok   a stale client Authorization header is replaced, not forwarded (200)
  ok   the KasmVNC client page loads through the gate (200)
  ok   the client page references no root-absolute asset (safe to serve at /)
  ok   the client reads host/port from window.location (survives the proxy)
  ok   the client still defaults its websocket path to a bare 'websockify'
  ok   the document is redirected to '/?path=rnode/fakenode/30123/websockify' so the client learns the prefix
  ok   a document that already carries path= is served, not redirected again
== 7. websocket upgrade with a foreign Origin, and the desktop behind it ==
  client would open ws://<host>/rnode/fakenode/30123/websockify ; the proxy forwards /websockify
  ok   the client-computed path arrives at the pod as /websockify
  ok   no cookie: refused, no upgrade (HTTP/1.1 200 OK)
  ok   with the session cookie: 101, valid Sec-WebSocket-Accept, foreign Origin
  ok   the desktop is reachable: 1600x900 depth=24 name=x11 rects=1 pixelbytes=1024
== 8. the home directory afterwards ==
  contents: .bashrc .config .gitconfig .local .ssh_config_sample cirrus-desktop work 
  ok   $HOME/cirrus-desktop was created
  ok   none of the XDG user dirs, .cache, .dbus, .ICEauthority or .config/xfce4 in $HOME
  ok   all eight XDG user dirs resolve under $HOME/cirrus-desktop
  ok   all eight exist inside $HOME/cirrus-desktop
  ok   nothing new anywhere outside $HOME/cirrus-desktop
  ok   every pre-existing file is byte-identical (md5)
== 9. idle watchdog ==
  ok   with no proxy prefix the document is served directly, not redirected
  ok   a session with a client attached survives past its idle timeout
  ok   an idle session ends itself and exits 0 (so OnFailure does not restart it)
== 10. the appearance defaults point at things that exist ==
  ok   GTK theme 'Yaru-dark' has a gtk-3.0 directory
  ok   window manager theme 'Yaru-dark' has an xfwm4 directory
  ok   icon theme 'Yaru-dark' is installed
  ok   cursor theme 'Yaru' ships cursors
  ok   every icon theme 'Yaru-dark' inherits from is installed
  ok   interface font 'Ubuntu' is installed
  ok   no launcher on the default panel points at a missing program
== 11. a browser, and the renderer GTK4 needs to draw one ==
  ok   exo-open --launch WebBrowser returns (it blocks on a dialog with no browser)
  ok   xdg-open exists (what GTK apps and terminals actually call)
  ok   GSK_RENDERER=cairo is set (GTK4 windows map without DRI3)
== 12. a user can install things without root ==
  ok   archive tools, compiler and pip are all present
  ok   tar round-trips gzip, bzip2 and xz archives
  ok   gcc compiles and the result runs, as the unprivileged session uid
  ok   python3 -m venv builds a working venv with pip in it
  ok   the session's PYTHONUSERBASE is inside $HOME/cirrus-desktop (/home/ncote/cirrus-desktop/python)
== 13. versions recorded in the image ==
  ok   desktop-versions --check agrees with the record
```

### What the websocket check does and does not cover

Unlike the RStudio app's, this one is **not** against a controlled echo upstream.
It drives the real KasmVNC through the real gate: an RFB 3.8 handshake over a
websocket with a foreign `Origin`, then `SetEncodings` for Raw and a
`FramebufferUpdateRequest`, and it reads the pixel bytes back. `1600x900
depth=24 name=x11 rects=1 pixelbytes=1024` is a real framebuffer, so the check
covers the whole chain — cookie, header injection, upgrade, relay in both
directions, and an X server with a desktop on it.

Crucially the path is **derived, not written**: the test reads the `path` the
gate handed the client, assembles the URL the way the client does, strips the
prefix the way OnDemand's `/rnode/` rule does, and connects to whatever remains.
A hand-written `/websockify` here is what let the client's root-absolute URL
through the first time.

What it does not cover is a browser. The KasmVNC client negotiates encodings,
resizes the desktop with `SetDesktopSize`, and streams webp; none of that is
exercised here. The first launch in OnDemand is still the first time a real
client attaches.

### Versions

```
$ podman run --rm <image> bootstrap desktop-versions
base-image     docker.io/library/ubuntu:24.04
ubuntu         24.04
kasmvnc        1.5.0-1
xkasmvnc       1.5.0.17265facc40ab50db5740cdf0d12c61173edafc9
xfce4-session  4.18.3-1build2
xfwm4          4.18.0-1build3
thunar         4.18.8-1build3
python3        3.12.3
git            2.43.0
```

`desktop-versions --check` re-resolves each component and diffs against the
record, and the acceptance test runs it. A base-image rebuild can change every
one of these while the Dockerfile stays byte-identical.

## Why it looks the way it does

The first working session looked *broken* rather than minimal: stock GTK icons, a
grey square where "File System" should have had an icon, raw grey window
titlebars, and a floating dock. That was not the minimal package set showing
through — it was a dangling configuration reference, and it is worth writing
down because nothing failed and nothing was logged.

`xfce4-settings` ships `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml`,
which sets:

```xml
<property name="ThemeName"     type="string" value="Greybird"/>
<property name="IconThemeName" type="string" value="elementary-xfce-dark"/>
```

Both `greybird-gtk-theme` and `elementary-xfce-icon-theme` are *Recommends* of
the XFCE packages, and this image is built with `--no-install-recommends`. So
XFCE asked for a theme and an icon set that were not in the image, GTK silently
fell back to its built-in Adwaita with no icon theme at all, and the desktop came
up looking like a fault. A session that renders is not a session that renders
*right*, and the acceptance suite had nothing to say about it.

### GNOME Shell is not an option, and that was tested

The obvious answer to "make it look like GNOME" is to run GNOME. It does not
work here, for two independent reasons, both measured by building it into a
probe image and starting it under this same X server:

```
Gjs-CRITICAL **: JS ERROR: Gio.IOErrorEnum: Could not connect: No such file or directory
  LoginManagerSystemd@resource:///org/gnome/shell/misc/loginManager.js:96:9
  getLoginManager@resource:///org/gnome/shell/misc/loginManager.js:84:29

libEGL warning: DRI3 error: Could not get DRI3 device
libEGL warning: Ensure your X server supports DRI3 to get accelerated rendering
```

GNOME Shell resolves its login manager through **systemd-logind** and exits when
it cannot reach it. logind needs systemd as PID 1, which an unprivileged OOD pod
does not have. Separately, Xkasmvnc exposes no DRI3, so mutter gets no
accelerated rendering — GNOME Shell is a GL compositor, and this pod has
llvmpipe at best.

### So: XFCE wearing Ubuntu's GNOME theme

`yaru-theme-gtk` and `yaru-theme-icon` — Ubuntu's own theme, so this is the look
of an Ubuntu GNOME desktop rather than an approximation. Yaru is the pick for one
concrete reason beyond that: it is the only GTK theme in the archive that also
ships an **xfwm4** variant, verified from the package contents:

```
themes/Yaru-dark/gtk-2.0  gtk-3.0  gtk-4.0  metacity-1  xfwm4
```

xfwm4 draws window borders from its own theme directory, and most GTK themes
ship none — so without that the widgets would be themed and the frames around
them would still be the 1990s `Default`.

Delivered as **system-wide xfconf defaults**, not a runtime seeding step: xfconf
reads `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/` through `XDG_CONFIG_DIRS` and
copies the values into the user's own channel files on first launch. So anything
changed in *Settings → Appearance* wins from then on, and persists in
`$HOME/cirrus-desktop/config` like the rest of their desktop state. No code
runs, and there is nothing to un-seed.

Two of the four files are about this **transport** rather than taste:

* **Grayscale antialiasing, not subpixel** (`Xft/RGBA = none`). Subpixel
  rendering colours the edge of every glyph on the assumption that it lands on a
  physical LCD stripe in that order. This framebuffer is JPEG/WebP encoded by
  KasmVNC and decoded in a browser at whatever scale the window happens to be:
  the fringes survive as artefacts *and* cost bitrate, because chroma detail is
  exactly what a lossy encoder is trying to discard.
* **A flat desktop colour, not a photograph.** A full-screen wallpaper is a
  large high-entropy region to re-encode on every full-frame update, and it looks
  worst precisely when scaled to an arbitrary viewport. Set `image-style` to 5
  and point `last-image` somewhere under `/usr/share/backgrounds` if a picture is
  wanted.

Two smaller things that cost a measurement each:

* The backdrop is keyed on the **RandR output name**, and Xkasmvnc calls its
  output `VNC-0`. The first attempt used `monitorscreen`, the legacy fallback
  name, and xfdesktop ignored it entirely — the desktop kept xfdesktop's own
  built-in blue. Asked of a live session:

  ```
  $ xfconf-query -c xfce4-desktop -l | grep backdrop
  /backdrop/screen0/monitorVNC-0/workspace0/color-style
  ```

* `yaru-theme-icon` declares **no dependencies at all**, and every Yaru variant
  reads `Inherits=Yaru,Humanity,hicolor`. Humanity was in the image only as an
  accident of something else's dependencies — which is the same dangling
  reference one level down, so every link is now named explicitly and asserted.

### The panel

One bar at the top: Applications on the left, the clock centred the way GNOME
centres it, status menu on the right. The stock XFCE layout is a menu bar plus a
floating bottom dock, and it was replaced for two reasons — one cosmetic, one a
real defect:

* its `plugin-19` is a launcher for `xfce4-web-browser.desktop`, which runs
  `exo-open --launch WebBrowser`. This image has no browser and no `xdg-open`, so
  that button sat on the dock looking like a feature and did nothing. **A dead
  control is worse than an absent one.**
* one top bar gives back the strip the dock was using, which matters more here
  than on a laptop: the desktop is only as tall as a browser window with browser
  chrome above it.

Nothing on the new panel is a launcher, so nothing on it can be dead — and the
acceptance suite now checks that claim for whatever layout is shipped.

### A browser, and the renderer GTK4 needs in order to draw one

Clicking the panel's Web Browser button reported *"Failed to execute default Web
Browser"*. Not a missing feature — a control that fails. XFCE's stock panel ships
that launcher running `exo-open --launch WebBrowser`, and with nothing to launch
the call does not error out, it **blocks on a GTK dialog**: measured,
`exo-open --launch WebBrowser https://example.com` never returned. Removing the
launcher would not have been enough either, because clicking a URL anywhere calls
the same helper.

**GNOME Web, and that is forced rather than chosen.** In the noble archive both
of the obvious answers are snap transition packages:

```
firefox           1:1snap1-0ubuntu5
chromium-browser  2:1snap1-0ubuntu2
```

and snap does not work in a container. `epiphany-browser` 46.5 is a real deb, it
is GNOME's own browser, and exo already ships a helper naming its binary:

```
epiphany.desktop   X-XFCE-Binaries=epiphany;org.gnome.Epiphany;
```

so `exo-open` finds it with **no configuration at all** — verified, exit 0. Plus
`xdg-utils`, because GTK apps and terminal workflows call `xdg-open` rather than
`exo-open`. WebKit's `bwrap` sandbox works unprivileged here, which was the risk
worth checking:

```
/usr/bin/bwrap --args 37 -- /usr/lib/x86_64-linux-gnu/webkitgtk-6.0/WebKitWebProcess
```

**And then it still did not draw anything.** Epiphany ran, its WebKit processes
ran, nothing was logged, and the screen stayed empty. GNOME Web 46 is a **GTK4**
application; GTK4 renders through GSK, whose default backend is GL, and this X
server provides no DRI3:

```
libEGL warning: DRI3 error: Could not get DRI3 device
libEGL warning: Ensure your X server supports DRI3 to get accelerated rendering
```

So GSK could not create a context and the window never mapped. `GSK_RENDERER=cairo`
in the image environment fixes it, and the same command then renders the page.

This is the failure mode worth remembering: **nothing else in the image showed
it, because XFCE, Thunar and Mousepad are all GTK3**, which uses cairo on X11
already. It only appears the first time a GTK4 application is added — which is
exactly when nobody is looking for it. `GTK_A11Y=none` is set alongside it for the
log rather than the screen; there is no accessibility bus in a session pod, and
GTK names the variable itself in the warning.

A side note on the debugging, because it cost time: `timeout 20 epiphany …`
reported *"Web process crashed"* three times, which looked like a WebKit sandbox
failure. It was not — those messages appear at exactly the moment `timeout` sends
its SIGTERM. Run detached there were no crashes at all, and the several
`WebKitWebProcess` instances were tabs from earlier launch attempts, not respawns.
A test harness that kills the thing it is measuring will describe the killing.

### An existing session keeps its old panel

`xfce4-panel` copies `/etc/xdg/xfce4/panel/default.xml` into the user's own
configuration on **first** launch. So a session that has run before keeps the
layout it already has, dock and all, in `$HOME/cirrus-desktop/config/xfce4/panel/`
— a new default does not reach it, and the entrypoint deliberately does not go
editing a configuration the user owns.

Which is the main reason installing a browser was the right fix rather than only
removing the launcher: the old dock's Web Browser button now **works** instead of
needing surgery. Anyone who wants the new single-bar layout can delete
`~/cirrus-desktop/config/xfce4/panel/` and relaunch.

### Light or dark

`Yaru-dark` is the default. For the light variant, change the four names in
`image/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`
(`xsettings.xml`: `ThemeName`, `IconThemeName`; `xfwm4.xml`: `theme`) from
`Yaru-dark` to `Yaru`, and lighten the `rgba1` values in `xfce4-desktop.xml`. The
panel stays dark either way, which is how Ubuntu GNOME looks. A user can also
just switch it in *Settings → Appearance* for their own sessions.

### The regression guard

The check that would have caught all of this is now section 10 of the acceptance
suite: **every name the appearance defaults mention must resolve to something in
the image** — the GTK theme's `gtk-3.0/`, the window manager theme's `xfwm4/`,
the icon theme's `index.theme`, every theme it inherits from, the cursor theme's
`cursors/`, the interface font family, and every `Exec=` behind every launcher on
the default panel.

## Installing things yourself, without root

There is no root in this session and there cannot be: the pod runs as the user's
own uid so files written to GLADE belong to them. Measured:

```
$ apt-get install -y cowsay
E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)
E: Unable to acquire the dpkg frontend lock, are you root?
```

Writable paths are **`/tmp`, `/var/tmp` and `$HOME`** — `/usr`, `/usr/local`,
`/opt`, `/var` and `/etc` are all read-only.

The image therefore carries the tools that make "install it in your home"
actually workable. Each one closes a dead end that was measured in the image
before it was added:

| | closes |
| --- | --- |
| `xz-utils` `bzip2` `zstd` `unzip` | `tar -J` and `tar -j` both **failed** — the image had `gzip` and nothing else, and most upstream releases ship `.tar.xz`. (`dpkg -x` was always fine; `dpkg-deb` links liblzma itself.) |
| `wget` | a great many install scripts assume it |
| `python3-pip` `python3-venv` | `python3 -m venv` **failed**: Debian strips `ensurepip`, so venv could not provision pip and there was no pip to fall back on |
| `build-essential` `python3-dev` | no compiler at all. `python3-dev` comes with it rather than after it — pip building any C extension fails on a missing `Python.h`, which is a confusing error to hit when a compiler is demonstrably present |

72 MB of download, 66 MB of it the compiler; the image goes from 979 MB to
1.26 GB. Weigh that against a session where the answer to "can I install X" is
no.

### Python: use a venv

Ubuntu 24.04 marks the system Python externally managed, so PEP 668 refuses the
obvious thing:

```
$ pip3 install --user six
error: externally-managed-environment
```

A virtual environment is the supported route and works normally:

```bash
python3 -m venv ~/cirrus-desktop/venv
~/cirrus-desktop/venv/bin/pip install <whatever>
```

`PYTHONUSERBASE` is pointed at `~/cirrus-desktop/python` for the person who
reaches for `--break-system-packages` anyway. Left at its default,
`pip install --user` writes to `$HOME/.local/lib/python3.12/site-packages`,
which **any Python of the same minor version on Casper and Derecho imports** —
and a compiled extension built here would then be picked up there and fail
somewhere else entirely. Same hazard as the R library in the sibling RStudio app.

### ⚠️ Anything you build here is this container's

glibc is **2.39** on Ubuntu 24.04. `$HOME` is GLADE, shared with Casper and
Derecho. A binary compiled in this container will generally **not** run on those
systems, nor the reverse, and unlike the R library there is no hook that can
catch it for a compiler. Build into `~/cirrus-desktop/` and treat the result as
belonging to this image.

### What is still possible with apt

`apt` works for everything except the final install step. Redirect its state
somewhere writable and it will even resolve the dependency closure:

```bash
APT="apt-get -o Dir::State::Lists=/tmp/apt/lists -o Dir::Cache::Archives=/tmp/apt/cache/archives"
mkdir -p /tmp/apt/lists/partial /tmp/apt/cache/archives/partial
$APT update
$APT install -s --no-install-recommends <pkg>     # prints the "Inst" closure
$APT download <the closure>
for d in *.deb; do dpkg -x "$d" ~/cirrus-desktop/local; done
```

Extraction gives files, not an install, so the program then has to be told where
its pieces are — either through the environment variables it documents
(`PATH`, `LD_LIBRARY_PATH`, `PERL5LIB`, …) or by grafting the tree over the real
prefixes:

```bash
bwrap --dev-bind / / --bind ~/cirrus-desktop/local/usr/lib/... /usr/lib/... <program>
```

Unprivileged user namespaces are available (`unshare -Ur` gives uid 0,
`max_user_namespaces` is unlimited), which is what makes that `bwrap` work — and
what WebKit's sandbox is already using. Two limits found by trying: `bwrap` can
only bind **over a path that already exists**, and unprivileged **overlayfs is
refused**, so there is no way to get a writable-but-populated `/usr` and run apt
for real. `apt -o RootDir=` fights its own path handling and is not worth it.

For anything durable or shared, the right answer remains `image/Dockerfile` plus
a CI run: real dependency resolution, reproducible, and it stays out of the
shared home.

## What is installed, and what is not

XFCE core — session, window manager, panel, desktop, settings — plus
xfce4-terminal, Thunar, Mousepad and xfce4-appfinder. Then `git`, `less`,
`nano`, `curl`, `jq`, `openssh-client` for the terminal (and `bao-getkey`, which
needs the last three), and `python3` for the gate.
Appearance: `yaru-theme-gtk`, `yaru-theme-icon`, `humanity-icon-theme`,
`adwaita-icon-theme`, `fonts-ubuntu`, `fonts-dejavu-core`. And
`epiphany-browser` plus `xdg-utils`, so that clicking a URL does something.

And the self-help toolchain above: `build-essential`, `python3-dev`,
`python3-pip`, `python3-venv`, `xz-utils`, `bzip2`, `zstd`, `unzip`, `wget`.

Roughly **1.26 GB**: about 145 MB theme and fonts, about 200 MB browser and
WebKit, and about 280 MB compiler and toolchain. All one-time pulls per node,
cached by Harbor. To drop the browser, remove `epiphany-browser` and `xdg-utils`
— and leave the panel default without a browser launcher, because the two go
together. To drop the toolchain, `build-essential` and `python3-dev` are 66 MB of
the 72 MB download on their own.

That is the deliberate scope: the reason to open a desktop here is to look at
and manipulate files on GLADE, and everything beyond that a user brings from
their home directory. A fuller desktop is mostly a larger image to pull on every
cold node.

Notable omissions:

* **No Firefox or Chromium.** Both are snap transition packages in the noble
  archive and snap does not work in a container. GNOME Web is installed instead;
  Firefox would mean adding Mozilla's own APT repository and ~250 MB.
* **No `tumbler`.** Thunar *Recommends* it for thumbnails and
  `--no-install-recommends` leaves it out. Thumbnails are a cache written per
  image file — one more writer aimed at the home directory. Image previews in
  Thunar are the visible loss.
* **No VirtualGL, no hardware OpenGL.** Out of scope for this version.
  `libgl1`/`libglx-mesa0` are installed so an application that touches GL
  renders in software rather than crashing. KasmVNC reports
  `Hardware video encoding acceleration capability: unavailable`, which is
  correct and expected.
* **No PulseAudio.** There is no audio path through the proxy — which is also
  why `EnableEventSounds` is off in the appearance defaults rather than left at
  its default: an event sound nobody can hear is still a file read and a decode.
* **No GNOME Shell, MATE or Cinnamon.** See above for GNOME Shell, which was
  tested and cannot work here. MATE and Cinnamon were not tried; XFCE is the one
  that is already proven against every other constraint in this app.

To add software, add to the `apt-get install` in `image/Dockerfile`, rebuild,
and re-run `image/test/acceptance.sh` — the home-isolation checks are exactly
what a new package can break.

### Harmless noise in the pod log

A session logs these every time and none of them is a problem:

```
xfce4-session-WARNING: No GPG agent found
xfwm4-WARNING: Another compositing manager is running on screen 0
libupower-glib-WARNING: Couldn't connect to proxy
xfdesktop: Failed to get system bus
xfce4-panel-Message: Plugin "pulseaudio-8" was not found and has been removed
xkbcomp: Warning: Could not resolve keysym XF86…
```

The compositing one is Xkasmvnc's own compositor, which xfwm4 correctly defers
to. The system-bus ones are the absence of a *system* bus, which a session pod
has no use for. The panel messages are the default panel configuration
referencing plugins this image does not install; the panel rewrites its own
config in `~/cirrus-desktop/config/` and does not ask again.

### Whose stderr goes where

Everything the desktop's own processes print lands in `kubectl logs` — the user
sees a framebuffer, not a stream, so there is no "user's session" output the way
RStudio's Console is. The exception is a terminal: xfce4-terminal gives its
children a pty, so what a user runs interactively stays in the window.
`bin/cirrus-desktop-session` says so in the log at start-up, because the first
question about a strange log line is which side it came from.

## Assumptions that a live launch is the first real test of

1. **The pod's service account can `get` pods and services in its namespace and
   cannot `list` them.** The init containers use `kubectl get` throughout for
   that reason. Checked as far as this kubeconfig allows:

   ```
   $ kubectl auth can-i get  pods     --as=system:serviceaccount:<ns>:default  -> yes
   $ kubectl auth can-i list pods     --as=system:serviceaccount:<ns>:default  -> no
   $ kubectl auth can-i patch configmaps --as=…:default                        -> yes
   ```

   The sibling apps already depend on the same shape.
2. **This OOD version surfaces the `<pod>-secret` keys to `view.html.erb`.** The
   other CIRRUS apps get `password` this way; nothing new is asked of it here.
3. **The browser client's `SetDesktopSize` works through the proxy**, which is
   why there is no resolution field on the form. If it does not, the desktop
   stays at `CIRRUS_DESKTOP_GEOMETRY` (1600x900) and that becomes a form field.

The first live launch already found one of these the hard way — the client's
websocket URL, above. The lesson generalised: a hand-written path in a test is
not a test of what the client does. Anything the *client* computes should be
derived in the test from what the pod actually tells it.

## CI

`ubuntu-latest`, no remote buildkitd, no scan job — Harbor runs Trivy itself.
Triggers on `workflow_dispatch` and on pushes to `main` touching `image/**` or
the workflow. Tags are date stamps, `%Y-%m-%d.%H.%M`, pushed to
`hub.k8s.ucar.edu/ncote/ubuntu-desktop`, with `HARBOR_LOGIN` and `HARBOR_SECRET`
as the credentials.

Before anything is pushed, a smoke test runs the image as an arbitrary uid: the
tools are present (`ssh`, `ssh-agent`, `ssh-add`, `jq`, `curl`, `bao-getkey`
and the desktop's own), `bao-getkey`'s sha256 matches the vendored upstream, the
uid gets a user name, a real session's gate serves its login page, and the
session's ssh-agent answers `ssh-add -l` with exit 1 (no identities). A failure
fails the build and nothing is pushed.

**After a successful push, CI pins the new tag in `submit.yml.erb` itself**: a
`github-actions[bot]` commit, `Pin desktop_img to ubuntu-desktop:<tag> [skip ci]`,
made on top of the latest `main`. So pull before editing locally. It only does
this for builds of `main`. A manual run can set `skip_bump` to build and push
without pinning. The workflow's paths filter does not include
`submit.yml.erb`, so the bot's commit does not start another build. If `main`
is ever branch-protected, the bot needs to be allowed to push to it.

The pinned image has passed the smoke test, not `image/test/acceptance.sh`. Run
that against it before announcing a change to users.

The run writes a job summary with the full reference, whether and by which
commit it was pinned (or the `desktop_img = "..."` line to paste when it was
not), the pushed digest and the versions recorded in the image.

Harbor's Trivy scan cannot be run from here, so "no Criticals" is unverified —
check it after the first push. The image does `apt-get upgrade` at build time.
The KasmVNC `.deb` comes from its GitHub release; `KASMVNC_SHA256` is a build
arg that is verified when set and is empty by default, because a
wrong-but-present hash nobody has checked is worse than an honest absence. The
version is pinned regardless.
