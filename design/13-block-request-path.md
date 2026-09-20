# The block request path

Status: proposed, 2026-09-20. Measured in the emulator; the per-command cost on
the 701's card reader is estimated from the device class and is to be
confirmed on the machine.

What one request to a USB volume carries, and how many requests a file read
or write takes. The path is `ulib.file` and the other readers, the VFS,
`fat.zig`, `bcache.zig`, `ublk.zig`, `usbd`'s `volume.zig` and `umass.zig`,
and the three host controller drivers. [03-storage-fs.md](03-storage-fs.md)
§4.4 specifies the bridge; [07-usb.md](07-usb.md) §5.4 and §5.8 the schedule
and the mass-storage engine.

## 1. What is wrong

Measured on a 4 MiB read from an EHCI stick: 1,024 requests, 3,270 interrupts,
1,024 kernel round trips, all serial.

- The request size is decided by the caller's buffer. `ulib.file.copy` reads
  4 KiB per call, `cat` and `pack` the same; the VFS and FAT hand the run down
  as asked, and nothing below merges. One mass-storage command per 4 KiB.
- A command is three bulk transfers, command, data and status, each an
  interrupt and a wake of usbd: 3.2 interrupts per request measured. The
  kernel waits for each request before issuing the next.
- The ublk slot is 16 KiB where 03 §4.4 specifies 64 KiB, so a whole-file
  read is capped at 16 KiB per command. On UHCI a command carries 1 KiB,
  limited by the control-answer buffer the driver also bounces bulk data
  through, while its chain of 131 descriptors carries 8 KiB. On OHCI 4 KiB.
- Every byte is copied twice: the kernel between the caller and the slot,
  usbd between the slot and a bounce buffer the controller reads. 03 §4.4
  specifies one copy.
- FAT commits its table per entry: appending one cluster stores the cached
  table sector to every copy at once. With 4 KiB clusters a 64 KiB write is
  33 commands, 32 of them table sectors of 512 bytes.
- A command costs the device's firmware on the order of a millisecond on a
  card reader, whatever the bus does. That caps reads near 4 to 6 MB/s and
  writes near 1 MB/s on a bus good for 25 MB/s. Booted from the card, `/home`
  and `/cfg` are on this path: every picture, document, save and every
  program in `/home/bin`.

A defect on the same path. `ehci.zig`'s `describe` fills two of a
descriptor's five page pointers, while `BULK_BYTES` allows 16 KiB and the
token's length field 20 KiB. A transfer that runs past its second page
continues at pointer three, which is zero: the controller moves that part to
physical page 0 and the caller gets whatever the bounce buffer held. Reached
by every read of a run of 16 KiB or more through a buffer that large:
`vfs.readFile`, so program loads from `/home/bin` and Draw's picture load,
the viewer's decode buffer, and `edit`. The gate never issues one: its
copies are 4 KiB, its files small, and the development image's `/home` is
on ATA. Reproduced in the emulator: a 96 KiB file of 8,940 numbered lines
on an EHCI stick, opened in `edit`, reads as 4,474 lines, intact for the
first 8 KiB of each transfer and zeros after.

## 2. The rule

The size of a request is decided where its cost is known, and every layer
above passes a run through whole.

- A host controller carries a whole slot in one command, as one chain of
  descriptors with one interrupt at its end.
- The slot is the unit of the bridge: 64 KiB.
- FAT and the block cache hand runs down unsplit, and FAT commits its
  metadata once per call.
- A program that reads a file in pieces reads it in pieces of that size.

## 3. Changes by layer

### 3.1 Host controllers: one command, one chain

- EHCI. Every page pointer a transfer reaches is filled (the defect). A
  descriptor addresses five pages; a 64 KiB slot is a chain of four
  descriptors of 16 KiB each, page aligned, linked by `next`, the interrupt
  bit on the last. The arena's single `payload` becomes an array of four.
- UHCI. The bulk limit is the chain's capacity, `(CHAIN - STAGES)` packets of
  the endpoint's packet size: 8 KiB at full speed, 1 KiB at low speed. It is
  no longer the control-answer buffer's size.
- OHCI. A descriptor spans two pages, 8 KiB from a page boundary; a 64 KiB
  slot is eight descriptors, the interrupt on the last as now.
- `bulkLimit` reports the chain's capacity and `umass` sizes its commands by
  it, as now.

### 3.2 The bridge: the slot as designed

`SLOT_BYTES` is 64 KiB; the depth stays 4. The attach answer carries the
physical base of the slot area, which the kernel has since the area is DMA
memory, so usbd can point a controller at a slot.

### 3.3 usbd: DMA from the slot

Bulk descriptors point into the slot, at its physical base plus the request's
offset, for both directions. The bounce buffers for bulk data go, and with
them usbd's copy per byte and the limit those buffers put on a command.
Control transfers keep their buffer. A slot is the kernel's until `done`, so
it stays mapped and unchanged for the length of the transfer.

### 3.4 FAT: the table stored once per call

`Table` keeps whether its cached sector is dirty. `set` marks it. The sector
is stored to every copy when the cache moves to another sector, at the end
of every call that changes the table (`writeAt`, `truncate`, `create`,
`remove`, `mkdir`), and on `flush`. A call still returns with everything it
changed on the medium, which is what the double-buffered write strategy of
00 §7 needs. Per 64 KiB written with 4 KiB clusters: one data run and one
table sector per copy, 3 commands. Allocation is unchanged: clusters taken
in order from the free pointer are contiguous, and the data stays one run.

### 3.5 The block cache

A run longer than sixteen sectors goes straight between the caller and the
backing and leaves the lines to the table, the directories and the small
files: read from the backing whole, or written through with no line left
behind saying what the sectors held before. Write-through keeps every line
what the medium holds, so a read served from the medium is never behind a
line. Measured before it was done: a 4 MiB file's chain spans eight table
sectors, every write call walks the chain from its start, and each 64 KiB
run through the lines evicted those sectors, so a 4 MiB write took 2,138
interrupts where its data took 192.

### 3.6 Callers

`ulib.file` reads and copies in `BLOCK`, 64 KiB, from one static buffer per
program. `cat`, `cp` and `pack` use it. Pad reads in 512 byte pieces and
moves to `BLOCK`. The viewer, Draw and the loader read whole files already.

Not done: read-ahead below the callers. 03 §5's page cache is not built, and
a reader that asks for small pieces of a large file is Pad alone.

## 4. Budgets

| Where | Now | After |
|---|---|---|
| ublk shared memory, per attached USB volume | 64 KiB | 256 KiB |
| usbd arena, EHCI | one descriptor | four; +192 B |
| usbd arena, OHCI | one descriptor | eight; +112 B |
| usbd arena, UHCI bulk bounce | 1 KiB | none |
| usbd arena, EHCI and OHCI bulk bounce | 16 KiB, 4 KiB | none |
| a program that copies files | 4 KiB | 64 KiB of BSS |

RAM, not image. Under half a megabyte with two volumes attached.

## 5. Expected effect

Per MiB read through EHCI: commands 256 to 16, interrupts about 820 to about
52, usbd wakes the same, kernel round trips 256 to 16, copies per byte 2 to
1. Per 64 KiB written: 33 commands to 3. UHCI: 1,024 commands per MiB to 128.

On the 701's reader, reads move from the command-bound 4 to 6 MB/s to the
reader's own rate; writes from about 1 MB/s to what the card sustains.
Program loads from `/home/bin` take a quarter of the commands they do now.

## 6. Verification

Host tests, each proven by breaking what it guards:

- `fat/alloc.zig`: a device double that counts writes; appending sixteen
  clusters in one call stores one sector per table copy; a call that changes
  two table sectors stores both; nothing is stored twice.
- `ehci/transfer.zig`: a 64 KiB chain has every page pointer of every
  descriptor set, each `next` links to the following descriptor, and only the
  last carries the interrupt bit; a 6 KiB transfer fills two pointers and no
  more.
- `uhci.zig`: the bulk limit is the chain's capacity at each speed, and a
  transfer of that length is accepted while one past it is refused.
- `ublk.zig`: a 200 KiB read is four slot requests of 64 KiB and one of 8 KiB.

Emulator, in the gate's copy step: a 4 MiB file copied from and to a stick
on EHCI and on UHCI, compared byte for byte, which once `cp` reads in
`BLOCK` moves every byte through 64 KiB transfers; interrupts per MiB from
`irq` under a bound. The page-pointer fix is also checked by hand as it
was found: a file of numbered lines, fewer than the 8,192 the editor
indexes, opened in `edit` from an EHCI stick, its line count read from the
status line.

Hardware: a timed 16 MiB copy from and to the card on the 701, and a program
run from `/home/bin`, before and after.

## 7. Order

1. EHCI page pointers. The defect, and the smallest change.
2. FAT table batching. The largest write win, pure and host-tested.
3. Slot to 64 KiB, with the EHCI and OHCI chains and the UHCI limit.
4. Callers at `BLOCK`.
5. DMA from the slot, with 3.
6. The block cache bypass, measured first.

Each landed on its own, the gate on the whole.

## 8. Risks

- Chained descriptors on the ICH6's EHCI and on a UHCI port: validated in
  the emulator, confirmed on the 701 by the copy in §6.
- Table batching widens the window in which the table on the medium lags the
  data from one entry to one call. A cut inside it leaves what a cut before
  the call's return already leaves, and `check` repairs it at mount.
- DMA from the slot depends on the slot staying mapped for the transfer,
  which the bridge already guarantees by holding a slot until `done`.
