//! A bounded channel built directly on the std.Io futex vtable primitives
//! (`futexWait`/`futexWake`), deliberately avoiding std.Io.Condition.
//!
//! std.Io.Queue already does direct sender->receiver handoff, but it layers a
//! per-waiter std.Io.Condition (a waiters/signals epoch state machine) on top of
//! the futex, plus a cancelable Mutex.lock per operation. This implementation
//! keeps only what's essential:
//!
//!   * a Mutex for the ring buffer + intrusive waiter lists (uncontended = 1 CAS),
//!   * one `u32` futex word per *blocked* waiter, flipped 0->1 to wake exactly
//!     that waiter (no epoch, no signal counting, no broadcast),
//!   * direct byte handoff into the peer's stack buffer.
//!
//! Like std.Io.Queue and zio's native Channel, the core is type-erased (operates
//! on raw bytes + elem_size) so `FutexChannel(T)` stays a thin typed shell and
//! doesn't bloat the binary per element type.
//!
//! Because it only touches the futex vtable, it is portable across every std.Io
//! backend (zio single/multi-threaded, std.Io.Threaded, ...).
//!
//! Lifetime note: a waiter's futex word lives on its own stack frame. The waker
//! flips the word and calls `futexWake` *while holding the mutex*, and a woken
//! waiter re-acquires the mutex before returning. That serialization guarantees
//! `futexWake` has finished touching the word before the waiter's frame dies —
//! the same trick std.Io.Queue relies on via its `defer mutex.lock`.

const std = @import("std");
const Io = std.Io;

pub const Closed = error{Closed};

const Waiter = struct {
    node: std.DoublyLinkedList.Node = .{},
    /// 0 = parked, 1 = woken. The futex word.
    futex: std.atomic.Value(u32) = .init(0),
    /// Sender: source of the item to send. Receiver: destination for the item.
    data_ptr: [*]u8,
    /// true  = value was handed off (send/receive succeeded),
    /// false = woken by close (return error.Closed).
    done: bool = false,
    /// Still linked in a waiter list (used to resolve the cancel race).
    queued: bool = true,
};

/// Type-erased core shared by all `FutexChannel(T)` instances.
pub const FutexChannelImpl = struct {
    buffer: [*]u8,
    elem_size: usize,
    capacity: usize, // in elements
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    closed: bool = false,

    mutex: Io.Mutex = .init,
    senders: std.DoublyLinkedList = .{},
    receivers: std.DoublyLinkedList = .{},

    fn elemPtr(self: *FutexChannelImpl, index: usize) [*]u8 {
        return self.buffer + index * self.elem_size;
    }

    /// Flip the waiter's futex word and wake it. MUST be called while holding
    /// the mutex (see the lifetime note at the top of the file).
    fn wake(io: Io, w: *Waiter) void {
        w.futex.store(1, .release);
        io.futexWake(u32, &w.futex.raw, 1);
    }

    /// Suspend until this waiter is woken (`futex` becomes 1) or the wait is
    /// canceled. `queue` is the list `w` is currently linked into.
    fn park(self: *FutexChannelImpl, io: Io, w: *Waiter, queue: *std.DoublyLinkedList) Io.Cancelable!void {
        while (w.futex.load(.acquire) == 0) {
            io.futexWait(u32, &w.futex.raw, 0) catch |err| {
                // Cancel requested. Under the lock, decide who won the race.
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                if (w.queued) {
                    // Not yet claimed by a peer: unlink and report cancellation.
                    queue.remove(&w.node);
                    w.queued = false;
                    return err;
                }
                // A peer already claimed us under the lock and set `futex` before
                // releasing it, so the handoff completed — cancel lost the race.
                return;
            };
        }
        // Woken normally. Serialize with the waker (which called futexWake under
        // the mutex) before our stack frame — and `w` — disappears.
        self.mutex.lockUncancelable(io);
        self.mutex.unlock(io);
    }

    pub fn send(self: *FutexChannelImpl, io: Io, item_ptr: [*]const u8) (Closed || Io.Cancelable)!void {
        try self.mutex.lock(io);

        if (self.closed) {
            self.mutex.unlock(io);
            return error.Closed;
        }

        // Direct handoff into a waiting receiver's buffer.
        if (self.receivers.popFirst()) |node| {
            const r: *Waiter = @fieldParentPtr("node", node);
            @memcpy(r.data_ptr[0..self.elem_size], item_ptr[0..self.elem_size]);
            r.done = true;
            r.queued = false;
            wake(io, r);
            self.mutex.unlock(io);
            return;
        }

        // Otherwise buffer it if there is room.
        if (self.count < self.capacity) {
            @memcpy(self.elemPtr(self.tail)[0..self.elem_size], item_ptr[0..self.elem_size]);
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
            self.mutex.unlock(io);
            return;
        }

        // Full: block as a sender.
        var w: Waiter = .{ .data_ptr = @constCast(item_ptr) };
        self.senders.append(&w.node);
        self.mutex.unlock(io);

        try self.park(io, &w, &self.senders);
        return if (w.done) {} else error.Closed;
    }

    pub fn receive(self: *FutexChannelImpl, io: Io, result_ptr: [*]u8) (Closed || Io.Cancelable)!void {
        try self.mutex.lock(io);

        // Buffered item available.
        if (self.count > 0) {
            @memcpy(result_ptr[0..self.elem_size], self.elemPtr(self.head)[0..self.elem_size]);
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
            // A blocked sender can now move its item into the slot we freed.
            if (self.senders.popFirst()) |node| {
                const s: *Waiter = @fieldParentPtr("node", node);
                @memcpy(self.elemPtr(self.tail)[0..self.elem_size], s.data_ptr[0..self.elem_size]);
                self.tail = (self.tail + 1) % self.capacity;
                self.count += 1;
                s.done = true;
                s.queued = false;
                wake(io, s);
            }
            self.mutex.unlock(io);
            return;
        }

        // No buffer contents; take directly from a waiting sender.
        if (self.senders.popFirst()) |node| {
            const s: *Waiter = @fieldParentPtr("node", node);
            @memcpy(result_ptr[0..self.elem_size], s.data_ptr[0..self.elem_size]);
            s.done = true;
            s.queued = false;
            wake(io, s);
            self.mutex.unlock(io);
            return;
        }

        if (self.closed) {
            self.mutex.unlock(io);
            return error.Closed;
        }

        // Empty: block as a receiver.
        var w: Waiter = .{ .data_ptr = result_ptr };
        self.receivers.append(&w.node);
        self.mutex.unlock(io);

        try self.park(io, &w, &self.receivers);
        return if (w.done) {} else error.Closed;
    }

    pub fn close(self: *FutexChannelImpl, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return;
        self.closed = true;
        while (self.receivers.popFirst()) |node| {
            const r: *Waiter = @fieldParentPtr("node", node);
            r.done = false;
            r.queued = false;
            wake(io, r);
        }
        while (self.senders.popFirst()) |node| {
            const s: *Waiter = @fieldParentPtr("node", node);
            s.done = false;
            s.queued = false;
            wake(io, s);
        }
    }
};

/// Thin typed shell over `FutexChannelImpl`.
pub fn FutexChannel(comptime T: type) type {
    return struct {
        impl: FutexChannelImpl,

        const Self = @This();

        /// Buffer length is the channel capacity. Empty buffer = unbuffered.
        pub fn init(buffer: []T) Self {
            return .{ .impl = .{
                .buffer = std.mem.sliceAsBytes(buffer).ptr,
                .elem_size = @sizeOf(T),
                .capacity = buffer.len,
            } };
        }

        pub fn send(self: *Self, io: Io, item: T) (Closed || Io.Cancelable)!void {
            var value = item;
            return self.impl.send(io, std.mem.asBytes(&value).ptr);
        }

        pub fn receive(self: *Self, io: Io) (Closed || Io.Cancelable)!T {
            var result: T = undefined;
            try self.impl.receive(io, std.mem.asBytes(&result).ptr);
            return result;
        }

        pub fn close(self: *Self, io: Io) void {
            self.impl.close(io);
        }
    };
}
