# Snouty Beam

Pass carts from badge to badge over the link cable. Pick a cart on your
badge, press A, and the other badge asks its owner whether to take it.
Once accepted, the cart is saved on the other badge: as a new `.uf2` on
its drive (firmware with cart files), or else in its external flash's
received-cart slot. Either way its menu lists it and it runs like any
other.

![home screen](docs/preview.gif)

## What you need

- Two SYCL Badge V2s with working UART headers (J4, the 3-pin JST-SH next
  to the Qwiic port) and a **JST-SH 3-pin to 3-pin cable** between them.
  Crossed or straight both work; the link works out which (docs/LINK.md).
- `snouty-beam.uf2` on both badges.
- **To send**: any firmware. The sending badge reads the cart's UF2 from
  its drive (or from SYCLEXTRA, the fork firmware's second drive).
- **To receive**: the receive build of this cart,
  `zig build -Dcart=snouty-beam -Dbeam_receive=true`, on fork firmware
  (adrian-computering/sycl-badge) with either feature:
  - **cart files** (`feature/cart-files`, fork/CART_FILES.md): the cart
    arrives as an ordinary `.uf2` on SYCLBADGE (or SYCLEXTRA when
    SYCLBADGE is full). Any cart the sender's menu can run goes, XIP
    carts and carts over 252 KB included.
  - **cart transfer** (`feature/cart-transfer`, fork/CART_TRANSFER.md):
    the cart lands in the external flash's one received-cart slot (RAM
    carts up to 252 KB).

  With both, files are used, and the slot only when neither drive has
  room. On main the cart is built send-only, because receiving needs an
  OS change; its footer then reads "RECEIVING NEEDS THE FORK FIRMWARE
  BUILD". A receive build on stock firmware says "CAN'T RECEIVE: NEEDS
  THE FORK FIRMWARE".

## Using it

Start Snouty Beam on both badges and plug in the cable. The top line goes
from PLUG IN THE CABLE to CONNECTED (or WRONG CART: <name> when the other
badge runs another cart).

**Home.** The list holds every `.uf2` on the drives, the size that would
be sent (the file, or the slot image for a partner that takes slots
only), and the received cart (marked `*`) if this badge's slot holds one.
Up/Down picks a row; the line under the list says what A will do, or why
a cart can't be sent to this partner:

| Reason | Meaning |
|---|---|
| XIP CART: CAN'T BEAM | an execute-in-place UF2 (`*-xip.uf2`), and the partner takes slots only (RAM carts) |
| TOO BIG FOR A SLOT | its RAM image is over 252 KB, and the partner takes slots only |
| NOT A RAM CART, NO CART DESCRIPTOR, NOT A VALID UF2 | the OS loader would refuse it too |
| PARTNER CAN'T RECEIVE | the partner runs the send-only build or stock firmware |
| PARTNER TAKES FILES | the received slot row, to a partner without a slot |

The footer says whether this badge can receive (files, the slot or
both) and what its slot holds. While a computer has this badge's drive
mounted it reads UNPLUG FROM THE COMPUTER TO RECEIVE instead: files are
refused then (a mounted computer would write its stale copy of the drive
back over the new file). A phone charger or power bank doesn't count.

**Send.** A on a cart: PREPARING (the image checksum), then WAITING FOR
THE PARTNER TO ACCEPT, then the bar and KB/s, then SENT or why not.
Hold B to cancel.

**Receive.** The other badge shows INCOMING CART: the name, its size,
and where it goes (`TO SYCLBADGE?`), or for a slot transfer what it
replaces. A accepts, B declines; no answer in 30 s declines. A file
whose name is taken is saved as `name-2.uf2`, `name-3.uf2` and so on;
nothing on the drive is replaced. A slot transfer erases the old
received cart at once (there is one slot). The bar runs, then RECEIVED
(with the drive and the final file name): open the menu (Start+Select)
and the cart is listed; run it like any other.

**Clear the slot.** Select on the received row, then A.

**Pass it on.** The received row can be sent too: badge to badge to badge.

## Speed

Stop-and-wait over 4 KB blocks at 1 Mbaud, with the receiver's flash
write (~55 ms per 4 KB) between blocks: about 29 KB/s. A file is the
whole UF2, about twice the bytes of the slot image: Snouty Pong (48 KB
UF2) takes about 1.7 s and Snouty Boy (251 KB UF2) about 9 s as a file,
1 s and 4.5 s as slot images (host model, PLAN.md status).

## If it goes wrong

- The cable comes out or a badge restarts mid-way: both screens say CABLE
  OUT OR PARTNER LEFT. A file transfer leaves the drive as it was (the
  file only appears at the end); a slot transfer leaves the slot empty
  (its header is erased first and written last), never a half cart.
- PARTNER: UNPLUG FROM THE COMPUTER: the receiving badge is plugged into
  a computer that has its drive mounted. Unplug it and send again. If
  the computer is plugged in mid-transfer, the transfer stops and nothing
  is saved.
- NO ROOM ON THE PARTNER'S DRIVES: neither drive has room for the file
  and it can't go to the slot (an XIP cart, too big, or no slot).
- Power lost mid-way: same, the firmware boots normally with no received
  cart.
- PARTNER CAN'T RECEIVE (FIRMWARE): the other badge runs stock firmware or
  the send-only build.
- PARTNER IS BUSY: both of you pressed A at once; try again.

## For developers

PLAN.md (protocol, screens, tests, status), `cart/src/proto.zig` (the
transfer state machines, protocol v2), `lib/beam_slot.zig` (the slot
format and UF2 flattener), `lib/ext_flash.zig` (the fork's external flash
mailbox), `lib/cart_files.zig` (the fork's cart files mailbox).
`zig build test-beam` runs the transfer tests; `zig build beam-slot --
in.uf2 out.bin` writes the slot bytes a cart would become.
