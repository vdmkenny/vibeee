//! Lines out of a stream.
//!
//! Every text tool wants the same loop: read a chunk, split it on newlines,
//! carry a part-line across the chunk boundary, and count a last line with no
//! newline after it. Written once here so `grep`, `head`, `tail`, `wc` and
//! `sort` cannot disagree about what a line is.
//!
//! A reader carries its buffers, which makes one five kilobytes. The user
//! stack is thirty-two, so a tool keeps its reader beside its other state
//! rather than on the frame.

const sys = @import("sys");

/// How much is taken from the handle at once. A read is a syscall and a
//  filesystem seek, so it is worth doing in pages rather than in lines.
const CHUNK = 4096;

/// The longest line kept whole. Longer is handed over cut with `cut` set:
/// losing the tail of a very long line beats losing the line.
pub const MAX = 1024;

pub const Reader = struct {
    handle: u32 = sys.STDIN,

    chunk: [CHUNK]u8 = undefined,
    /// What the last read brought, and how far into it `next` has walked.
    held: usize = 0,
    at: usize = 0,

    line: [MAX]u8 = undefined,
    /// Whether the line just handed over was longer than it could hold.
    cut: bool = false,
    /// How long that line was, which is not how much of it came back when it
    /// ran past `MAX`. What a tool counting bytes wants is the length the
    /// stream had, and the part that fit is a different number.
    full: usize = 0,
    /// Runs of anything that is not a space, over the whole line.
    ///
    /// Counted here rather than by whoever wants the number, because this
    /// loop is the only thing that sees a long line in full: counting from
    /// what comes back counts the part that fit and calls it the line.
    words: usize = 0,
    /// The stream gave its last line; nothing more will come.
    ///
    /// True on the call that hands over a line means that line ended at the
    /// end of the stream and had no newline after it, which is a byte the
    /// file did not have.
    spent: bool = false,

    pub fn of(handle: u32) Reader {
        return .{ .handle = handle };
    }

    /// The next line, without its newline, or null at the end of the stream.
    ///
    /// The slice points into the reader and lasts until the next call, which
    /// is what keeps a tool that only looks at one line at a time free of
    /// any copying at all.
    pub fn next(self: *Reader) ?[]const u8 {
        if (self.spent) return null;

        var len: usize = 0;
        var inside = false;
        self.cut = false;
        self.full = 0;
        self.words = 0;

        while (true) {
            if (self.at == self.held) {
                const got = sys.read(self.handle, &self.chunk) catch 0;
                if (got == 0) {
                    self.spent = true;
                    // A last line with no newline after it is still a line.
                    return if (len > 0 or self.cut) self.line[0..len] else null;
                }
                self.held = got;
                self.at = 0;
            }

            const byte = self.chunk[self.at];
            self.at += 1;
            if (byte == '\n') return self.line[0..len];

            self.full += 1;
            const blank = byte == ' ' or byte == '\t' or byte == '\r';
            if (!blank and !inside) self.words += 1;
            inside = !blank;

            if (len < MAX) {
                self.line[len] = byte;
                len += 1;
            } else {
                self.cut = true;
            }
        }
    }
};
