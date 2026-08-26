//! Translate x86 exception frames into the portable panic report.
//!
//! This is the boundary: everything above it (kernel/panic.zig) is
//! architecture-neutral, and everything x86 about a fault, vector numbering,
//! CR2, the page-fault error bitfield, which registers are worth showing,
//! stops here.

const console = @import("../../kernel/console.zig");
const cpu = @import("cpu.zig");
const sched = @import("../../kernel/sched.zig");
const idt = @import("idt.zig");
const panic = @import("../../kernel/panic.zig");

const VECTOR_PAGE_FAULT = 14;

/// Called for any CPU exception with no registered handler.
pub fn onException(frame: *idt.Frame) noreturn {
    var r = panic.Report{
        .vector = frame.vector,
        .error_code = frame.error_code,
        .pc = frame.eip,
        .fp = frame.ebp,
        .from_user = frame.cs & 3 != 0,
        .decode_page_fault = frame.vector == VECTOR_PAGE_FAULT,
    };

    if (r.decode_page_fault) r.fault_addr = cpu.readCr2();

    // Without a privilege change the CPU pushes no stack selector, so the
    // frame's user_esp slot holds whatever happened to be above it. The
    // meaningful stack pointer in that case is where the frame itself sits.
    r.sp = if (r.from_user) frame.user_esp else @intFromPtr(frame);

    r.addReg("eax", frame.eax);
    r.addReg("ebx", frame.ebx);
    r.addReg("ecx", frame.ecx);
    r.addReg("edx", frame.edx);
    r.addReg("esi", frame.esi);
    r.addReg("edi", frame.edi);
    r.addReg("ebp", frame.ebp);
    r.addReg("efl", frame.eflags);

    // A program's mistake stops the program. Only the kernel faulting is worth
    // stopping the machine for: a buggy application taking the desktop with it
    // would make every other kind of robustness here pointless.
    if (r.from_user) {
        if (r.decode_page_fault) {
            console.warn("{s} in {s} at {x:0>8}, touching {x:0>8}", .{
                panic.exceptionName(frame.vector),
                sched.currentName(),
                frame.eip,
                r.fault_addr,
            });
        } else {
            console.warn("{s} in {s} at {x:0>8}", .{
                panic.exceptionName(frame.vector),
                sched.currentName(),
                frame.eip,
            });
        }
        sched.exitWith(FAULTED);
    }

    panic.report(&r);
}

/// What a process reports to whoever waits for it after a fault. Positive, and
/// 128 plus the number the same fate carries elsewhere: `spawn` returns a
/// status and an error in one signed word, so a negative status would read as
/// a program that never started.
const FAULTED: i32 = 128 + 11;
