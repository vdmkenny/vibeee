//! The sizes this system has chosen for itself.
//!
//! A limit here is not a guess at what is enough: it is a budget. The machine
//! has 512 MB and a 630 MHz core, and every buffer sized "generously" is
//! memory a program cannot have. So a limit is set close enough to what is
//! actually needed that outgrowing it is an event.
//!
//! When one is reached, the first question is whether the thing that grew
//! should have: a table with room for nine services does not need a
//! sixteen-kilobyte buffer, it needs a file that is mostly not prose. Only
//! when the growth is real does the number double, and the comment says which
//! wall was hit. The build measures the shipped files against these, so
//! outgrowing one is a build that fails naming the file rather than a machine
//! that quietly starts fewer services than its table declares.

/// The service table, read in one go by init.
///
/// Doubled once from four kilobytes, which the shipped table outgrew at nine
/// services: the file is mostly the comments that say why each service exists
/// and where it sits in the boot, and those are worth their bytes on a
/// machine whose only documentation is on the machine. Eight leaves room for
/// a few more without inviting a file nobody reads.
pub const SERVICES_FILE_MAX = 8 * 1024;

/// How many services init will run. Nine ship; the rest is room for a machine
/// that adds its own. Each costs a process, its address space and its
/// surfaces, so this is a budget rather than a maximum anybody should reach.
pub const MAX_SERVICES = 12;
