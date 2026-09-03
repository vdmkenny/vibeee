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

pub const ar5212 = @import("ar5212.zig");
pub const audio = @import("audio.zig");
pub const audiograph = @import("audiograph.zig");
pub const battery = @import("battery.zig");
pub const bounded = @import("bounded.zig");
pub const Bounded = bounded.Bounded;
pub const calc = @import("calc.zig");
pub const civil = @import("civil.zig");
pub const cmdline = @import("cmdline.zig");
pub const decimal = @import("decimal.zig");
pub const font = @import("font.zig");
pub const framemap = @import("framemap.zig");
pub const logo = @import("logo.zig");
pub const ipv4 = @import("ipv4.zig");
pub const join = @import("join.zig");
pub const kind = @import("kind.zig");
pub const mac = @import("mac.zig");
pub const mlme = @import("mlme.zig");
pub const mmio = @import("mmio.zig");
pub const pci = @import("pci.zig");
pub const Phys = @import("phys.zig").Phys;
pub const fifo = @import("fifo.zig");
pub const find = @import("find.zig");
pub const limits = @import("limits.zig");
pub const ntp = @import("ntp.zig");
pub const openers = @import("openers.zig");
pub const palette = @import("palette.zig");
pub const rgb = @import("rgb.zig");
pub const ring = @import("ring.zig");
pub const driver = @import("driver.zig");
pub const elf = @import("elf.zig");
pub const escapes = @import("escapes.zig");
pub const exif = @import("exif.zig");
pub const eth = @import("eth.zig");
pub const hostname = @import("hostname.zig");
pub const hosts = @import("hosts.zig");
pub const icmp = @import("icmp.zig");
pub const ieee80211 = @import("ieee80211.zig");
pub const ifmatch = @import("ifmatch.zig");
pub const services = @import("services.zig");
pub const spsc = @import("spsc.zig");
pub const str = @import("str.zig");
pub const hid = @import("hid.zig");
pub const scsi = @import("scsi.zig");
pub const text = @import("text.zig");
pub const usb = @import("usb.zig");
pub const volume = @import("volume.zig");
pub const wifi = @import("wifi.zig");
pub const wpa2 = @import("wpa2.zig");
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

test {
    // A module that is only re-exported here is not analysed until
    // something reaches for it, and `zig test` collects tests from the
    // files it analyses. Without this the runner builds cleanly, reports
    // success, and has run none of them: naming every declaration is the
    // difference between a library that is tested and one that merely
    // contains tests.
    @import("std").testing.refAllDecls(@This());
}
