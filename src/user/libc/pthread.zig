//! Locks and waits for a program that has one thread.
//!
//! Every program here is built single-threaded, so a mutex guards nothing
//! and a condition has no one to wait for: the calls succeed and do nothing,
//! which is what they mean where there is no second thread to contend with.
//! QuickJS reaches for them in its atomics, which is the one part of it that
//! presumes another thread; `Atomics.wait` answers at once here rather than
//! stopping a program nothing would ever wake.

export fn pthread_mutex_init(mutex: *c_int, attr: ?*anyopaque) c_int {
    _ = attr;
    mutex.* = 0;
    return 0;
}

export fn pthread_mutex_lock(mutex: *c_int) c_int {
    _ = mutex;
    return 0;
}

export fn pthread_mutex_unlock(mutex: *c_int) c_int {
    _ = mutex;
    return 0;
}

export fn pthread_mutex_destroy(mutex: *c_int) c_int {
    _ = mutex;
    return 0;
}

export fn pthread_cond_init(cond: *c_int, attr: ?*anyopaque) c_int {
    _ = attr;
    cond.* = 0;
    return 0;
}

/// Wakes at once: there is no other thread, so waiting would be waiting for
/// something that cannot happen.
export fn pthread_cond_wait(cond: *c_int, mutex: *c_int) c_int {
    _ = cond;
    _ = mutex;
    return 0;
}

export fn pthread_cond_signal(cond: *c_int) c_int {
    _ = cond;
    return 0;
}

export fn pthread_cond_broadcast(cond: *c_int) c_int {
    _ = cond;
    return 0;
}

/// Waits until a time, which is now: there is no other thread to wake this
/// one and nothing to keep it waiting, so a timed wait answers at once, the
/// way `pthread_cond_wait` does.
export fn pthread_cond_timedwait(cond: *c_int, mutex: *c_int, when: ?*anyopaque) c_int {
    _ = cond;
    _ = mutex;
    _ = when;
    return 0;
}

export fn pthread_cond_destroy(cond: *c_int) c_int {
    _ = cond;
    return 0;
}

/// No second thread can be made, and this system says so rather than
/// pretending: a program is one image with one stack.
export fn pthread_create(thread: *c_int, attr: ?*anyopaque, start: ?*anyopaque, arg: ?*anyopaque) c_int {
    _ = thread;
    _ = attr;
    _ = start;
    _ = arg;
    return 1;
}

export fn pthread_join(thread: c_int, value: ?*?*anyopaque) c_int {
    _ = thread;
    _ = value;
    return 1;
}
