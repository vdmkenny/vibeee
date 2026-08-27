//! What a line of system output means, so it can be coloured for it.
//!
//! Shared because the boot log and the tools that show the same information
//! later are one voice: `log` printing what the kernel said should look like
//! the kernel saying it, and `devices` should look like the probe it repeats.
//! A tool that picked its own colours would be a second scheme, and two
//! schemes on one screen read as neither.
//!
//! Roles rather than colours, because the two sides do not encode colour the
//! same way: the console has the VGA palette's ordering and a terminal has the
//! ANSI one. What is shared is which role a thing has; each side spells it.

pub const Role = enum {
    /// The key column: what this line is about. The word the eye scans for.
    key,
    /// The ordinary text of a line.
    value,
    /// It worked, or this is the one in use.
    good,
    /// Worth looking at, but the system carried on.
    warn,
    /// It failed.
    bad,
    /// Present and not important: a detail the eye should be able to skip.
    dim,
};
