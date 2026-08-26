# vibeee system calls

<!-- Generated from src/lib/syscalls.zig by `zig build syscall-docs`.
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

- `EBADF`, the handle is not open in this process
- `EFAULT`, a pointer argument is outside the caller's address space

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

- `EBADF`, the handle is not open in this process
- `EFAULT`, a pointer argument is outside the caller's address space

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

- `EFAULT`, a pointer argument is outside the caller's address space

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

- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range

Separate from write() so diagnostics survive a process losing its console handle. Rate-limited.

## `shutdown`  <sub>#8</sub>

Flush all filesystems and stop the machine.

| arg | type | meaning |
|---|---|---|
| `action` | uint | 0 power off, 1 reboot, 2 halt. |

**Returns:** does not return

**Errors:**

- `EINVAL`, an argument is out of range

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

- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range

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

- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `ENOENT`, no such file or directory
- `ENOMEM`, no handle slots free, or the buffer is too small

Read-only. Writing needs cluster allocation in the FAT driver, which is not written yet.

## `close`  <sub>#11</sub>

Close a handle.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | Handle to release. |

**Returns:** 0

**Errors:**

- `EBADF`, the handle is not open in this process

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

- `EBADF`, the handle is not open in this process
- `EINVAL`, an argument is out of range

## `readdir`  <sub>#13</sub>

Read the next entry from an open directory.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | A directory handle from open() with the directory flag. |
| `buf` | ptr | Receives a DirEntry: u32 size, u8 flags, u8 name_len, then the name. |
| `buf_len` | len | Capacity of the buffer. |

**Returns:** bytes written, or 0 when the directory is exhausted

**Errors:**

- `EBADF`, the handle is not open in this process
- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOMEM`, no handle slots free, or the buffer is too small

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

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `ENOMEM`, no handle slots free, or the buffer is too small

## `spawn`  <sub>#15</sub>

Load and run a program, and wait for it to finish.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | Absolute path to an ELF executable. |
| `path_len` | len | Length of the path. |
| `argv` | const ptr | Packed arguments: u16 count, then each as u16 length followed by bytes. |
| `argv_len` | len | Length of the packed block. |
| `flags` | flags | Bit 0 set returns immediately with the child's id instead of waiting. |

**Returns:** the program's exit status

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small

Synchronous: the caller blocks until the child exits. Deliberately not fork, see design/00-vibeee.md §13. Asynchronous spawn arrives with job control, which needs somewhere to report a finished background job.

## `chdir`  <sub>#16</sub>

Change the working directory.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | Directory to move to; may be relative. |
| `path_len` | len | Length of the path. |

**Returns:** 0

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `EINVAL`, an argument is out of range

The directory must exist. A child started afterwards inherits it.

## `getcwd`  <sub>#17</sub>

Read the working directory.

| arg | type | meaning |
|---|---|---|
| `buf` | ptr | Receives the absolute path. |
| `buf_len` | len | Capacity of the buffer. |

**Returns:** bytes written

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOMEM`, no handle slots free, or the buffer is too small

## `realtime_us`  <sub>#18</sub>

Read the wall clock.

| arg | type | meaning |
|---|---|---|
| `out` | ptr | Pointer to an i64 that receives microseconds since 1970-01-01 UTC. |

**Returns:** 0

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range

UTC, never local time. EINVAL until the clock has been set from a source; a machine whose battery-backed clock has failed reports that it does not know the time rather than claiming 1970. Use clock_us for measuring intervals: this one can step when a better source corrects it.

## `event_create`  <sub>#19</sub>

Create an event.

**Returns:** handle to the new event

**Errors:**

- `ENOMEM`, no handle slots free, or the buffer is too small

Events count rather than latch, so a signal delivered before anyone waits is kept and consumed by the next waiter instead of being lost.

## `event_signal`  <sub>#20</sub>

Signal an event, releasing one waiter.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | The event to signal. |

**Returns:** 0

**Errors:**

- `EBADF`, the handle is not open in this process

## `wait_many`  <sub>#21</sub>

Block until one of several events is signalled.

| arg | type | meaning |
|---|---|---|
| `handles` | const ptr | Array of u32 event handles. |
| `count` | len | How many, at most 8. |
| `timeout_us` | uint | 0 to poll, 0xFFFFFFFF to block forever, else microseconds. |

**Returns:** index of the event that fired

**Errors:**

- `EBADF`, the handle is not open in this process
- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `ETIMEDOUT`, the timeout elapsed before anything happened

The only blocking primitive: a server with a channel, a ring and a timer waits in one call rather than one thread each. When several are already signalled the lowest index wins, so priority is argument order.

## `svc_register`  <sub>#22</sub>

Create a channel and publish it under a name.

| arg | type | meaning |
|---|---|---|
| `name` | const ptr | Service name: lowercase, digits, dot and dash. |
| `name_len` | len | Length of the name. |

**Returns:** handle to the serving end of the channel

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small
- `EEXIST`, the name is already registered

Closing the returned handle withdraws the name and fails every call still waiting on a reply, which is what lets a client tell a crashed server from a slow one.

## `svc_connect`  <sub>#23</sub>

Open a channel to a registered service.

| arg | type | meaning |
|---|---|---|
| `name` | const ptr | Service name. |
| `name_len` | len | Length of the name. |

**Returns:** handle to the calling end of the channel

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `ENOMEM`, no handle slots free, or the buffer is too small

Clients hold a name rather than a handle to one instance, so reconnecting to a restarted server is a lookup rather than a redesign.

## `call`  <sub>#24</sub>

Send a request and block until the server replies.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | A channel from svc_connect. |
| `request` | const ptr | A Message to send. |
| `reply` | ptr | Receives the reply Message. |

**Returns:** bytes of reply payload

**Errors:**

- `EBADF`, the handle is not open in this process
- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `EPIPE`, the far end of the channel has closed

Payloads are capped at 64 bytes: anything larger is bulk data and belongs in a shared ring, and the message carries the handle to that ring. Up to four handles travel with a message; the receiver gets fresh numbers for the same objects. EPIPE means the serving end closed.

## `recv`  <sub>#25</sub>

Block until a request arrives on a served channel.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | A channel from svc_register. |
| `msg` | ptr | Receives the request Message, including any handles. |
| `token` | ptr | Receives a u32 naming this call, to pass to reply(). |
| `timeout_us` | uint | 0 to poll, 0xFFFFFFFF to block forever, else microseconds. |

**Returns:** bytes of request payload

**Errors:**

- `EBADF`, the handle is not open in this process
- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `ETIMEDOUT`, the timeout elapsed before anything happened

## `reply`  <sub>#26</sub>

Answer a call taken by recv().

| arg | type | meaning |
|---|---|---|
| `handle` | handle | The channel the call arrived on. |
| `token` | uint | The token recv() produced. |
| `msg` | const ptr | The reply Message, which may carry handles. |

**Returns:** 0

**Errors:**

- `EBADF`, the handle is not open in this process
- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range

The token carries a generation, so a reply to a call that has already been abandoned is rejected rather than landing on whichever call inherited the slot.

## `wait`  <sub>#27</sub>

Collect a child that has exited.

| arg | type | meaning |
|---|---|---|
| `pid` | uint | Which child, or 0 for whichever exits first. |
| `timeout_us` | uint | 0 to poll, 0xFFFFFFFF to block forever, else microseconds. |
| `status` | ptr | Receives the child's i32 exit status. |

**Returns:** the process id that exited

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ECHILD`, the caller has no such child to wait for
- `ETIMEDOUT`, the timeout elapsed before anything happened

A process that has exited stays as a corpse until collected, so a status is never lost before its parent can read it. Children of a process that dies are re-parented onto init, which collects them; ECHILD means there is nothing to wait for, now or ever.

## `shm_create`  <sub>#28</sub>

Allocate a shared-memory segment.

| arg | type | meaning |
|---|---|---|
| `size` | len | Bytes, rounded up to a page. |

**Returns:** handle to the segment

**Errors:**

- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small

The segment is zeroed, and is not mapped anywhere until shm_map. Pass the handle over a channel to share it: the segment outlives any one mapping, and its frames are freed only when the last reference goes.

## `shm_map`  <sub>#29</sub>

Map a segment into the calling process.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | A segment from shm_create or received over a channel. |
| `flags` | flags | Bit 0 set maps it writable. |

**Returns:** address the segment is mapped at

**Errors:**

- `EBADF`, the handle is not open in this process
- `ENOMEM`, no handle slots free, or the buffer is too small

Mapping the same segment twice returns two addresses onto the same memory. Addresses are not reused, so a process that maps repeatedly will eventually run out of window rather than silently aliasing.

---

30 calls defined.
