# Badge manager review for agreement

## Implementation follow-up — 2026-10-02

The F01–F21 fixes are implemented in the `manager/m2` working tree. Library edits now use shared transactions; sync and deployment validate staged artifacts before replacement; real devices require USB identity and the expected FAT volume. Production startup fails explicitly, browser mutations enforce origin checks, builds run under an unprivileged account, and the installed SSH CLI uses the service API. Process cleanup, remote result recovery, format validation, action results, selection recovery, focus preservation, set replacement, and installation/update guidance have been corrected.

Regression coverage is in `tests/test_library.py`, `tests/test_sync_safety.py`, `tests/test_deployment_safety.py`, `tests/test_operations.py`, the existing build/CLI/server suites, and `tests/browser_regression.js`. All 181 Python tests passed with `python3 -m unittest discover -s tests -q`. Chromium checks, `BADGE_STATION_IMAGE=builtin bash tests/e2e_loop.sh`, shell syntax checks, and `git diff --check` also passed. Physical Pi installation, NetworkManager changes, actual USB deployment, screen-reader use, and paid builds remain untested. The original findings below describe the reviewed baseline, before these fixes.

Reviewed 2026-10-01 at commit `79b7e896140c646c3c162103a4e9c723a629a3c1` in the `manager/m2` checkout. This is a review of the current badge manager, including its Python package, phone page, installer, network scripts, build runner, tests, README, and plan. Three independent reviewers covered device and library correctness, builds and operations, and documentation and UX; the coordinating review checked integration and reproduced additional server failures.

The implementation has a useful structure and substantial happy-path coverage. The main concern is preserving trustworthy state when more than one client acts, inputs change, or an operation fails. Several reproduced failures can lose library configuration or usable artifacts. Installation and first-use guidance also need work before a newcomer can reliably get from a fresh Pi to a deployed cart.

This document records findings and proposed directions for agreement. No implementation, configuration, or existing documentation has been changed. Priorities are recommendations: **P1** means address before unattended or shared station use; **P2** means address for reliable everyday use and newcomer readiness. Design decisions are listed separately from confirmed defects.

## Findings at a glance

| ID | Priority | Finding |
| --- | --- | --- |
| F01 | P1 | Stale manifest writes erase other clients' changes |
| F02 | P1 | Deploy can wipe the badge before discovering missing inputs |
| F03 | P1 | Sync replaces valid carts before validation and can report success on failure |
| F04 | P1 | Explicit ROM destination names can write outside the badge |
| F05 | P1 | Editing a broken manifest replaces its original contents |
| F06 | P1 | Accepted text can corrupt the manifest during serialization |
| F07 | P1 | The restricted CLI sudo rule permits arbitrary root commands |
| F08 | P1 | Startup errors silently select defaults or a simulated station |
| F09 | P1 | A configuration parse error can delete saved hotspot profiles |
| F10 | P1 | Timeout and cancellation do not reliably terminate descendants |
| F11 | P2 | Mutating HTTP routes do not check request origin |
| F12 | P2 | Local build installation and runtime use different environments |
| F13 | P2 | Failed remote retrieval deletes recoverable build output |
| F14 | P2 | UF2 validation accepts impossible payload sizes |
| F15 | P2 | Truncated FAT data escapes the device error handling |
| F16 | P2 | A transient fit request failure leaves selection deployment disabled |
| F17 | P2 | Page updates discard keyboard focus and log containers |
| F18 | P2 | Accepted operations have no durable user-facing result |
| F19 | P2 | Saving a new set can silently replace an existing one |
| F20 | P2 | Multiword SSH examples lose their argument quoting |
| F21 | P2 | The documented update procedure can reinstall the same old code |

Source references below are relative to this directory and refer to the reviewed commit. Reproductions used temporary fixtures, fake devices, local servers, or command stubs. Findings marked as source tracing were not exercised on a Pi or through an actual privileged installation.

## State and data preservation

### F01 Stale manifest writes erase changes from other clients

**P1 · reproduced.** `badge_manager/library.py:606–626` rewrites the complete manifest from the object's cached `_raw` snapshot. `Station.poll()` at `badge_manager/station.py:165–172` does not refresh the library after another CLI process changes it.

Create two `Library` instances for the same manifest. Save a set through the first, then change a cart mode through the second: the newly saved set disappears from disk. These operations can be sequential. The server, SSH CLI, nightly sync, and build registration therefore cannot safely share the manifest under the current ownership model.

Concurrent writes have a second problem: they share `manifest.toml.tmp`. Uploads use `App._action_lock`, while build registration uses `Station._state`; these different locks do not serialize their writes. That concurrent collision is established by source tracing, rather than a timed reproduction.

**Proposed direction and acceptance:** give every library mutation one transaction boundary covering a fresh read, validation, merge, and atomic replacement using a unique temporary file. Refresh readers after external commits. Verify sequential stale-client edits and overlapping upload/build/CLI edits preserve all accepted changes. Locking only `_write()` would still lose changes prepared from stale snapshots.

### F02 Deploy can erase the badge before discovering missing inputs

**P1 · reproduced.** `badge_manager/library.py:351–378` plans from cached sizes and validation results; `badge_manager/station.py:320–336` wipes before reopening source files.

Initialize a station, remove a selected UF2 from its library, then deploy that set. The preflight passes, existing badge files are erased, and copying fails because the source is already missing. Replacing an input after it was validated can similarly invalidate the fit and format checks.

**Proposed direction and acceptance:** validate and pin or stage the exact deployment inputs before the first destructive write. Compute fit from that snapshot and copy those same bytes. Missing, changed, or invalid inputs must leave existing badge contents untouched. This does not promise atomic rollback for a physical disconnect during copying; that separate failure needs an explicit recovery state.

### F03 Sync replaces valid carts before validation

**P1 · reproduced.** `sync.sh:43–54` rsyncs directly into the live library. Validation at `67–73` happens afterward, and the registration loop at `96–114` does not consistently turn invalid input or registration failure into a failing script exit.

Syncing a seven-byte `INVALID` file over a registered, valid 2,048-byte UF2 destroyed the original artifact, printed a validation failure, and returned exit code **0**. The nightly service and page can consequently report a successful sync while a working cart has become unusable.

The README at `193–197` also says the library follows main and a failed sync changes nothing. The script copies whatever artifacts currently exist in the configured build directory; it does not fetch or build main, and its failure behavior does not preserve the previous library.

**Proposed direction and acceptance:** download into staging, validate the complete intended update, and promote valid artifacts through the library transaction boundary. Preserve the previous usable version on failure and return a nonzero result. Record artifact provenance if “follows main” is a product requirement; otherwise document the actual source precisely.

### F04 Explicit ROM destination names can escape the badge

**P1 · reproduced.** The `short` field is accepted at `badge_manager/library.py:293–300,469–470` and passed into the deployment plan at `374–378`. Mounted-device copying at `badge_manager/device.py:271–272` and directory copying at `363–364` append it to the mount path without confinement checks.

Giving a ROM an absolute temporary destination overwrote an unrelated file outside a fake badge; verification failed only afterward. A `../` destination can also escape. The mounted-device path uses the same join, ordinarily as root. This input is available through the manifest and CLI `add-rom --short`; the normal phone upload does not expose `short` directly.

**Proposed direction and acceptance:** validate single FAT filenames when loading/importing metadata and again at the device boundary. Reject absolute paths, traversal, separators, invalid names, and conflicting destinations before wiping. Tests should prove that both mounted and fake adapters keep every write inside the intended volume.

### F05 Editing an invalid manifest discards its original configuration

**P1 · reproduced.** At `badge_manager/library.py:200–205`, a parse failure sets `_raw` to an empty dictionary. Ordinary mutators at `606–626` still write that dictionary back.

Append an unfinished array to an otherwise complete manifest, load it, then save a set. Although the library reports the parse error, saving replaces the original document with the new set and loses the old configuration. A repairable typo becomes data loss.

**Proposed direction and acceptance:** refuse all mutations when the current manifest cannot be read and validated. Preserve its bytes and show a repair instruction. Apply the rule to every entry point, including uploads, build registration, mode changes, set changes, and initialization.

### F06 Accepted text can corrupt the manifest

**P1 · reproduced.** `_toml_value()` at `badge_manager/library.py:153–161` escapes line feeds but not carriage returns or other forbidden controls. `_write()` at `620–626` replaces the manifest before checking whether the output is valid TOML.

Saving a set with an internal carriage return in its title writes an invalid manifest, then raises `KeyError`. Reload reports an illegal character and exposes no saved sets. The HTTP title validation also permits this input. This is a separate path into the F05 failure state.

**Proposed direction and acceptance:** fully encode TOML strings or reject unsupported characters at input boundaries, then parse the candidate document before replacement. Round-trip all accepted title/key characters; rejected input must preserve the original manifest exactly.

## Privilege startup and job lifecycle

### F07 The restricted CLI grants arbitrary root execution

**P1 · source tracing.** `setup.sh:130–144` permits the badge user to invoke the Python CLI as root with arbitrary arguments. `badge_manager/cli.py:29–34,125–129` accepts a caller-selected configuration file. Its `sync_command` reaches `subprocess.Popen(..., shell=True)` at `badge_manager/station.py:406–422`.

A badge SSH user can therefore supply a configuration that executes an arbitrary command as root. Pinning the working directory does not constrain configuration contents. No privilege escalation was attempted during this review. README wording about permitting “only that command” does not describe the effective authority.

**Proposed direction and acceptance:** first decide whether badge SSH users are intentionally full administrators. If they are meant to be restricted operators, the privileged entry point must reject caller-controlled configuration, executable commands, and device/library path overrides. Prefer a narrow device helper and an unprivileged application/build process. Test the installed privilege boundary, not just the CLI parser.

### F08 Startup failures look like working stations

**P1 · helper reproduction and source tracing.** `badge_manager/server.py:1476–1487` catches configuration errors and returns defaults. `1490–1501,1522–1526` catches station initialization failures and constructs `DemoStation`.

A malformed explicitly requested config returned the default live-library path, bind address `0.0.0.0`, and port 80. A simulated initialization failure returned the sentinel that selects the demo. The page has no persistent demo indicator, so simulated successful builds and deployments can be mistaken for real operations. Warnings in the service log do not resolve that ambiguity for a phone user.

**Proposed direction and acceptance:** require explicit opt-in for demo behavior and give it a persistent banner. Invalid production configuration should fail startup or show an unmistakable unavailable state without enabling mutations. Verify bad paths, malformed TOML, unreadable library storage, and initialization exceptions.

### F09 A config typo can remove hotspot profiles

**P1 · reproduced with a stub NetworkManager command.** `net/nm-profiles.sh:53–54` reads the parser through process substitution without capturing its failure. The pruning loop at `103–113` interprets an empty result as a valid configuration containing zero hotspots.

With malformed TOML, the script printed a parser exception, invoked deletion of a saved `snouty-hotspot-1` profile, and exited **0**. Running the documented reconfiguration command after a typo can remove connection settings and complicate remote recovery.

**Proposed direction and acceptance:** parse and validate the complete configuration before any network mutation; stop on parser failure. A malformed config must produce a nonzero exit and zero mutating `nmcli` calls. Profile pruning should happen only after successful validation and application of the intended configuration.

### F10 Timeout and cancellation can leave jobs running

**P1 · reproduced.** Build termination at `badge_manager/build.py:374–386,530–534,551–565` sends SIGTERM to the process group but conditions the delayed SIGKILL on the shell leader remaining alive. A descendant can outlive that leader and keep stdout open. Separately, sync at `badge_manager/station.py:419–434` kills only its shell.

A build child ignoring SIGTERM remained alive after a 0.6-second timeout and the three-second grace period; after 4.8 seconds the runner and job still reported running while the shell had exited with `-15`. The held build lock blocks later builds. A sync child also continued past a patched 0.1-second timeout and kept the caller waiting until it exited. Review processes were explicitly cleaned up afterward.

**Proposed direction and acceptance:** supervise the whole process group independently of leader liveness, bound output draining, and reap descendants on timeout, cancellation, and exceptional exit. Test a terminated leader with a stubborn child holding stdout. The operation must reach a terminal state and release its lock within a bounded grace period.

### F11 HTTP mutations have no origin boundary

**P2 · local HTTP and Chromium reproductions.** `badge_manager/server.py:1073–1087` dispatches known routes without validating Host or Origin; `_read_json()` at `1168–1180` accepts JSON regardless of content type. Captive-portal redirect handling applies to unmatched requests and does not protect known API routes.

A `POST /api/cart-mode` with an unrelated Origin and Host and `Content-Type: text/plain` returned **200** and changed the cart mode. In Chromium, a page at `127.0.0.1:8188` also changed the demo at `127.0.0.1:8187` from RAM to XIP with a `no-cors`, text/plain fetch. The response was opaque, but the mutation succeeded. This proves cross-origin loopback-to-loopback behavior; public-origin access to private networks and its browser restrictions were not tested.

The agreed no-passphrase policy for ROM uploads does not require accepting commands initiated by unrelated web pages. More broadly, every station-network client can currently deploy, wipe, edit sets, or start a paid build; the plan explicitly records the open-upload decision but not all those permissions.

**Proposed direction and acceptance:** define the trusted-client model, validate browser request origins for mutations, and separate captive-portal GET handling from API policy. Preserve intentional CLI/API access. Test cross-origin browser requests, same-origin page actions, uploads, and the intended non-browser clients.

### F12 Installed local build tools are not the tools the service finds

**P2 · source tracing.** `setup.sh:183–199` installs Zig under `/home/badge/.local`; `systemd/badge-station.service:9` runs as root. Readiness at `badge_manager/station.py:560–570` looks under `Path.home()/.local`, and `build-job.sh:36` uses `$HOME/.local/bin`. The bench venv installation under `/opt/badge-station` also differs from the lookup beneath `build_repo` at `build-job.sh:275–278`.

Following `setup.sh --build-tools` does not by itself make local builds ready in the installed service environment. A sufficiently capable Pi can fall back to the remote host or reject local builds. Checkout location, agent installation/authentication, and bench dependencies also need an explicit first-use contract.

**Proposed direction and acceptance:** choose an explicit unprivileged builder identity and shared toolchain paths. Run readiness checks in that actual environment and identify the missing prerequisite precisely. Validate a clean installation through a no-agent local build, then separately validate agent authentication.

### F13 A failed result transfer deletes remote output

**P2 · source tracing.** `_remote_after()` at `badge_manager/build.py:347–357` runs remote cleanup even when result retrieval fails. Only a timeout triggers remote cancellation there; an SSH failure does not first reconcile whether the remote job remains active.

A transient transfer failure can discard the only completed UF2, previews, and detailed remote logs after the build has consumed time and money. The source branch survives, but retrieving the completed package cannot simply be retried. Remote process survival after a real disconnected SSH session was not tested.

**Proposed direction and acceptance:** retain output until successful local receipt and validation; reconcile remote job state before cleanup. Add bounded retention and retry/recovery. A simulated failed fetch must leave the remote result available, and a lost connection must have a defined cancellation or resumption outcome.

## Format validation

### F14 UF2 validation accepts impossible payload sizes

**P2 · reproduced.** `badge_manager/library.py:119–128` checks block magic and address regions without adequately bounding the declared payload size.

Changing a valid 512-byte block's payload length to 9,000 still made `validate_uf2()` return `ram`. The claim here is acceptance of structurally invalid input, not a demonstrated firmware exploit or a measured badge response.

**Proposed direction and acceptance:** define one validator contract aligned with the badge loader and shared tooling. Reject impossible lengths and other loader-required structural violations using malformed fixtures. Normal library discovery and direct imports must apply the same gate as build/sync paths.

### F15 Truncated FAT input produces internal exceptions

**P2 · reproduced.** `badge_manager/fat12.py:235–244` indexes the FAT without checking that the declared bytes were read. Device wrappers at `badge_manager/device.py:246–252,382–390` do not normalize the resulting `IndexError`.

A valid boot sector declaring the usual geometry but lacking the FAT raised an uncaught `IndexError`. Corrupt or truncated media can consequently produce internal failures instead of an actionable invalid-volume status.

**Proposed direction and acceptance:** validate geometry, available FAT capacity, and read lengths before indexing. Convert invalid-media failures into the device error contract. Apply equivalent checks to both reader and writer and test truncated tables, impossible geometry, and invalid cluster references.

## User experience and documentation

### F16 A transient fit failure does not recover

**P2 · executable JavaScript and Chromium reproductions.** `www/index.html:514–519` assigns `fitKey` even when `/api/fit` fails. At `523–553`, later renders consider that error a current result and do not retry.

After selecting a cart, fail one fit request and restore the connection. Status polling can recover while Deploy selection stays disabled with “Request failed (no connection).” An isolated execution of the actual functions produced no retry across five subsequent renders. Chromium confirmed that healthy status updates left the error and disabled button unchanged, with only one fit request issued. Changing the selection or reloading is the hidden workaround.

**Proposed direction and acceptance:** cache successful results, retry transient failures with bounded backoff, and offer a visible Retry action. A restored connection should recover the unchanged selection without reloading.

### F17 Rendering replaces focused controls

**P2 · source tracing and Chromium reproduction.** `www/index.html:343–345,450–452,710–712` clears and recreates the sets, library, and build-history DOM. Every status response invokes those renderers at `817–826`, including unchanged long-poll responses and frequent build-log updates. Opening a set and arming Remove also rebuild the control being used.

In Chromium, expanding a set, arming Remove, and receiving an unrelated healthy status update each moved focus from the intended control to `BODY`. Recreating an open log also discards its scroll container, as established by source tracing. Native buttons, checkbox labels, `aria-expanded`, `aria-pressed`, and generous control heights are good foundations, but they do not preserve interaction state across replacement.

**Proposed direction and acceptance:** retain nodes keyed by stable identities, or update only changed content while preserving focus and scroll. Complete a keyboard-only select, expand, remove, and deploy flow during an active build without focus jumping to the document.

### F18 Accepted actions have no durable result near the controls

**P2 · source tracing.** `badge_manager/server.py:1011–1021` logs failures after the API has already acknowledged the action. `badge_manager/station.py:398–404` returns a sync success boolean that the async worker does not surface. The page's `act()` at `www/index.html:861–865` accepts the initial HTTP success; the working label at `333–335` simply disappears when the operation ends.

A newcomer pressing Sync with an invalid SSH key must discover the failure in the bottom log. The same distinction between “accepted” and “completed” matters for failed deployment or eject. There is no durable, structured last-action result to render beside the original control.

**Proposed direction and acceptance:** expose an operation identity, progress, and terminal result. Show success or failure with the next recovery step beside the badge/action controls; retain logs for detail. Test a worker failure after HTTP acceptance and reconnection after completion.

### F19 Saving a new set can replace another set silently

**P2 · source tracing.** `www/index.html:912–921` asks for a new set name and reports “Saved.” `badge_manager/library.py:149–150,555–560` derives a slug and overwrites the table already at that key.

“My Game” and “My-Game” collide even though their displayed titles differ. A user can lose an existing set without choosing Replace. README's same-name replacement note neither appears at the decision point nor explains all slug collisions; default keys also need not equal their title slugs.

**Proposed direction and acceptance:** distinguish Create from Replace. On collision, show the existing set and require a deliberate replacement choice or another name. Test exact-name collisions, normalized-name collisions, and defaults with different keys and titles.

### F20 Copy pasted SSH examples split multiword arguments

**P2 · reproduced through the actual argument parser.** README examples at `119,124–125` quote prompts/titles only for the local shell. OpenSSH joins command arguments for the remote shell, so the intended grouping is lost.

The reconstructed remote invocations for a multiword build prompt and `--title Game Gear` both exited **2** with unrecognized arguments. Quote the complete remote command and quote its values inside that command, for example:

```sh
ssh -t badge@snouty.local 'badge build "a Snouty cart where it rains frogs"'
```

**Proposed direction and acceptance:** exercise all copy-paste SSH examples, including globs and titles with spaces, through a remote-shell parsing test. Keep interactive TTY and explicit automation examples separate, according to the destructive-action decision below.

### F21 Rerunning setup does not necessarily update the code

**P2 · source tracing.** README at `19` describes rerunning setup as the update procedure. For the advertised clone-based installation, `setup.sh:49–53,68–69` copies the adjacent checkout without fetching it. Fetching at `55–64` belongs to the other installation path.

A user following only “rerun setup” can reinstall the old revision and believe they have updated. Reinstallation being repeatable is different from selecting a new source revision.

**Proposed direction and acceptance:** document an explicit fetch/revision-selection step or provide an update operation that does it. Show the installed revision, prerequisites, and rollback procedure. Validate the instructions from an intentionally older clone.

## Architecture and product decisions to agree

1. **One owner for shared state.** Choose either a station service that all clients call, or a shared transaction layer that all processes must use. The current mixture of HTTP action locks, station state locks, device flocks, and cached library objects does not define one consistent boundary. Keeping Python's standard library and the current module separation is reasonable; a framework rewrite is not required to solve this.

2. **Separate device privilege from build execution.** Decide who may administer the station, who may deploy, and who may spend build budget. The root web service also launches local builds; generated build code and agent tool permissions are not an operating-system sandbox. An explicit builder user would address both privilege scope and F12's environment mismatch. The plan's proposed separate-user guardrail is not the installed behavior.

3. **Make destructive intent consistent.** Saved-set Deploy at `www/index.html:397` acts immediately, while selection deploy at `896–906` requires a second tap saying it will wipe. CLI `_confirm()` at `badge_manager/cli.py:140–143` automatically approves any non-TTY stdin, even without `--yes`; the README's deploy-over-SSH examples do not allocate a TTY. These are confirmed behaviors whose desired policy needs agreement. Recommended default: show “replaces everything” before every deploy, use deliberate confirmation for an unfamiliar selection, and require explicit `--yes` for noninteractive destructive commands. A clearly labeled repeat-deploy flow could preserve expo speed.

4. **Define deployment success and recovery.** `_verify()` at `badge_manager/station.py:354–368` checks expected names and warns on fragmentation; it does not verify file content integrity or chain length. Agree whether success requires sizes, hashes, and contiguity. Also define the visible outcome after a cable disconnect, failed copy, or failed eject. There is no evidence here that wipe-and-copy can be made physically atomic.

5. **Choose the target-device policy.** `badge_manager/device.py:69` accepts a `SYCLBADGE` volume label before USB identity, intentionally supporting test sticks. Decide how production mode distinguishes intended targets and multiple devices. Label-only selection and cross-process mount polling deserve hardware validation; this review did not reproduce a wrong-device wipe or an actual mount race.

6. **Specify build ownership through disconnection and restart.** Local process groups, SSH sessions, remote PID files, timers, job JSON, and cleanup each own part of the lifecycle. Document who cancels whom, which results survive, and what restart recovery does. F10 and F13 should be resolved under that model rather than patched independently.

7. **Keep the demo representative without duplicating the product.** Much of `server.py` implements a separate simulated station/library/build system. It makes a useful demonstration, but its success does not prove real library persistence, privilege, or device behavior. Consider using the real domain logic with fake device/build adapters for more tests, and share API contract tests between real and demo implementations. Split transport and demo code when this improves navigability; a file split alone would not fix the state problems.

## New user journey improvements

These are proposed documentation and UX improvements, in addition to the confirmed findings above.

| Journey | Current obstacle | Proposed improvement |
| --- | --- | --- |
| Fresh install to first deploy | Setup seeds manifest entries, not cart binaries. Host selection, SSH key registration, initial sync, phone access, and deployment are explained in separate places. | One ordered quickstart with prerequisites and an expected result at each step: configure host, register key, sync, connect phone, put badge on menu, deploy, unplug. |
| Personalizing a new station | Example config contains project-specific host, path, and hotspot values. | Mark every value a new installation must replace; distinguish required settings from working defaults. |
| Diagnosing the first failure | Missing carts, failed SSH authentication, no internet, and mount errors require interpreting logs. | A short troubleshooting table linked from the affected page states, with a concrete diagnostic and recovery step. |
| Choosing carts | RAM/XIP and ROM compatibility are unexplained at the point of use; variant choice changes all saved sets. | Compact contextual help explaining the choice and its global effect. |
| Uploading a ROM | Supported extensions and the 4 MB limit are not stated beside the picker before selection. | Show accepted types, limit, and which emulator cart reads the chosen ROM. |
| Starting a build | The README gives duration and budget information that is absent at submission. | Show the destination, expected duration, configured budget, and cancellation behavior next to Build. |
| Recovering a connection | Polling failure changes the header but retains stale enabled controls. | Show disconnected/stale status and make retry and post-reconnect reconciliation explicit. |
| Using assistive technology | Action/error/fit/build-completion updates have no live status or alert semantics. | Announce meaningful changes through concise live regions, without reading every log line. |
| Understanding project status | PLAN's opening still calls M2 “next,” while later sections record it as implemented. | Separate implemented behavior, historical proposals, accepted policies, and hardware/browser validation still outstanding. |

The existing small page, no-app requirement, set-based deployment, visible capacity checks, previews, and offline library are appropriate for the expo use case. The first-use experience should build on those strengths rather than introduce more configuration screens.

## Validation and limits

- **Existing suite:** all **137 tests passed** using `python3 -m unittest discover -s tests -q` from `badge-manager/`. The first sandboxed run could not create sockets for 26 HTTP tests; the permitted rerun passed. That initial restriction was environmental, not a product failure. The passing run still emitted resource warnings for unclosed file/stream handles, a lower-priority cleanup item.
- **Image integration:** `BADGE_STATION_IMAGE=builtin bash tests/e2e_loop.sh` passed with real UF2 artifacts from the main checkout. Both sets had the expected files, volume label, complete cluster chains, and contiguity. This exercised the built-in FAT12 writer, not Linux vfat mounting or physical USB eject.
- **Additional reproductions:** stale manifest clients; missing deploy source; escaped ROM destination; invalid-manifest mutation; control characters in TOML; invalid sync replacement; malformed network config with stubbed commands; stubborn build and sync descendants; invalid UF2 length; truncated FAT; fit retry behavior; SSH argument grouping; foreign-origin HTTP mutation; and startup fallback helpers.
- **Browser validation:** headless Chromium against an isolated localhost demo confirmed F11, F16, F17, and the single-tap saved-set deployment behavior. Desktop and 320px/390px mobile viewports had no horizontal overflow. A simulated build completed, displayed its preview, and selected its cart. No JavaScript exceptions were recorded. The mobile screenshot was also visually inspected.
- **Accessibility:** automated axe checks recorded 21 passes and one scrollable-log focus warning. Manual Tab traversal reached that log in this Chromium version, so the warning is not listed as a confirmed defect. There were no live regions for dynamic status announcements. This is a partial accessibility review, not a conformance certification.
- **Not exercised:** real Pi installation/update, real NetworkManager changes, actual USB mount/eject, an iPhone or Android captive portal, a screen reader, paid agent builds, or remote SSH interruption on a real station. Unit tests, Chromium viewport emulation, and FAT images cannot establish those behaviors.

Temporary review evidence remains in this VM: [test output](/tmp/badge-manager-review-tests.log), [image integration output](/tmp/badge-manager-review-e2e.log), [browser results](/tmp/badge-review-browser/results.json), [cross-origin results](/tmp/badge-review-browser/cross-origin.json), [browser reproduction script](/tmp/badge-review-browser/review.js), and [390px mobile screenshot](/tmp/badge-review-browser/mobile-390.png). These `/tmp` artifacts are not committed and may be cleaned up by the environment. The findings and reproduction descriptions above are the durable record. Review-owned browser and HTTP-server processes were stopped.

## Proposed agreement and implementation order

The recommended first agreement is to preserve the existing product shape while establishing reliable ownership and failure behavior.

1. **Preserve data and fail clearly:** F01–F06, F08–F09. Establish library transactions and deployment snapshots; stage sync; confine filenames; preserve invalid input for repair; make production startup failures explicit.
2. **Agree privilege and lifecycle rules:** F07, F10–F13 and architecture decisions 2, 5, and 6. Define the operator/admin boundary, builder identity, HTTP trust model, bounded termination, and result retention.
3. **Make outcomes and recovery usable:** F16–F19 and destructive-action decision 3. Preserve focus, recover transient failures, distinguish accepted/completed actions, and make replacement deliberate.
4. **Close format and onboarding gaps:** F14–F15, F20–F21, then the ordered quickstart and contextual help. Run the clean-install and physical-device acceptance checks before describing the station as ready for newcomers.

For discussion, approve or revise the priorities and the seven architecture/product decisions above. Each finding includes an acceptance condition so an agreed change can be reviewed against observable behavior. Agreement on this report does not imply that all larger architectural options must be implemented at once.
