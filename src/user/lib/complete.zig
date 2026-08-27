//! Finishing what someone has started typing.
//!
//! Separate from the editor because what makes sense at a prompt depends
//! entirely on the program: the editor knows where the word starts and ends
//! and nothing else. A caller registers sources, each one saying when it
//! applies and what it would offer, and the collector below does the part
//! every source would otherwise repeat: discarding what does not fit,
//! ignoring duplicates, and working out how far the answer is agreed.
//!
//! That last part is what lets a single key do the two things a person
//! expects of it. One candidate finishes the word. Several finish as far as
//! they agree and stop, so the next keystroke narrows rather than choosing,
//! and the same collected set is what an inline suggestion would draw from.

const str = @import("lib").str;

/// Where the cursor is in what has been typed, decomposed the way a source
/// needs to see it.
pub const Context = struct {
    /// The whole line, for a source that needs more than its own word.
    line: []const u8 = "",
    /// The word being completed, up to the cursor.
    word: []const u8 = "",
    /// Which word it is. Zero is the command itself.
    index: usize = 0,
    /// The command the line begins with, empty when that is what is being
    /// typed. What a source matches on to complete one command's arguments.
    command: []const u8 = "",

    /// Whether this is the command position, where the names of things that
    /// can be run belong.
    pub fn atCommand(self: Context) bool {
        return self.index == 0;
    }
};

/// Gathers candidates and works out what they agree on.
///
/// Holds no candidate list of its own: a machine with this much memory should
/// not keep every filename in a directory just to find their common prefix,
/// and the prefix can be narrowed one candidate at a time as they arrive.
pub const Collector = struct {
    /// The word being completed. Anything not starting with it is not an
    /// answer to the question that was asked.
    word: []const u8,

    /// How far the candidates agree, which is how much can be filled in
    /// without choosing for the user.
    agreed: [256]u8 = @splat(0),
    agreed_len: usize = 0,
    count: usize = 0,

    /// Offer a candidate. Ignored unless it extends the word.
    pub fn offer(self: *Collector, candidate: []const u8) void {
        if (!str.startsWith(candidate, self.word)) return;
        if (candidate.len > self.agreed.len) return;

        if (self.count == 0) {
            self.agreed_len = candidate.len;
            @memcpy(self.agreed[0..candidate.len], candidate);
            self.count = 1;
            return;
        }

        // The same name offered by two sources is one answer, not two.
        if (str.eql(self.settled(), candidate)) return;

        var same: usize = 0;
        const limit = @min(self.agreed_len, candidate.len);
        while (same < limit and self.agreed[same] == candidate[same]) same += 1;
        self.agreed_len = same;
        self.count += 1;
    }

    pub fn settled(self: *const Collector) []const u8 {
        return self.agreed[0..self.agreed_len];
    }

    /// What the word should become, or the word itself when nothing was
    /// offered or the candidates agree on no more than was typed already.
    pub fn resolve(self: *const Collector) []const u8 {
        if (self.count == 0 or self.agreed_len <= self.word.len) return self.word;
        return self.settled();
    }

    /// Whether the answer is the only one, which is when a trailing space is
    /// welcome: the word is finished and the next one is about to start.
    pub fn settledOne(self: *const Collector) bool {
        return self.count == 1;
    }
};

/// When a source applies.
pub const When = enum {
    /// The command position: the names of things that can be run.
    command,
    /// The arguments of the one command it names.
    named,
    /// The arguments of every command no `named` source claims.
    ///
    /// Where filenames belong. Most commands take one, so making that the
    /// default rather than an entry per command means a program added to the
    /// system completes its arguments without anybody remembering to say so,
    /// and the table holds only the commands that want something else.
    otherwise,
};

/// A source of candidates: when it applies, and what it would offer.
pub const Source = struct {
    when: When = .named,
    /// Which command, for a `named` source. Ignored by the other two.
    command: []const u8 = "",
    offer: *const fn (ctx: Context, into: *Collector) void,
};

/// Ask every source that applies, and gather what they agree on.
pub fn resolve(sources: []const Source, ctx: Context, into: *Collector) void {
    if (ctx.atCommand()) {
        for (sources) |source| {
            if (source.when == .command) source.offer(ctx, into);
        }
        return;
    }

    var claimed = false;
    for (sources) |source| {
        if (source.when == .named and str.eql(source.command, ctx.command)) {
            source.offer(ctx, into);
            claimed = true;
        }
    }
    if (claimed) return;

    for (sources) |source| {
        if (source.when == .otherwise) source.offer(ctx, into);
    }
}

/// Split a line the way a source needs to see it: which word the cursor is
/// in, and what the command is.
pub fn contextAt(line: []const u8, cursor: usize) Context {
    var start = cursor;
    while (start > 0 and line[start - 1] != ' ') start -= 1;

    // Which word this is, counted by the runs of non-space before it.
    var index: usize = 0;
    var i: usize = 0;
    var in_word = false;
    while (i < start) : (i += 1) {
        if (line[i] == ' ') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            index += 1;
        }
    }

    var command: []const u8 = "";
    if (index > 0) {
        var first: usize = 0;
        while (first < line.len and line[first] == ' ') first += 1;
        var last: usize = first;
        while (last < line.len and line[last] != ' ') last += 1;
        command = line[first..last];
    }

    return .{
        .line = line,
        .word = line[start..cursor],
        .index = index,
        .command = command,
    };
}
