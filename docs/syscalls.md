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

## `open`  <sub>#10</sub>

Open a file or directory.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | Absolute path. |
| `path_len` | len | Length of the path. |
| `flags` | flags | Bit 0 set opens a directory for reading entries. |

**Returns:** a handle

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space
- `EINVAL` — an argument is out of range
- `ENOENT` — no such file or directory
- `ENOMEM` — no handle slots free, or the buffer is too small

Read-only. Writing needs cluster allocation in the FAT driver, which is not written yet.

## `close`  <sub>#11</sub>

Close a handle.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | Handle to release. |

**Returns:** 0

**Errors:**

- `EBADF` — the handle is not open in this process

Closing a file releases the mount reference it held; a volume with handles still open cannot be unmounted.

## `seek`  <sub>#12</sub>

Move a file handle's read position.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | An open file. |
| `offset` | int | Displacement, interpreted per `whence`. |
| `whence` | uint | 0 from start, 1 from current, 2 from end. |

**Returns:** the new position

**Errors:**

- `EBADF` — the handle is not open in this process
- `EINVAL` — an argument is out of range

## `readdir`  <sub>#13</sub>

Read the next entry from an open directory.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | A directory handle from open() with the directory flag. |
| `buf` | ptr | Receives a DirEntry: u32 size, u8 flags, u8 name_len, then the name. |
| `buf_len` | len | Capacity of the buffer. |

**Returns:** bytes written, or 0 when the directory is exhausted

**Errors:**

- `EBADF` — the handle is not open in this process
- `EFAULT` — a pointer argument is outside the caller's address space
- `ENOMEM` — no handle slots free, or the buffer is too small

## `stat`  <sub>#14</sub>

Describe a path without opening it.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | Absolute path. |
| `path_len` | len | Length of the path. |
| `buf` | ptr | Receives the same DirEntry layout readdir() produces. |
| `buf_len` | len | Capacity of the buffer. |

**Returns:** bytes written

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space
- `ENOENT` — no such file or directory
- `ENOMEM` — no handle slots free, or the buffer is too small

## `spawn`  <sub>#15</sub>

Load and run a program, and wait for it to finish.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | Absolute path to an ELF executable. |
| `path_len` | len | Length of the path. |
| `argv` | const ptr | Packed arguments: u16 count, then each as u16 length followed by bytes. |
| `argv_len` | len | Length of the packed block. |

**Returns:** the program's exit status

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space
- `ENOENT` — no such file or directory
- `EINVAL` — an argument is out of range
- `ENOMEM` — no handle slots free, or the buffer is too small

Synchronous: the caller blocks until the child exits. Deliberately not fork — see design/00-vibeee.md §13. Asynchronous spawn arrives with job control, which needs somewhere to report a finished background job.

## `chdir`  <sub>#16</sub>

Change the working directory.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | Directory to move to; may be relative. |
| `path_len` | len | Length of the path. |

**Returns:** 0

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space
- `ENOENT` — no such file or directory
- `EINVAL` — an argument is out of range

The directory must exist. A child started afterwards inherits it.

## `getcwd`  <sub>#17</sub>

Read the working directory.

| arg | type | meaning |
|---|---|---|
| `buf` | ptr | Receives the absolute path. |
| `buf_len` | len | Capacity of the buffer. |

**Returns:** bytes written

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space
- `ENOMEM` — no handle slots free, or the buffer is too small

## `realtime_us`  <sub>#18</sub>

Read the wall clock.

| arg | type | meaning |
|---|---|---|
| `out` | ptr | Pointer to an i64 that receives microseconds since 1970-01-01 UTC. |

**Returns:** 0

**Errors:**

- `EFAULT` — a pointer argument is outside the caller's address space
- `EINVAL` — an argument is out of range

UTC, never local time. EINVAL until the clock has been set from a source; a machine whose battery-backed clock has failed reports that it does not know the time rather than claiming 1970. Use clock_us for measuring intervals: this one can step when a better source corrects it.

---

19 calls defined.
