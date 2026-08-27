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

Recorded into the kernel's ring and never printed: display is write()'s business, and a service line reaches the ring even on a quiet boot. The log tool reads the ring back, so what is said here is kept whether or not anyone saw it. Callers gate their own debug lines, which are the ones not worth keeping when nobody asked.

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
| `flags` | flags | OpenFlags: bit 0 directory, 1 write, 2 create, 3 truncate, 4 append. |

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
| `options` | const ptr | A Spawn struct, or 0 for defaults. Bit 0 of its flags returns immediately with the child's id instead of waiting. |

**Returns:** the program's exit status

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small

Synchronous: the caller blocks until the child exits. The status is never negative, so a negative result always means the child never ran: a process that was stopped rather than exiting reports 128 plus the reason, 137 for killed and 139 for a fault. Deliberately not fork, see design/00-vibeee.md §13. Asynchronous spawn arrives with job control, which needs somewhere to report a finished background job.

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

The message's `sender` field is filled in with the calling process's id. A server with many clients on one channel needs to know which is talking, and the kernel is the only party that cannot be lied to about it.

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

## `unlink`  <sub>#30</sub>

Remove a file.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | Path to the file. |
| `path_len` | len | Length of the path. |

**Returns:** 0

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `EINVAL`, an argument is out of range
- `EIO`, the underlying device failed

Directories are not removed by this call. Clusters are freed immediately, so a handle still open on the file will read whatever claims them next.

## `pointer_read`  <sub>#31</sub>

Read pending pointer events.

| arg | type | meaning |
|---|---|---|
| `buf` | ptr | Receives an array of PointerEvent. |
| `buf_len` | len | Capacity in bytes. |
| `timeout_us` | uint | 0 to poll, 0xFFFFFFFF to block forever, else microseconds. |

**Returns:** bytes written

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `ETIMEDOUT`, the timeout elapsed before anything happened

Events rather than pollable state: a press and release between two polls would vanish, and the boundaries of a drag would blur. Motion carries the button mask, so a drag is motion with a button already held. Motion may be dropped when the queue fills; a button transition never is.

## `display_acquire`  <sub>#32</sub>

Take exclusive ownership of the screen.

| arg | type | meaning |
|---|---|---|
| `info` | ptr | Receives a DisplayInfo describing the screen. |

**Returns:** handle to the scanout buffer, mappable with shm_map

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `EBUSY`, another process already owns it
- `ENOENT`, no such file or directory
- `ENOMEM`, no handle slots free, or the buffer is too small

Exactly one process may own the display: a compositor and the kernel console both drawing into one framebuffer produce a mess neither can recover from. Acquiring stops the console drawing; closing the handle gives it back, cleared. The buffer is an ordinary shared-memory handle, so it maps like any other.

## `key_read`  <sub>#33</sub>

Read raw key events, claiming the keyboard.

| arg | type | meaning |
|---|---|---|
| `buf` | ptr | Receives an array of KeyEvent. |
| `buf_len` | len | Capacity in bytes. |
| `timeout_us` | uint | 0 to poll, 0xFFFFFFFF to block forever, else microseconds. |

**Returns:** bytes written

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `ETIMEDOUT`, the timeout elapsed before anything happened

The first call claims the keyboard: events stop reaching the line discipline and arrive here instead, because a shell reading lines and a compositor reading keys cannot both consume the same keystroke. The claim is released when the process exits. Presses and releases both arrive, with the keycode for shortcuts and the codepoint for text.

## `kill`  <sub>#34</sub>

End another process.

| arg | type | meaning |
|---|---|---|
| `pid` | uint | Process to end. |

**Returns:** 0 on success

**Errors:**

- `ENOENT`, no such file or directory
- `EPERM`, the operation is not allowed on that object

There are no signals: this ends the process, it does not ask it to. The process dies at its next return to userspace, so kernel state it holds is unwound rather than abandoned; one blocked or sleeping is woken so that happens at once. Ending `init` is refused, since nothing would collect what it adopts.

## `pipe`  <sub>#35</sub>

Create a pipe.

| arg | type | meaning |
|---|---|---|
| `out` | ptr | Receives two u32 handles: the read end then the write end. |

**Returns:** 0 on success

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOMEM`, no handle slots free, or the buffer is too small

Reading blocks until there are bytes, and returns 0 once every writer has closed. Writing blocks while the pipe is full, and fails with EPIPE once every reader has closed. The read end can be passed to wait_many, so a process waiting on a pipe and on something else has one blocking call.

## `irq_attach`  <sub>#36</sub>

Take a device interrupt line.

| arg | type | meaning |
|---|---|---|
| `gsi` | uint | Global interrupt number, as the firmware describes it. |

**Returns:** a handle

**Errors:**

- `EBUSY`, another process already owns it
- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small

The handle can be passed to wait_many. The line stays masked until the first wait, so a driver may attach before it is ready to service the device. The kernel's own handler masks the line and signals; everything else about the interrupt happens in the driver. Closing the handle gives the line back, masked.

## `irq_ack`  <sub>#37</sub>

Say the device has been serviced, so its line may fire again.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | A handle from irq_attach. |

**Returns:** 0 on success

**Errors:**

- `EBADF`, the handle is not open in this process

Acknowledging a line that was not held is not an error: a driver that found nothing to do should say so rather than track whether one was outstanding.

## `mkdir`  <sub>#38</sub>

Create a directory.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | Absolute or relative path. |
| `path_len` | len | Length of the path. |

**Returns:** 0 on success

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `EEXIST`, the name is already registered
- `ENOENT`, no such file or directory
- `ENOSPC`, the volume is full
- `EPERM`, the operation is not allowed on that object

Only the last component is created; the parent must already exist. The new directory is written with its `.` and `..` already in place.

## `set_mode`  <sub>#39</sub>

Ask the display adapter for a mode.

| arg | type | meaning |
|---|---|---|
| `width` | uint | Pixels across. |
| `height` | uint | Pixels down. |
| `bpp` | uint | Bits per pixel, or 0 for whatever the adapter prefers. |

**Returns:** 0 on success

**Errors:**

- `EINVAL`, an argument is out of range
- `EBUSY`, another process already owns it
- `EPERM`, the operation is not allowed on that object
- `EIO`, the underlying device failed

Refused while something owns the display: changing the mode under a compositor would hand it a buffer of a different shape than the one it is drawing into. EPERM means no backend can drive this adapter, in which case what the firmware set is what there is.

## `ioport_grant`  <sub>#40</sub>

Allow this process to use a range of I/O ports directly.

| arg | type | meaning |
|---|---|---|
| `base` | uint | First port. |
| `count` | len | How many ports from there. |

**Returns:** 0 on success

**Errors:**

- `EPERM`, the operation is not allowed on that object
- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small

Needs the driver capability. Granted through the CPU's I/O permission bitmap rather than by mediating each access, so `in` and `out` then run at full speed from Ring 3. Grants accumulate and last until the process exits; there is no revoke, because a driver that no longer wants its ports is a driver that should exit.

## `map_device`  <sub>#41</sub>

Map a device's registers into this process.

| arg | type | meaning |
|---|---|---|
| `phys` | uint | Physical address of the aperture. |
| `len` | len | Bytes to map, rounded up to a page. |

**Returns:** the address it was mapped at

**Errors:**

- `EPERM`, the operation is not allowed on that object
- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small

Needs the driver capability. Mapped uncached, since a write to a register that sat in the cache would never reach the device, and marked as belonging elsewhere so ending the process unmaps it without handing device memory to the page allocator. There is no unmap: a driver that has finished with its device is a driver that should exit.

## `tty_mode`  <sub>#42</sub>

Choose how the console delivers what is typed.

| arg | type | meaning |
|---|---|---|
| `mode` | uint | A TtyMode: 0 cooked, 1 raw. |

**Returns:** the mode in effect before the call

**Errors:**

- `EINVAL`, an argument is out of range

Raw mode is what a shell drawing its own input line needs: it does its own echoing, so the kernel must not, and it needs the arrow keys, which produce no character and arrive as the escape sequences every terminal sends. The mode belongs to the console rather than to a handle, because there is one keyboard. A program that changes it puts it back.

## `watch`  <sub>#43</sub>

An event that fires when something happens.

| arg | type | meaning |
|---|---|---|
| `what` | uint | A Watchable: 0 keys, 1 pointer, 2 children. |

**Returns:** an event handle

**Errors:**

- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small

For a program with more than one thing to listen to. Each of these can otherwise only be waited for by the call that consumes it, which forces a program watching several into asking each in turn. This hands back the event that call would have waited on, so it goes into a wait_many with everything else and every read afterwards is one that never blocks.

## `rename`  <sub>#44</sub>

Move a file or directory, replacing what is already there.

| arg | type | meaning |
|---|---|---|
| `from` | const ptr | What to move. |
| `from_len` | len | Length of the path. |
| `to` | const ptr | Where it goes. |
| `to_len` | len | Length of the path. |

**Returns:** 0

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `EEXIST`, the name is already registered
- `EINVAL`, an argument is out of range
- `EIO`, the underlying device failed
- `EPERM`, the operation is not allowed on that object

Within one volume: across two this would be a copy and a delete, which takes time proportional to the file and fails differently, so it is refused rather than done silently. Replacing an existing file repoints the record that is already there, so the name means the old content or the new one and never nothing, which is what makes write-then-rename worth doing on FAT. A directory cannot replace or be replaced.

## `set_keymap`  <sub>#45</sub>

Choose which keyboard layout the keys mean.

| arg | type | meaning |
|---|---|---|
| `layout` | uint | A keymaps.Name, which is its index in the layout table. |

**Returns:** 0

**Errors:**

- `EINVAL`, an argument is out of range

The layouts are compiled into the kernel and userspace names them by the same list, so the number crossing here means the same layout on both sides. There is no call to read it back: the setting is where it is written down and reading the file is reading the answer.

## `mount`  <sub>#46</sub>

Attach a volume at a path.

| arg | type | meaning |
|---|---|---|
| `device` | const ptr | Volume name, as `disk` lists it. |
| `device_len` | len | Length of the name. |
| `path` | const ptr | Where it goes. Must exist as a directory of the mount above it. |
| `path_len` | len | Length of the path. |
| `flags` | flags | MountFlags: bit 0 read-only, bit 1 removable. |

**Returns:** 0

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `EEXIST`, the name is already registered
- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small
- `EPERM`, the operation is not allowed on that object

Requires Caps.mount. The longest mount path matching a lookup wins, so a volume attached deeper shadows what the one above it had there.

## `unmount`  <sub>#47</sub>

Detach the volume at a path, flushing it first.

| arg | type | meaning |
|---|---|---|
| `path` | const ptr | A mount point, exactly as it was mounted. |
| `path_len` | len | Length of the path. |

**Returns:** 0

**Errors:**

- `EFAULT`, a pointer argument is outside the caller's address space
- `ENOENT`, no such file or directory
- `EBUSY`, another process already owns it
- `EPERM`, the operation is not allowed on that object

Requires Caps.mount. Refused while anything on the volume is open, because a handle to a volume that no longer exists has no answer to give. FAT has no journal, so the flush is the only thing that puts written data on the medium.

## `ftruncate`  <sub>#48</sub>

Make an open file exactly this long.

| arg | type | meaning |
|---|---|---|
| `handle` | handle | An open file. |
| `size` | len | Bytes the file should end up holding. |

**Returns:** 0

**Errors:**

- `EBADF`, the handle is not open in this process
- `EINVAL`, an argument is out of range
- `EIO`, the underlying device failed
- `EPERM`, the operation is not allowed on that object

Shrinking gives back what is past the new end. Growing only moves the end: the space between is allocated when something writes into it, so a file made large and left alone costs a directory entry and nothing more.

## `quiesce`  <sub>#49</sub>

Flush and unmount everything, and return.

**Returns:** 0

**Errors:**

- `EPERM`, the operation is not allowed on that object

Requires Caps.power. The half of a shutdown only the kernel can do, for a caller that will finish it: entering a sleep state properly means evaluating the firmware's own methods first, which is an interpreter's job. Nothing is mounted afterwards, so a caller that needs a file should have read it already.

## `dma_alloc`  <sub>#50</sub>

Allocate physically contiguous DMA memory.

| arg | type | meaning |
|---|---|---|
| `size` | len | Bytes, rounded up to a page. |
| `phys` | const ptr | Where the physical base is written. |

**Returns:** handle to map with shm_map

**Errors:**

- `EPERM`, the operation is not allowed on that object
- `EFAULT`, a pointer argument is outside the caller's address space
- `EINVAL`, an argument is out of range
- `ENOMEM`, no handle slots free, or the buffer is too small

Requires Caps.driver. The promise shm_create does not make: one contiguous physical run, addressable by a DMA engine. Maps cached; the frames go back to the allocator when the last reference closes.

## `claim_device`  <sub>#51</sub>

Say a userspace driver now drives this device.

| arg | type | meaning |
|---|---|---|
| `bus` | uint | PCI bus number. |
| `device` | uint | PCI device number. |
| `function` | uint | PCI function number. |

**Returns:** 0

**Errors:**

- `EPERM`, the operation is not allowed on that object
- `ENOENT`, no such file or directory

Requires Caps.driver. The kernel's device table says driven for a device a kernel driver attached; a userspace driver is invisible to it until it says so here, and everything reading the table, the listing and a second service probing for unclaimed hardware alike, would read a driven device as free.

## `pci_read`  <sub>#52</sub>

Read one dword of PCI configuration space.

| arg | type | meaning |
|---|---|---|
| `location` | uint | bus << 8 | device << 3 | function. |
| `offset` | uint | Register offset, dword aligned. |

**Returns:** the register's value

**Errors:**

- `EPERM`, the operation is not allowed on that object

Requires Caps.driver. The two configuration ports are one shared index pair; every access in the system goes through the kernel so no two of them can interleave. Narrower reads are cut from the dword by the caller.

## `pci_write`  <sub>#53</sub>

Write one dword of PCI configuration space.

| arg | type | meaning |
|---|---|---|
| `location` | uint | bus << 8 | device << 3 | function. |
| `offset` | uint | Register offset, dword aligned. |
| `value` | uint | The dword to write. |

**Returns:** 0

**Errors:**

- `EPERM`, the operation is not allowed on that object

Requires Caps.driver. Read-modify-write for narrower widths is the caller's, made safe by every access sharing the kernel's one pair.

## `console_claim`  <sub>#54</sub>

Become the console's foreground.

**Returns:** 0

From this call on, only the claimer and its descendants render to the console; everything else's lines go to the kernel's ring alone, where the log tool reads them. The boot narrates onto the console because nothing has claimed it yet; the shell claims it when the console becomes a conversation.

## `sci_enable`  <sub>#55</sub>

Open or close the chipset's gate on the system control interrupt.

| arg | type | meaning |
|---|---|---|
| `on` | uint | One opens the gate, zero closes it. |

**Returns:** 0

**Errors:**

- `EPERM`, the operation is not allowed on that object

Requires Caps.driver. The SCI line is routed and left masked at boot; the runtime performs no controller writes, and this PM register bit is the switch the firmware's protocol says opens after its own handshake.

---

56 calls defined.
