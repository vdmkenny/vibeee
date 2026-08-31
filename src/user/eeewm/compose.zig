//! What a window carries for the compositor: its pixels and what changed.
//!
//! Pure data, in a module of its own, because both sides of the manager need
//! it and neither may bring the other's dependencies: the layout is pure
//! geometry that must stay testable without a machine, and the client table
//! talks to the kernel. The window owns these rather than the compositor
//! keeping them in arrays beside the window table, because arrays beside a
//! table have to be reordered in step with it, and once they were not: two
//! windows drew each other's pixels.

const eui = @import("eui");

const Rect = eui.Rect;

pub const Surface = struct {
    pixels: ?[*]u32 = null,
    width: u16 = 0,
    height: u16 = 0,
    stride: u16 = 0,
    /// Held so the mapping survives; released when the window goes.
    handle: u32 = 0,

    pub fn valid(self: Surface) bool {
        return self.pixels != null and self.width > 0 and self.height > 0;
    }
};

/// What part of a window changed since it was last composited.
pub const Damage = struct {
    rects: [MAX_RECTS]Rect = @splat(.{}),
    count: usize = 0,
    /// Everything, because the window moved or was just mapped and there is no
    /// previous content to keep.
    all: bool = false,

    /// As many as a commit can carry.
    pub const MAX_RECTS = 3;

    pub fn isEmpty(self: Damage) bool {
        return self.count == 0 and !self.all;
    }

    pub fn add(self: *Damage, area: Rect) void {
        if (self.all or area.isEmpty()) return;

        if (self.count == MAX_RECTS) {
            // Past what a commit carries, everything merges into one box: the
            // bookkeeping would cost more than the pixels it saved.
            var all = self.rects[0];
            for (self.rects[1..self.count]) |r| all = all.unite(r);
            self.rects[0] = all.unite(area);
            self.count = 1;
            return;
        }

        self.rects[self.count] = area;
        self.count += 1;
    }

    pub fn whole(self: *Damage) void {
        self.all = true;
        self.count = 0;
    }

    pub fn clear(self: *Damage) void {
        self.* = .{};
    }
};
