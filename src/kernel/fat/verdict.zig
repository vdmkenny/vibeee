//! What a volume check decides, with no I/O.
//!
//! FAT records a file's length twice: the directory record holds the first
//! cluster and the size in bytes, the allocation table holds the chain. Each
//! way the two can differ has one correct repair.
//!
//! Separated from `fat/check.zig` so each case is a table entry rather than a
//! volume damaged to reach it. `fat/check.zig` keeps the I/O: reading the
//! chain and writing the repair.
//!
//! Nothing here allocates, reads or writes.

const std = @import("std");

/// What a record says about itself.
pub const Claim = struct {
    /// A directory's record holds no length. Its size field is zero
    /// whatever its chain holds, so there is nothing to compare.
    is_dir: bool,
    /// The length in bytes the record gives.
    size: u32,
    /// Where the record says the chain begins. Zero means no chain, which
    /// is how an empty file is recorded.
    first: u32,
    /// How many bytes a cluster of this volume holds.
    cluster_size: u32,
};

/// Where following a chain stopped, and why.
pub const Outcome = enum {
    /// Reached an end-of-chain marker.
    ended,
    /// Returned to a cluster already walked in this chain.
    looped,
    /// Reached a cluster another chain claims.
    crossed,
    /// Pointed outside the volume.
    strayed,
};

/// What following it found. Lengths are in clusters.
pub const Chain = struct {
    /// How many clusters were walked before stopping.
    length: u32 = 0,
    /// The last cluster walked that is on the volume. Zero if none was.
    last: u32 = 0,
    /// The cluster at the end of what the record's size accounts for,
    /// recorded during the walk. Set only if the walk reached that far.
    cut_after: u32 = 0,
    outcome: Outcome = .ended,
};

/// Where a chain is to be ended, and what length that leaves.
pub const Cut = struct {
    /// The cluster to write an end-of-chain marker into. Everything after
    /// it is freed.
    after: u32,
    /// How many clusters the record holds afterwards.
    clusters: u32,
};

/// The repair a difference calls for. One case per way the two sides can
/// differ, named for the fault rather than the repair, so that counting
/// faults and applying repairs both read the same answer.
pub const Verdict = union(enum) {
    /// The record and its chain agree. Nothing to do.
    agree,
    /// The record claims bytes but names no chain. Those bytes were never
    /// written.
    claims_nothing,
    /// The record's first cluster is not on the volume. Nothing can be
    /// followed, so nothing can be kept.
    begins_nowhere,
    /// The chain left the volume or looped part way along. The clusters
    /// before that point are valid and are kept.
    breaks_at: Cut,
    /// The chain holds more clusters than the size accounts for. This is
    /// what an interrupted write leaves.
    runs_long: Cut,
    /// The size accounts for nothing and the record names a chain anyway.
    /// The whole chain is freed.
    holds_unclaimed,
    /// The chain is shorter than the size claims, so the size is wrong: the
    /// clusters past the chain were never written. Carries the length in
    /// clusters the record can claim.
    runs_short: u32,
    /// Two chains claim one cluster. Assigning it to either takes it from
    /// the other, and the medium does not record which is correct.
    contested,
};

/// How many clusters a file of `size` bytes occupies.
///
/// Computed in sixty-four bits: a record's size field is a full `u32`, and
/// rounding the largest one up to the next cluster overflows thirty-two.
pub fn clustersFor(size: u32, cluster_size: u32) u32 {
    std.debug.assert(cluster_size != 0);
    const rounded = (@as(u64, size) + cluster_size - 1) / cluster_size;
    return @intCast(rounded);
}

/// What to do about a record and the chain it turned out to have.
pub fn decide(claim: Claim, chain: Chain) Verdict {
    if (claim.first == 0) {
        // No chain. For a file that means the bytes the record claims are
        // not on the medium.
        return if (!claim.is_dir and claim.size != 0) .claims_nothing else .agree;
    }

    switch (chain.outcome) {
        .crossed => return .contested,
        .looped, .strayed => {
            // Nothing was walked, so the first cluster was the bad one and
            // there is nothing to keep.
            if (chain.length == 0) return .begins_nowhere;
            return .{ .breaks_at = .{ .after = chain.last, .clusters = chain.length } };
        },
        .ended => {},
    }

    // A directory's length is its chain's length. There is nothing to
    // compare it against.
    if (claim.is_dir) return .agree;

    const needed = clustersFor(claim.size, claim.cluster_size);
    if (chain.length > needed) {
        if (needed == 0) return .holds_unclaimed;
        return .{ .runs_long = .{ .after = chain.cut_after, .clusters = needed } };
    }
    if (chain.length < needed) return .{ .runs_short = chain.length };
    return .agree;
}

const testing = std.testing;

/// A verdict's case without its payload, which is what most of these check.
const Tag = std.meta.Tag(Verdict);

fn tagOf(answer: Verdict) Tag {
    return std.meta.activeTag(answer);
}

/// A file on a volume with hundred-byte clusters, which keeps the
/// arithmetic in these cases easy to read.
fn file(size: u32, first: u32) Claim {
    return .{ .is_dir = false, .size = size, .first = first, .cluster_size = 100 };
}

fn directory(first: u32) Claim {
    return .{ .is_dir = true, .size = 0, .first = first, .cluster_size = 100 };
}

test "a size rounds up to the clusters that hold it" {
    try testing.expectEqual(@as(u32, 0), clustersFor(0, 100));
    try testing.expectEqual(@as(u32, 1), clustersFor(1, 100));
    try testing.expectEqual(@as(u32, 1), clustersFor(100, 100));
    try testing.expectEqual(@as(u32, 2), clustersFor(101, 100));
}

test "the largest size a record can hold still rounds up" {
    // Rounding the largest size up to the next cluster overflows thirty-two
    // bits. Computed there it returns zero, and the whole file then reads as
    // a tail to reclaim.
    const largest = std.math.maxInt(u32);
    try testing.expectEqual(@as(u32, 1), clustersFor(largest, largest));
    try testing.expectEqual(@as(u32, 2), clustersFor(largest, largest / 2 + 1));
    try testing.expect(clustersFor(largest, 512) > 0);
}

test "a record and chain that agree are left alone" {
    // Exactly full, then part way into the last cluster.
    try testing.expectEqual(Tag.agree, tagOf(decide(file(200, 5), .{ .length = 2, .last = 6 })));
    try testing.expectEqual(Tag.agree, tagOf(decide(file(150, 5), .{ .length = 2, .last = 6 })));
}

test "an empty file names no chain and that is correct" {
    try testing.expectEqual(Tag.agree, tagOf(decide(file(0, 0), .{})));
}

test "a record claiming bytes with no chain is cut to nothing" {
    try testing.expectEqual(Tag.claims_nothing, tagOf(decide(file(50, 0), .{})));
}

test "a directory is judged on its chain alone" {
    // Its record's size says nothing, so a walked chain of any length agrees
    // with it, and the case that would be a mismatch for a file is not one.
    try testing.expectEqual(Tag.agree, tagOf(decide(directory(5), .{ .length = 3, .last = 7 })));
    try testing.expectEqual(Tag.agree, tagOf(decide(directory(0), .{})));
}

test "a chain longer than its record is cut where the record runs out" {
    const answer = decide(file(150, 5), .{ .length = 4, .last = 8, .cut_after = 6 });
    try testing.expectEqual(Tag.runs_long, std.meta.activeTag(answer));
    try testing.expectEqual(@as(u32, 6), answer.runs_long.after);
    try testing.expectEqual(@as(u32, 2), answer.runs_long.clusters);
}

test "a chain under a zero-length record is freed entirely" {
    // Distinct from the case above: there is no cluster to cut after, because
    // the record keeps none of the chain.
    try testing.expectEqual(Tag.holds_unclaimed, tagOf(decide(file(0, 5), .{ .length = 3, .last = 7 })));
}

test "a size larger than its chain is brought down to the chain" {
    const answer = decide(file(500, 5), .{ .length = 2, .last = 6 });
    try testing.expectEqual(Tag.runs_short, std.meta.activeTag(answer));
    try testing.expectEqual(@as(u32, 2), answer.runs_short);
}

test "a chain that breaks part way keeps the clusters before the break" {
    for ([_]Outcome{ .strayed, .looped }) |outcome| {
        const answer = decide(file(500, 5), .{ .length = 3, .last = 7, .outcome = outcome });
        try testing.expectEqual(Tag.breaks_at, std.meta.activeTag(answer));
        try testing.expectEqual(@as(u32, 7), answer.breaks_at.after);
        try testing.expectEqual(@as(u32, 3), answer.breaks_at.clusters);
    }
}

test "a chain whose first cluster is off the volume keeps nothing" {
    // Nothing was walked, so there is no cluster to end the chain at and no
    // part of the file is recoverable.
    for ([_]Outcome{ .strayed, .looped }) |outcome| {
        try testing.expectEqual(
            Tag.begins_nowhere,
            tagOf(decide(file(500, 99), .{ .length = 0, .outcome = outcome })),
        );
    }
}

test "a cluster two chains claim is never decided here" {
    // A contested cluster outranks any other fault in the record: once a
    // chain runs into another, its length cannot be trusted.
    try testing.expectEqual(
        Verdict.contested,
        decide(file(500, 5), .{ .length = 2, .last = 6, .outcome = .crossed }),
    );
    try testing.expectEqual(
        Verdict.contested,
        decide(directory(5), .{ .length = 2, .last = 6, .outcome = .crossed }),
    );
}

test "every case of the union is reachable" {
    // A case added without a rule that returns it fails here, rather than
    // going unnoticed because nothing ever produces it.
    var reached = std.EnumSet(Tag).initEmpty();

    const cases = [_]struct { claim: Claim, chain: Chain }{
        .{ .claim = file(200, 5), .chain = .{ .length = 2, .last = 6 } },
        .{ .claim = file(50, 0), .chain = .{} },
        .{ .claim = file(500, 99), .chain = .{ .outcome = .strayed } },
        .{ .claim = file(500, 5), .chain = .{ .length = 3, .last = 7, .outcome = .strayed } },
        .{ .claim = file(150, 5), .chain = .{ .length = 4, .last = 8, .cut_after = 6 } },
        .{ .claim = file(0, 5), .chain = .{ .length = 3, .last = 7 } },
        .{ .claim = file(500, 5), .chain = .{ .length = 2, .last = 6 } },
        .{ .claim = file(500, 5), .chain = .{ .length = 2, .last = 6, .outcome = .crossed } },
    };

    for (cases) |case| reached.insert(tagOf(decide(case.claim, case.chain)));
    try testing.expectEqual(std.meta.fields(Verdict).len, reached.count());
}
