//! The process table, as userspace sees it.
//!
//! The kernel reports threads as tab-separated text under the `threads.list`
//! key. Turning that into rows, and the parent links into a tree, is the same
//! work whether the answer is printed to a terminal or drawn in a window, so
//! it happens once here.

const info = @import("info.zig");
const str = @import("str.zig");

/// Enough for anything the scheduler can hold. A list that silently stopped at
/// the interesting process would be worse than no list.
pub const MAX = 64;

pub const Process = struct {
    pid: usize = 0,
    parent: usize = 0,
    /// The scheduler's own name for the state, passed through rather than
    /// re-spelled: it changes when the scheduler changes, and a translation
    /// table here would go stale without anyone noticing.
    state: []const u8 = "",
    priority: usize = 0,
    ticks: usize = 0,
    name: []const u8 = "",
    /// Running on the CPU at the moment the list was taken.
    current: bool = false,
    /// Generations below its root, for indenting the tree.
    depth: u8 = 0,
};

pub const Table = struct {
    entries: [MAX]Process = @splat(.{}),
    count: usize = 0,

    /// In tree order: each process is followed by its children.
    pub fn items(self: *const Table) []const Process {
        return self.entries[0..self.count];
    }

    pub fn find(self: *const Table, pid: usize) ?*const Process {
        for (self.items()) |*p| {
            if (p.pid == pid) return p;
        }
        return null;
    }

    /// Total CPU ticks across every process, for working out shares.
    pub fn totalTicks(self: *const Table) usize {
        var sum: usize = 0;
        for (self.items()) |p| sum += p.ticks;
        return sum;
    }
};

/// Read the process table into tree order.
///
/// `buf` receives the kernel's text and the returned names point into it, so it
/// has to outlive the table.
pub fn read(buf: []u8) Table {
    var flat: [MAX]Process = @splat(.{});
    var count: usize = 0;

    var lines = str.lines(info.ask("threads.list", buf));
    while (lines.next()) |line| {
        if (line.len == 0 or count >= MAX) continue;

        var it = str.fields(line);
        flat[count] = .{
            .pid = str.toUnsigned(it.next() orelse continue),
            .parent = str.toUnsigned(it.next() orelse continue),
            .state = it.next() orelse "",
            .priority = str.toUnsigned(it.next() orelse ""),
            .ticks = str.toUnsigned(it.next() orelse ""),
            .name = it.next() orelse "",
            .current = str.toUnsigned(it.next() orelse "") != 0,
        };
        count += 1;
    }

    var table = Table{};
    var placed: [MAX]bool = @splat(false);

    // Roots first: a process whose parent is not in the list was started by the
    // kernel itself, and is where a branch begins.
    for (flat[0..count], 0..) |*p, i| {
        if (parentIndex(flat[0..count], p.parent) == null) {
            append(&table, flat[0..count], &placed, i, 0);
        }
    }

    // Anything left is in a parent cycle, which should not be possible. Showing
    // it out of tree order beats dropping it from the one list that would make
    // the bug visible.
    for (0..count) |i| {
        if (!placed[i]) append(&table, flat[0..count], &placed, i, 0);
    }

    return table;
}

fn parentIndex(flat: []const Process, pid: usize) ?usize {
    for (flat, 0..) |p, i| {
        if (p.pid == pid) return i;
    }
    return null;
}

fn append(table: *Table, flat: []Process, placed: []bool, index: usize, depth: u8) void {
    if (placed[index] or table.count >= MAX) return;
    placed[index] = true;

    table.entries[table.count] = flat[index];
    table.entries[table.count].depth = depth;
    table.count += 1;

    for (flat, 0..) |*child, i| {
        if (i != index and child.parent == flat[index].pid) {
            append(table, flat, placed, i, depth + 1);
        }
    }
}
