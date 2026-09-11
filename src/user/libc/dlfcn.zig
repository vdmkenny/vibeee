//! What a program asks for when it wants another program mapped into itself.
//!
//! There is none of that here: every program is one static image, there is no
//! dynamic loader, and nothing is mapped but the file a program reads. So
//! `dlopen` answers nothing and `dlerror` says why, which is how a script
//! asking for a module written in C finds out that it cannot have one
//! instead of the program that ran it stopping.

export fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque {
    _ = filename;
    _ = flags;
    return null;
}

export fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque {
    _ = handle;
    _ = name;
    return null;
}

export fn dlclose(handle: ?*anyopaque) c_int {
    _ = handle;
    return -1;
}

export fn dlerror() ?[*:0]const u8 {
    return "shared objects: this system maps none";
}
