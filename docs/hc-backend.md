# hc runtime backend

hc is an experimental session-provider backend for herdr-core, the terminal core under Herdr.app.
It provides task terminals while Treehouse continues to provide git worktrees, the same split tmux uses.
herdr-core is not Herdr 1: the `herdr` backend ([`herdr-backend.md`](herdr-backend.md)) talks to the `herdr` multiplexer, and the two share no socket, id space, or CLI.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.
This page owns operator setup and supported limits; the adapter header in `bin/backends/hc.sh` explains implementation decisions.
[`verification/runtime-backends.md`](verification/runtime-backends.md#hc) records what was exercised against a real core.

## Setup

Prerequisites:

- Herdr Core at version 0.1.14 or later, self-identifying as `hc x.y.z`, and a core speaking protocol generation 1.
  Binary resolution uses an executable `FM_HC_BIN` override first, then `herdr-core` on `PATH`, then the `hc` alias.
  `hc` starts its own core on first use.
  [`bin/fm-install-hc.sh`](../bin/fm-install-hc.sh) owns installation usage and the checksum-verified release pin; updates remain operator-run.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select hc explicitly with local `config/backend` containing `hc`, `FM_BACKEND=hc` for one launch, or an explicit request to Firstmate.
An explicit setting always wins; see "Runtime auto-detection" below for when hc is also selected automatically.

The core a task lands on is the one `HC_SESSION` names when the task is spawned, or hc's `default` session when it is unset.
The Herdr app shows the terminals of the session it bound at launch, `default` unless the app was started with a different `HC_SESSION`.

## Runtime auto-detection

hc is auto-detected only on the Herdr app's terminal-level signal, never on bare `HC_TERMINAL_*` markers: hc stamps them into every process an hc terminal starts, and an app-created terminal's env is deliberately identical to any other hc terminal's - the app sends `TERM_PROGRAM=herdr` in its `terminal.run` call, but the core's `child_env` normalizes that to `ghostty` for every child, app-created or not.
What marks a terminal as the app's is its core-side record: the app stamps `herdr.space`/`herdr.tab` labels on every terminal it creates, and a non-empty `herdr.space` is the exact condition under which the app projects a terminal into its window.
[Backend selection order](configuration.md#backend-selection-order) owns precedence; this section owns the app-terminal signal.

Exactly one signal selects hc, after every other surface marker has had its say:

- `app-terminal`: this process's own `HC_TERMINAL_ID` terminal carries a non-empty `herdr.space` label in its core's record.
  The check is read-only and gated: a unix connect must first prove `HC_TERMINAL_SOCKET` live, because `hc` starts a core on contact with a missing socket and a bare `hc get` could create state; then one `hc get` reads the label through the resolved binary.
  Missing markers, a dead socket, a missing or unusable `hc`/`jq` toolchain, a `get` failure, or an empty label are all a miss, never a detection.

A live `herdr-app.sock` or an open window is deliberately not a signal: every process on the host can see it, so it cannot tell a Firstmate inside an app terminal from one on a bare shell while the window happens to be open elsewhere.
Live testing against the real app confirmed the ambiguity - marker-less processes selected hc solely because a window existed - so only the terminal-level claim above can auto-select hc.
A captain who wants a shell outside the app to spawn hc workers sets `config/backend`, `FM_BACKEND`, or `--backend` explicitly.

The signal binds the core a spawn would actually reach, the `HC_SESSION` (else `default`) session, and requires it to be running already, because the adapter's container ensure starts a missing core and detection must never start one.
`bin/fm-backend.sh` resolves that core's socket without calling `hc`: an `FM_HC_SOCKET` pin, else `$XDG_RUNTIME_DIR/herdr-core/<session>.sock` when `XDG_RUNTIME_DIR` is set, else `${XDG_STATE_HOME:-~/.local/state}/herdr-core/<session>/<session>.sock`, the layout measured on hc 0.1.14.
`app-terminal` additionally requires `HC_TERMINAL_SOCKET` to be that same socket, so a labeled terminal on some other core never steers a spawn.
The app shows the session it bound at launch, so a captain whose app runs a session other than `default` sets the same `HC_SESSION` for Firstmate or selects hc explicitly.

An explicit `--backend`, `FM_BACKEND`, or `config/backend` always wins over detection.
Inside the classic Herdr TUI, `HERDR_ENV=1` wins before the app signal is consulted, so the `herdr` backend keeps its behavior; inside tmux, `$TMUX` wins the same way, so a marker-less or contradictory process on either surface never sees the app check at all.
A contradictory marker set (for example another surface's marker alongside the app's) keeps the earlier surface's verdict rather than switching - ambiguous input means no automatic switch.
When a live hc terminal is present but no usable hc toolchain resolves (an executable `FM_HC_BIN`, or `herdr-core`/`hc` on `PATH` reporting `hc x.y.z` at or above the adapter's verified minimum, plus `jq` - the same version gate the spawn's container check applies), detection does not switch and a notice names the missing piece instead; a bare terminal marker set is still never a detection.
An auto-detected hc prints a stderr notice naming the winning signal and how to opt out; [Task shape and metadata](#task-shape-and-metadata) owns its task record.

Auto-detected hc spawns carry the same `herdr.space`/`herdr.tab` labels an explicit hc spawn does, so workers appear in the captain's window without the app ever being started by Firstmate.
The app is local GUI presentation only; detection reads the terminal's core-side label without requiring a live app window, so a surviving labeled terminal can still select hc after the GUI closes.
An hc primary defaults new remote secondmates to hc and can select `herdr` or `rex` explicitly through the separate remote home described in [Remote second mates](remote-secondmates.md).

Away-mode supervisor discovery is owned by [Away-mode supervisor backend](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target).

## Task shape and metadata

Each task is one hc terminal running the user's login shell in the project directory, started with `--no-parent --outlive-parent --no-notify` so it is independent of whichever hc terminal Firstmate itself runs in.
The terminal carries these labels:

| Label | Value | Purpose |
| --- | --- | --- |
| `firstmate.task` | `fm-<id>` | Task identity checked before input or close. |
| `firstmate.home` | `<hometag>` from `bin/fm-backend-hometag-lib.sh` | Keeps two homes with the same task id apart. |
| `herdr.space` | `fm-<hometag>-fm-<id>` by default | Gives each ship or scout a Herdr.app space. |
| `herdr.tab` | `<hometag>-fm-<id>` | One Herdr.app tab per task. |
| `herdr.seen` | `0` at creation | Lets Herdr clients show later completed turns as unseen. |
| `firstmate.group` and `firstmate.group-order` | Group and order from `config/herdr-project-groups`, when enabled | Records display metadata on the terminal. |

```text
backend=hc
backend_detect=app-terminal
window=<session>:<address>
hc_session=<session>
hc_terminal=<address>
```

`backend_detect=` is `app-terminal` only when that signal automatically selected hc; an explicitly selected hc writes no `backend_detect=` line.

The shared `config/herdr-presentation-spaces` setting selects per-task spaces for ship and scout tasks.
Absent, empty, and `on` select a per-task space; `off` selects the shared `fm-<hometag>` home space.
An invalid value warns and uses the default.
A secondmate stays in the shared home space.
An explicit `FM_HC_SPACE` selects that space instead.
Changing a setting affects new terminals only.

The shared `config/herdr-project-groups` setting uses the same project and task selector rules as [Herdr project groups](herdr-backend.md#project-groups).
When enabled, Firstmate records the resolved group and order on each new ship or scout terminal.
Herdr.app does not expose Herdr's project-group sidebar, sorted agents view, or workspace ordering through these labels.
Group labels are metadata only, not a visual group or task ownership, and changes to rules do not update existing terminals.
Use `hc get` to inspect them.

`<address>` is hc's terminal address such as `t7`.
Every adapter call sets exactly the recorded `HC_SESSION` and drops any inherited `HC_SOCKET`, which hc would otherwise prefer, so a task keeps reaching its own core even when the caller's environment names another one.
`FM_HC_SOCKET` is the deliberate socket pin tests and labs use instead of an inherited `HC_SOCKET`.
An input, capture, or close that carries the task label refuses a terminal whose `firstmate.task` or `firstmate.home` label does not match, and a close without a label still refuses a terminal that lacks this home's labels.

## Operations

| Operation | hc command |
| --- | --- |
| Container ensure | `hc server status` plus the `hello` generation handshake over `hc connect` |
| Create task | `hc run --bg --no-parent --outlive-parent --no-notify --cwd <project> --label ...` |
| Capture | `hc read --lines <n>` |
| Visible capture | `hc read --lines 0` |
| Send a line and submit | `hc send` |
| Submit with confirmation | Use `hc send --wait`, refusing a confirmed draft and guarding idle sends |
| Named key | `hc keys` |
| Current path | `hc get`, the foreground process's `cwd` |
| Busy state | `hc get`, native `status.state` (`working` is busy) |
| Agent state | `hc get`, the foreground process and its process group, through the shared classifier |
| Composer state | `hc read --lines 0` through the shared classifier, with `hc get` native status settling a row that equals a known idle placeholder |
| Close | `hc kill`, then `hc rm`, then `hc get` must answer not found |

## Away and quiet supervision

The away daemon runs in its own hc terminal without Herdr app presentation labels.
Firstmate records its exact terminal and closes only that terminal when the daemon stops.
The daemon checks that the supervisor composer is empty before sending marked input.

## Limits

- `hc send` always presses Enter, and `hc keys` cannot type arbitrary Unicode text.
  `bin/fm-spawn.sh` pastes and submits the spawn launch line with `hc send` and consumes the Enter that follows it.
- `hc read` returns plain text, so a harness's dim idle placeholder and a typed copy of the same words arrive as identical characters.
  The composer reads `empty` when the composer row exactly equals an idle placeholder from the shared set in `bin/fm-composer-lib.sh` and hc's native status is `idle` or `done`.
  Any other row, a one-character difference, a `working` or `blocked` status, or a terminal without native status reads `unknown` or `pending`, so `exit`, `relaunch`, and away-mode injection refuse.
  A person who types the placeholder's exact text at a native-idle prompt is the residual: that draft reads `empty` here, where Herdr's styled read would see pending text.
  The 60-second draft hold inside `hc send` and the `--if idle` condition narrow that window but do not close it.
- When hc reports idle, Firstmate refuses a confirmed draft and sends with `--if idle` otherwise.
  An unknown composer can contain a draft that the screen classifier cannot identify.
  When hc does not report idle, Firstmate sends without the idle condition, so a terminal without native status remains reachable.
  The screen read and `hc send` are separate, so a draft can appear between them.
  Away and quiet escalations stay buffered when the supervisor composer cannot be classified.
- hc reports one foreground process per terminal.
  When that process is a launcher, the adapter also reads the rest of its process group from `ps`, which works only for terminals on the local machine.
- Right after a terminal starts, `hc get` can report no foreground process yet, and agent state reads `unreadable` until the shell is up.
- Secondmates run in their own home, with their terminal labeled for the launching home so that its control and recovery paths can identify it.
  Control can interrupt, exit, and relaunch an agent in a live terminal.
  A missing terminal follows secondmate recovery; control does not rebind it.
  Ship and scout reclaim requires a matching recorded core ID and proof that the recorded agent PID with its recorded start time is no longer live.
  Records without these identities refuse a missing terminal.
  If the agent cannot be classified at spawn, its identity is not recorded and reclaim refuses.
  A detached descendant can survive terminal closure and is not covered by this proof: an hc 0.1.21 lab fixture survived in a separate session with its working directory at `/`.
- A worker inherits `HC_SESSION`, `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, and `HC_SCOPE` from its terminal, and the `config/launch-env-allowlist` floor keeps them; whether a real harness then reports native status under Firstmate's launch is not verified.
- Naming, ordering, and arranging Herdr.app spaces and tabs need the app window and are not done by Firstmate.
  The `herdr.space`/`herdr.tab` label contract above is the app's documented bridge (its window projects labeled terminals as spaces/tabs and keeps unlabeled ones hidden), verified against a real window: [`verification/runtime-backends.md`](verification/runtime-backends.md#hc) records the live exercise.
- The `herdr` backend's project-group sidebar tokens, sorted agents view, and group ordering have no equivalent in the hc adapter.
  The group labels described above do not change the app layout.
- Firstmate does not change `herdr.pinned` or update `herdr.seen` after creation.
  Herdr clients own pinning and mark turns seen when a person views them.
- Firstmate does not place individual workers on an hc machine with `--on`.
  [Remote second-mate support](remote-secondmates.md) uses a separate remote home and does not place individual workers remotely.
- Supervision uses a home-filtered `hc events` stream for reported blocked and working states.
  Its subscription snapshot catches blocked states after reconnect, and polling remains the fallback when the event command, reader, or stream is unavailable.
  A terminal that does not report native status remains on the polling path.

## Tests

`tests/fm-backend-hc.test.sh` pins the adapter against a fake `hc`.
`tests/fm-remote-secondmate-lifecycle-e2e.test.sh` exercises an hc primary with fake remote `herdr`, `rex`, and `hc` backends and a stub SSH transport.
`tests/fm-backend-hc-liveness-live-e2e.test.sh` is the default-on live guard: it launches every installed harness bare in a private core and requires `alive`.
`tests/fm-backend-hc-smoke.test.sh` drives the real binary and event stream in an isolated lab; [`bin/fm-hc-lab.sh`](../bin/fm-hc-lab.sh) owns the isolation and fleet-state tripwire contract, and [`tests/hc-test-safety.sh`](../tests/hc-test-safety.sh) owns guarded test teardown.
`tests/fm-backend-hc-appdetect-smoke.test.sh` runs a real `bin/fm-spawn.sh` spawn in the same kind of lab for the app-terminal and explicit cases, and checks that a live app window never selects hc for a marker-less process and starts nothing for a session with no running core.
The smokes skip when no resolved Core binary or `jq` is available; provisioning and teardown failures fail the test.
For CI coverage, see [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend); the workflow requires `jq` and rejects the `hc not found` skip.
[`bin/fm-hc-ci-cleanup.sh`](../bin/fm-hc-ci-cleanup.sh) owns job-end cleanup mechanics.
