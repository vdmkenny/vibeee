//! Code shared by the kernel and by userspace.
//!
//! Everything reachable from here is pure computation: no state, no hardware,
//! no syscalls. That restriction is what makes it safe to compile the same
//! source into both sides of the privilege boundary, and it is enforced by
//! `tools/check-layering.zig` rather than left to discipline.
//!
//! Imported as a named module (`@import("lib")`) rather than by relative path,
//! so kernel and userspace share one instance and its types are the same type
//! on both sides of a syscall.

pub const audio = @import("audio.zig");
pub const audiograph = @import("audiograph.zig");
pub const battery = @import("battery.zig");
pub const bounded = @import("bounded.zig");
pub const Bounded = bounded.Bounded;
pub const civil = @import("civil.zig");
pub const cmdline = @import("cmdline.zig");
pub const font = @import("font.zig");
pub const logo = @import("logo.zig");
pub const ipv4 = @import("ipv4.zig");
pub const mac = @import("mac.zig");
pub const mmio = @import("mmio.zig");
pub const pci = @import("pci.zig");
pub const fifo = @import("fifo.zig");
pub const ring = @import("ring.zig");
pub const driver = @import("driver.zig");
pub const elf = @import("elf.zig");
pub const escapes = @import("escapes.zig");
pub const eth = @import("eth.zig");
pub const hosts = @import("hosts.zig");
pub const icmp = @import("icmp.zig");
pub const ieee80211 = @import("ieee80211.zig");
pub const ifmatch = @import("ifmatch.zig");
pub const spsc = @import("spsc.zig");
pub const str = @import("str.zig");
pub const scsi = @import("scsi.zig");
pub const usb = @import("usb.zig");
pub const wifi = @import("wifi.zig");
pub const style = @import("style.zig");
pub const syscalls = @import("syscalls.zig");

test {
    _ = battery;
    _ = bounded;
    _ = civil;
    _ = cmdline;
    _ = font;
    _ = logo;
    _ = mac;
    _ = pci;
    _ = ring;
    _ = driver;
    _ = elf;
    _ = audio;
    _ = audiograph;
    _ = escapes;
    _ = eth;
    _ = hosts;
    _ = ieee80211;
    _ = icmp;
    _ = ifmatch;
    _ = ipv4;
    _ = mmio;
    _ = spsc;
    _ = str;
    _ = usb;
    _ = wifi;
    _ = style;
    _ = syscalls;
}
