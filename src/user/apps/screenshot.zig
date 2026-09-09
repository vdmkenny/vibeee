//! screenshot: a picture of the display, or of the window on it.
//!
//! The manager owns the screen, so it is what copies the pixels; the encoding
//! and the writing happen here. That division is what keeps a picture from
//! costing the desktop a pause: a blit is the thing the manager is already
//! fastest at, and turning a megabyte and a half into a PNG is not.
//!
//! Written as PNG rather than JPEG. A screen is mostly text, and text is what
//! JPEG smears.

const client = @import("proto").client;
const env = @import("ulib").env;
const heap = @import("ulib").heap;
const img = @import("img");
const out = @import("ulib").out;
const rgb = @import("lib").rgb;
const std = @import("std");
const sys = @import("sys");
const time = @import("ulib").time;
const wm = @import("proto").wm;

/// Where a picture goes when nobody says. Beside a person's own files,
/// because that is whose picture it is.
const HOME = "/home";

comptime {
    _ = @import("clibc");
}

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    // Two at most: what to take a picture of, and where to put it.
    var words: [2][]const u8 = undefined;
    var given: usize = 0;
    while (given < words.len) : (given += 1) {
        words[given] = env.arg(frame, given + 1) orelse break;
    }

    run(words[0..given]);
    out.flush();
    sys.exit(0);
}

fn run(args: []const []const u8) void {
    var of: wm.Snapshot = .screen;
    var rest = args;
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "window")) {
        of = .focused;
        rest = rest[1..];
    } else if (rest.len > 0 and std.mem.eql(u8, rest[0], "screen")) {
        rest = rest[1..];
    }

    if (rest.len > 1) {
        out.text("usage: screenshot [screen | window] [file]\n");
        out.flush();
        return;
    }

    // The connection lasts as long as the command does, which is until the
    // picture is written: the manager forgets a client when its channel goes.
    var connection = client.Connection.open("screenshot") catch {
        out.fault("screenshot", "", "nothing is running the display");
        out.flush();
        return;
    };

    // Room for the whole screen, whichever is asked for: a window's picture
    // is smaller, and the manager says how much of it was filled.
    const enough = @as(usize, connection.screen_w) * connection.screen_h * @sizeOf(rgb.Colour);
    const handle = sys.shmCreate(enough) catch {
        out.fault("screenshot", "", "not enough memory for a picture of the screen");
        out.flush();
        return;
    };
    defer sys.close(handle);

    const took = connection.snapshot(of, handle) catch {
        out.fault("screenshot", "", "the display would not be copied");
        out.flush();
        return;
    };

    const pixels = sys.shmMap(handle, .{}) orelse {
        out.fault("screenshot", "", "the picture could not be reached");
        out.flush();
        return;
    };
    defer sys.shmUnmap(pixels);

    const count = @as(usize, took.w) * took.h;
    const colours: [*]rgb.Colour = @ptrCast(@alignCast(pixels));

    var named: [64]u8 = undefined;
    const path = if (rest.len == 1) rest[0] else nameNow(&named);
    write(path, .{
        .pixels = colours[0..count],
        .width = took.w,
        .height = took.h,
        .owned = false,
    });
    out.flush();
}

fn write(path: []const u8, picture: img.Picture) void {
    const gpa = heap.allocator;
    const count = @as(usize, picture.width) * picture.height;

    // Three bytes a pixel for the writer, and a file that cannot be larger
    // than the pixels it came from plus what a PNG puts around them.
    const scratch = gpa.alloc(u8, count * 3) catch return noRoom(path);
    defer gpa.free(scratch);
    const file = gpa.alloc(u8, count * 4 + 4096) catch return noRoom(path);
    defer gpa.free(file);

    const bytes = img.encodePng(picture, scratch, file) catch
        return out.fault("screenshot", path, "the picture would not encode");

    const handle = sys.open(path, .{ .write = true, .create = true, .truncate = true }) catch
        return out.fault("screenshot", path, "cannot create");
    defer sys.close(handle);

    var at: usize = 0;
    while (at < bytes.len) {
        const wrote = sys.write(handle, bytes[at..]) catch 0;
        if (wrote == 0) return out.fault("screenshot", path, "cannot write");
        at += wrote;
    }

    out.text(path);
    out.text(", ");
    out.decimal(picture.width);
    out.text(" by ");
    out.decimal(picture.height);
    out.text(", ");
    out.decimal(bytes.len);
    out.text(" bytes\n");
}

fn noRoom(path: []const u8) void {
    out.fault("screenshot", path, "not enough memory to encode a picture this size");
}

/// `/home/screen-2026-09-11-04-37-21.png`, so two pictures in a row do not
/// land on each other and a listing sorts them in the order they were taken.
fn nameNow(buf: []u8) []const u8 {
    const seconds = @divFloor(sys.realtimeMicros() orelse 0, 1_000_000);
    var stamp: [24]u8 = undefined;
    const when = time.stamp(&stamp, seconds);

    var at: usize = 0;
    for (HOME) |c| {
        buf[at] = c;
        at += 1;
    }
    for ("/screen-") |c| {
        buf[at] = c;
        at += 1;
    }
    // The stamp's own separators are not a filename's: a space and a colon in
    // a name are a name nobody can type at a shell.
    for (when) |c| {
        buf[at] = if (c == ' ' or c == ':') '-' else c;
        at += 1;
    }
    for (".png") |c| {
        buf[at] = c;
        at += 1;
    }
    return buf[0..at];
}
