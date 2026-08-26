//! Translate x86 exception frames into the portable panic report.
//!
//! This is the boundary: everything above it (kernel/panic.zig) is
//! architecture-neutral, and everything x86 about a fault — vector numbering,
//! CR2, the page-fault error bitfield, which registers are worth showing —
//! stops here.

const cpu = @import("cpu.zig");
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

    panic.report(&r);
}
