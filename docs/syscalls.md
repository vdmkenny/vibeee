# vibeee system calls

<!-- Generated from src/kernel/syscall_table.zig by `zig build syscall-docs`.
     Do not edit: change the table instead. -->

Calls enter the kernel through `SYSENTER` where the CPU provides it, and
through `int 0x80` otherwise; the choice is made once at libc start-up and
the register convention is identical either way.

| register | meaning |
|---|---|
| `eax` | call number on entry, result on return |
| `ebx`, `ecx`, `edx`, `esi`, `edi` | arguments 0-4 |

A negative result is `-errno`. Pointer arguments are validated against the
caller's address space before use, and a range crossing into kernel memory
fails with `EFAULT` rather than faulting.

## `exit`  <sub>#0</sub>

Terminate the calling process.

| arg | type | meaning |
|---|---|---|
| `status` | int | Exit status reported to whoever waits for this process. |

**Returns:** does not return

## `write`  <sub>#1</sub>

Write bytes to an open handle.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | Destination. STDOUT and STDERR go to the console. |
| `buf` | const ptr | Bytes to write. |
| `len` | len | Number of bytes. |

**Returns:** bytes written

**Errors:**

- `EBADF` — the handle is not open in this process
- `EFAULT` — a pointer argument is outside the caller's address space

Short writes are possible; callers must loop.

## `read`  <sub>#2</sub>

Read bytes from an open handle.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | Source. |
| `buf` | ptr | Where to put the bytes. |
| `len` | len | Maximum bytes to read. |

**Returns:** bytes read, or 0 at end of input

**Errors:**

- `EBADF` — the handle is not open in this process
- `EFAULT` — a pointer argument is outside the caller's address space

Blocks until input is available. On STDIN, input is line-buffered: a read returns once Enter is pressed, and never mid-line.

## `yield`  <sub>#3</sub>

Give up the rest of the current time slice.

**Returns:** 0

A hint, not a guarantee: the scheduler may immediately pick the same thread again if nothing else is runnable.

## `sleep_us`  <sub>#4</sub>

Block the calling thread for at least the given time.

| arg | type | meaning |
|---|---|---|
| `usec` | uint | Minimum microseconds to sleep. |

**Returns:** 0

Resolution is bounded by the timer tick, so short sleeps round up.

## `clock_us`  <sub>#5</sub>

Read the monotonic clock.

| arg | type | meaning |
|---|---|---|
| `out` | ptr | Pointer to a u64 that receives microseconds since boot. |

**Returns:** 0

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space

Monotonic and never steps backwards. Not wall-clock time; it is unaffected by clock adjustment.

## `getpid`  <sub>#6</sub>

Return the calling process's identifier.

**Returns:** process id

## `log`  <sub>#7</sub>

Write a line to the kernel log.

| arg | type | meaning |
|---|---|---|
| `buf` | const ptr | Message text, without a trailing newline. |
| `len` | len | Message length. |

**Returns:** 0

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space
- `EINVAL` — an argument is out of range

Separate from write() so diagnostics survive a process losing its console handle. Rate-limited.

## `shutdown`  <sub>#8</sub>

Flush all filesystems and stop the machine.

| arg | type | meaning |
|---|---|---|
| `action` | uint | 0 power off, 1 reboot, 2 halt. |

**Returns:** does not return

**Errors:**

- `EINVAL` — an argument is out of range

Unmounts every filesystem and flushes every device before acting. FAT has no journal, so this is the only way to guarantee written data reached the medium.

## `sysinfo`  <sub>#9</sub>

Read a named piece of system information.

| arg | type | meaning |
|---|---|---|
| `key` | const ptr | Key name, e.g. "cpu", "mem", "board", "smbios". |
| `key_len` | len | Length of the key. |
| `buf` | ptr | Where the value is written. |
| `buf_len` | len | Capacity of the buffer. |

**Returns:** bytes written

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space
- `EINVAL` — an argument is out of range

Values are text, except "smbios" which returns the raw DMI structure table for a userspace decoder. A keyed interface rather than a struct, so adding a value is not an ABI break.

---

10 calls defined.
