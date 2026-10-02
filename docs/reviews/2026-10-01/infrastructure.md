# Shared infrastructure review

Reviewed main `79b7e89` as checked out, including the pre-existing working changes. The SDK working tree itself was clean at `4ccc4c4`, while the main gitlink records `a6ce19f`. These results describe this workspace, not a clean checkout of the recorded main commit. No implementation was changed.

## Confirmed findings

### INF01 Reject drive geometry outside the physical volume

**P2, reproduced.** [lib/romfs.zig:81](/home/exedev/snouty-badge/lib/romfs.zig:81) validates logical FAT geometry but never bounds the root/data/FAT offsets or total sectors against the physical 1280 KiB volume. It caps the cluster count rather than rejecting an inconsistent FAT capacity. `find()` then dereferences the root pointer, while `map()` constructs pointers from those unchecked offsets.

A 512-byte boot sector with normal signature, sector size, root count and FAT marker, but reserved sectors=3000, FAT count=2, FAT sectors=8, total sectors=4000 is accepted. Mapping a one-sector file at cluster 2 returns an offset of **1,545,216 bytes**, beyond the physical **1,310,720-byte** volume. The probe only compared addresses; it did not dereference out-of-bounds memory. Corrupt/reformatted drive metadata can therefore make emulator startup read unrelated flash or invalid addresses rather than report BadGeometry.

Proposed fix: validate every derived range against an explicit backing extent; on badge builds require the physical volume bound. Preserve the intended support for truncated fixtures through an explicit test interface, not unchecked production pointers. Reject internally inconsistent FAT geometry. Acceptance: invalid root/FAT/data bounds return BadGeometry before any directory/data access; valid fragmented fixtures continue passing. Probe and result are documented in [validation.md](validation.md).

### INF02 Require badge identity before a destructive deployment

**P1, reproduced with mocks.** [device.py:69](/home/exedev/snouty-badge/badge-manager/badge_manager/device.py:69) selects `_by_label() or _by_usb_id()`. `_by_label()` at line 81 accepts any device behind `/dev/disk/by-label/SYCLBADGE`, bypassing the USB VID/PID path entirely. [station.py:333](/home/exedev/snouty-badge/badge-manager/badge_manager/station.py:333) subsequently wipes that device during deploy.

The mock probe returned `/dev/not-a-badge` from `_by_label`; `find_badge()` selected it without invoking `_by_usb_id`. A different FAT volume carrying this label can therefore be selected and erased. The risk requires that label collision; this is not a claim that ordinary differently named drives are at risk. No actual block device was opened by the probe.

Proposed fix: verify label, USB identity and expected geometry together for real devices; keep fake image/directory modes explicit. Fail clearly on ambiguity or identity mismatch. Acceptance: a same-label non-badge device cannot be selected for wipe/deploy; supported real badges and explicit fake modes remain usable.

### INF03 Reject foreign browser origins on mutation routes

**P1, reproduced at the HTTP boundary.** [server.py:1070](/home/exedev/snouty-badge/badge-manager/badge_manager/server.py:1070) dispatches mutations without checking Origin, and [server.py:1168](/home/exedev/snouty-badge/badge-manager/badge_manager/server.py:1168) parses JSON regardless of Content-Type. The foreign-host helper is only used for routing unmatched GETs, not authorization of mutation routes. Empty bodies are also accepted as `{}`.

A local test server backed by a fake station accepted `POST /api/wipe`, `Content-Type: text/plain`, `Origin: http://unrelated.example`, body `{}` with HTTP 200 and invoked the fake wipe action. This demonstrates missing server enforcement. Browser delivery depends on browser/network policy and was not tested; do not read this as a universal browser exploit demonstration. The intended no-passphrase station network is documented, but that choice does not require accepting requests initiated by unrelated web origins.

Proposed fix: define the station's browser trust boundary, validate Origin for browser mutations and reject simple cross-origin form/text requests. Keep legitimate CLI use explicit; use a request token if needed for supported captive-browser constraints. Acceptance: valid same-origin UI and intended CLI requests work; a foreign-origin mutation receives a rejection before dispatch. This review did not request a new login system.

### INF04 Align UF2 acceptance with the loader

**P2, reproduced.** [library.py:119](/home/exedev/snouty-badge/badge-manager/badge_manager/library.py:119) checks magic and address windows but ignores payload validity, family and block-count fields. [tools/uf2_info.py:27](/home/exedev/snouty-badge/tools/uf2_info.py:27), also used by the build gate, has similar incomplete validation. A 512-byte UF2 block declaring 477 payload bytes at `0x20035100` is accepted as a RAM cart. The actual [SDK UF2 parser:140](/home/exedev/snouty-badge/sycl-badge/src/os/loader/uf2.zig:140) rejects payloads larger than 476 bytes.

The station can report such a cart as deployable, wipe the old set, and copy a file the badge refuses. The probe created only a temporary file. Proposed fix: one shared Python validator whose structural/family/count/range checks match the supported SDK loader; use it for library import and build gating. Acceptance: malformed payload, missing blocks, invalid family, mixed/out-of-range blocks and valid RAM/XIP images have explicit cases. Treat this as loader compatibility validation, not a guarantee that arbitrary valid machine code is safe.

### INF05 Check the actual XIP artifact for soft float

**P2, reproduced.** [Reflections build.zig:43](/home/exedev/snouty-badge/carts/snouty-reflections/build.zig:43), [Maze build.zig:41](/home/exedev/snouty-badge/carts/snouty-maze/build.zig:41), and [Demosnout build.zig:33](/home/exedev/snouty-badge/carts/demosnout/build.zig:33) unconditionally check `<name>.elf` even when the selected mode produces `<name>-xip.elf`.

`zig build check-float -Dcart=snouty-reflections -Dcart-mode=xip -j2 --prefix /tmp/sycl-review-xip-check` built the XIP ELF/UF2, then failed trying to open absent `snouty-reflections.elf`. With an older RAM ELF left in the usual output directory, the check can instead pass against that unrelated artifact and never inspect XIP. Proposed fix: derive the checked artifacts from the selected mode; `both` should check both. Acceptance: RAM/XIP/both work from empty output directories and report every requested ELF.

## Architecture assessment

The one root build, pinned toolchain, pure host-testable emulator cores, allocation-conscious frame loops, deterministic replay exports and reusable FAT reader are useful boundaries. The main RAM build compiled all configured artifacts, and the current default float checks passed. These are foundations to retain.

The current build interface duplicates cart metadata and platform details across root registration, per-cart builders, tool aliases, manager manifests and prose. Wasm control/framebuffer adapters, emulator input/menu/ROM-selection flows, and replay/page-store code have been copied between carts. Copying platform adapters makes contract fixes easy to miss; copying emulator internals can also be intentional because state layouts and performance constraints differ. A sensible follow-up is a narrow shared platform adapter and explicit cart metadata after behavior tests are in place, not an immediate universal cart framework.

Two independent Python UF2 validators already demonstrate contract drift. ROM readers should similarly have a clearly bounded input interface rather than infer the backing extent from untrusted metadata. Keep hardware-specific boundaries narrow and separately testable.

The SDK OS cycle-counter fix is present only in the local submodule checkout relative to main's gitlink. Its change is to OS startup, so merely compiling carts against that checkout does not update an attendee's installed OS. Record the actual supported firmware and cart commits with release artifacts. No claim of firmware incompatibility was inferred solely from the dirty gitlink; existing calibration notes already discuss the patch.

No tracked `.github` workflow was found in main. That does not prove the team has no external automation. Agree on a single documented release-validation entry point, explicit optional-ROM coverage and branch integration checks before considering new CI infrastructure.

## Boundaries of this review

The parent reviewed shared Zig build/XIP wiring, ROMFS and its tests, simulator tools, the relevant SDK loader contracts, and selected badge-manager build/library/server/device/deployment paths. The manager's existing tests were run, but this was not a line-by-line security audit of every manager, networking, packaging, art-pipeline or benchmark module. No physical badge/Pi was attached, no real deploy/wipe ran, no real AI build job was launched, and no firmware or networking configuration was changed.
