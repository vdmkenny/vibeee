//! Host-side unit tests.
//!
//! Anything portable, allocators, encoders, table generators, layout algebra
//! is tested natively here, with no emulator and no hardware in the loop. On a
//! project whose target machine has no serial port, pushing as much correctness
//! as possible into this file is what keeps hardware bring-up tractable.

test {
    _ = @import("kernel/bootinfo.zig");
    _ = @import("kernel/klog.zig");
    _ = @import("kernel/ports.zig");
    _ = @import("kernel/probe.zig");
    _ = @import("arch/x86/mtrr.zig");
    _ = @import("arch/x86/timer.zig");
    // What stands between a stray user pointer and a dead machine. Split from
    // the paging code it belongs to precisely so it can be asked here, against
    // tables built by hand, rather than only on a machine that would stop.
    _ = @import("arch/x86/pagetable.zig");
    _ = @import("drv/video/modeset/modeset.zig");
    _ = @import("drv/video/modeset/gen3cursor.zig");
    // Generic over its node type precisely so it can be tested here, off the
    // hardware: the run queues are where this system's worst bug lived.
    _ = @import("kernel/sched/queue.zig");
    _ = @import("lib");
    _ = @import("qr_test.zig");
    _ = @import("keymap_test.zig");
    _ = @import("user/eterm/vt_test.zig");
    _ = @import("user/eterm/render.zig");
    _ = @import("user/eui/text_test.zig");
    // The toolkit whole, rather than a list of its modules: a list is a
    // second place that has to be kept agreeing with the first, and the way
    // it fails is a module whose tests quietly stop running.
    _ = @import("user/eui/eui.zig");
    _ = @import("user/lib/bindings.zig");
    _ = @import("user/lib/command.zig");
    // What a settings file says, which is read by four services and
    // written by one: pure text, and the one parser a bad line reaches.
    _ = @import("user/lib/config.zig");
    _ = @import("user/lib/env.zig");
    // Both halves of the terminal key codec, and the proof they are inverses:
    // a key that can be sent and not read is one that works on the machine's
    // own screen and does nothing inside a terminal window.
    _ = @import("user/lib/keys.zig");
    _ = @import("user/lib/ustar.zig");
    // One maker's numbers for the serial adapter everybody owns: the
    // divisors, the data word, and the status bytes on every packet.
    _ = @import("user/usbd/ftdi/regs.zig");
    _ = @import("user/netd/attansic.zig");
    _ = @import("user/netd/cursor.zig");
    _ = @import("user/netd/mii.zig");
    // The page an L1E receives into, which is the only part of that
    // driver that can be run anywhere but on the machine that has one.
    _ = @import("user/netd/rxpage.zig");
    _ = @import("user/netd/route.zig");
    _ = @import("user/lib/time.zig");
    _ = @import("user/lib/paths.zig");
    _ = @import("user/lib/console.zig");
    _ = @import("user/lib/table.zig");
    // Whether the ciphertext in hand starts with a whole record, which is what
    // lets a sealed connection be read without waiting on the socket.
    _ = @import("user/lib/tls.zig");
    // The C library's length modifiers: which type a `printf` argument is
    // read as and a `scanf` result is stored as. The rest of the formatter
    // needs a stream, and this is the part that decides where the bytes go.
    _ = @import("user/libc/length.zig");
    // Every decision about a program image, away from the frames and the
    // mappings it would otherwise take to ask one: the files worth asking
    // about are the ones no linker would produce.
    _ = @import("kernel/elf/plan.zig");
    // The long-name assembler, which is the most exposed parser here: it runs
    // over bytes from whatever medium somebody puts in the machine.
    _ = @import("kernel/fat.zig");
    // The volume's own account of how it was last put down, and the walk that
    // compares the two halves of a volume against each other. Both run over a
    // medium built in memory, so a power cut is a test rather than an outing
    // with the machine's own card.
    _ = @import("kernel/fat/clean.zig");
    _ = @import("kernel/fat/check.zig");
    // What a check decides, which is arithmetic over two descriptions and
    // needs no volume at all: every way a record and its chain can disagree
    // is a case there rather than a medium damaged to reach it.
    _ = @import("kernel/fat/verdict.zig");
    // The geometry a boot sector describes, which mounting reads and
    // formatting writes. Its round trip is what keeps the two agreeing.
    _ = @import("kernel/fat/layout.zig");
    _ = @import("kernel/fat/format.zig");
    _ = @import("kernel/fat/grow.zig");
    _ = @import("kernel/fat/bulk.zig");
    _ = @import("kernel/ublk.zig");
    // The device table's row and name discipline: rows are reused as media
    // come and go, and a name has to stay with the row it names.
    _ = @import("kernel/block.zig");
    // The line discipline's rules, apart from the keyboard and the screen:
    // what a keystroke echoes and what a reader gets, in both modes.
    _ = @import("kernel/tty.zig");
    // A driver's pure half: what the AR5212 family's words mean and the
    // arithmetic its bring-up runs. Values a test can check, kept with the
    // driver that is the only thing reading them.
    _ = @import("user/netd/ar5212/family.zig");
}
