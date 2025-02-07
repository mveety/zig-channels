const std = @import("std");

pub const ChannelError = error{
    ChannelClosed,
    SelectEmpty,
    SelectFull,
};

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        closed: bool,
        buffer: T,
        full: bool,
        sendlock: std.Thread.Mutex,
        sendsem: std.Thread.Semaphore,
        recvlock: std.Thread.Mutex,
        recvsem: std.Thread.Semaphore,
        mselectsem: ?*std.Thread.Semaphore,

        pub fn send(self: *Self, data: T) ChannelError!void {
            if (self.closed) return ChannelError.ChannelClosed;
            self.sendlock.lock();
            defer self.sendlock.unlock();
            if (self.closed) return ChannelError.ChannelClosed;
            self.buffer = data;
            self.full = true;
            self.recvsem.post();
            if (self.mselectsem) |selectsem|
                selectsem.post();
            if (self.closed) return ChannelError.ChannelClosed;
            self.sendsem.wait();
            if (self.closed) return ChannelError.ChannelClosed;
        }

        pub fn recv(self: *Self) ChannelError!T {
            if (self.closed) return ChannelError.ChannelClosed;
            self.recvlock.lock();
            defer self.recvlock.unlock();
            if (self.closed) return ChannelError.ChannelClosed;
            self.recvsem.wait();
            const data = self.buffer;
            self.buffer = undefined;
            self.full = false;
            self.sendsem.post();
            if (self.closed) return ChannelError.ChannelClosed;
            return data;
        }

        pub fn canRecv(self: *Self) bool {
            if (self.closed) return false;
            return self.full;
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.recvsem.post();
            self.sendsem.post();
            if (self.mselectsem) |selectsem|
                selectsem.post();
        }

        pub fn init() Self {
            return .{
                .closed = false,
                .buffer = undefined,
                .full = false,
                .sendlock = std.Thread.Mutex{},
                .sendsem = std.Thread.Semaphore{},
                .recvlock = std.Thread.Mutex{},
                .recvsem = std.Thread.Semaphore{},
                .mselectsem = null,
            };
        }

        pub fn Select(comptime N: usize) type {
            return struct {
                const SelSelf = @This();
                const SelectResult = struct {
                    channel: *Self,
                    index: usize,
                };
                lock: std.Thread.Mutex,
                sem: std.Thread.Semaphore,
                chans: [N]?*Self,
                n: usize,

                pub fn select(selself: *SelSelf) ChannelError!SelectResult {
                    if (selself.n == 0) return ChannelError.SelectEmpty;
                    selself.lock.lock();
                    defer selself.lock.unlock();
                    while (true) {
                        for (selself.chans, 0..) |mchan, idx| {
                            if (mchan) |chan| {
                                if (chan.closed) return ChannelError.ChannelClosed;
                                if (chan.canRecv()) return .{ .channel = chan, .index = idx };
                            }
                        }
                        selself.sem.wait();
                    }
                }

                pub fn selectRecv(selself: *SelSelf) ChannelError!T {
                    const sr = try selself.select();
                    return sr.channel.recv();
                }

                pub fn add(selself: *SelSelf, chan: *Self) ChannelError!usize {
                    selself.lock.lock();
                    defer selself.lock.unlock();
                    for (0..selself.chans.len) |i| {
                        if (selself.chans[i] != null) continue;
                        selself.chans[i] = chan;
                        chan.mselectsem = &selself.sem;
                        selself.n += 1;
                        return i;
                    }
                    return ChannelError.SelectFull;
                }

                pub fn removeClosed(selself: *SelSelf) void {
                    selself.lock.lock();
                    defer selself.lock.unlock();
                    for (0..selself.chans.len) |i| {
                        if (selself.chans[i]) |chan| {
                            if (chan.closed) {
                                selself.n -= 1;
                                selself.chans[i] = null;
                                if (selself.n == 0) return;
                            }
                        }
                    }
                }

                pub fn init() SelSelf {
                    var nc: [N]?*Self = undefined;

                    for (0..N) |i| nc[i] = null;
                    return .{
                        .lock = std.Thread.Mutex{},
                        .sem = std.Thread.Semaphore{},
                        .chans = nc,
                        .n = 0,
                    };
                }
            };
        }
    };
}

const TestChan = Channel(i32);

fn testproc2(c: *TestChan) void {
    std.debug.print("chan thread start\n", .{});
    c.send(5) catch unreachable;
    std.debug.print("thread sent 5\n", .{});
}

test "basic channel test" {
    var chan = TestChan.init();
    var c = &chan;

    std.debug.print("main chan thread start\n", .{});
    const t1 = try std.Thread.spawn(.{}, testproc2, .{c});
    const res = try c.recv();
    std.debug.print("main chan thread got {}\n", .{res});
    t1.join();
}

fn testproc3(c: *TestChan) void {
    std.debug.print("recv thread start\n", .{});
    const res = c.recv() catch unreachable;
    std.debug.print("thread got {}\n", .{res});
}

test "complex channel test" {
    var chan = TestChan.init();

    std.debug.print("main sender thread start\n", .{});
    const t1 = try std.Thread.spawn(.{}, testproc3, .{&chan});
    const t2 = try std.Thread.spawn(.{}, testproc3, .{&chan});
    const t3 = try std.Thread.spawn(.{}, testproc3, .{&chan});
    try chan.send(1);
    try chan.send(2);
    try chan.send(3);
    t1.join();
    t2.join();
    t3.join();
}

test "select test" {
    var chan = TestChan.init();
    var select = TestChan.Select(1).init();

    std.debug.print("main sender thread start\n", .{});

    _ = try select.add(&chan);
    const t1 = try std.Thread.spawn(.{}, testproc2, .{&chan});

    var sr = try select.select();
    const res = try sr.channel.recv();
    std.debug.print("main select thread got {}\n", .{res});
    t1.join();
}

fn testproc4(threadn: usize, mainchan: *TestChan, mychan: *TestChan) void {
    std.debug.print("starting thread {}\n", .{threadn});

    while (mainchan.recv()) |res| {
        std.debug.print("thread {}: got {}\n", .{ threadn, res });
        mychan.send(res) catch {
            std.debug.print("thread {}: my channel closed\n", .{threadn});
            return;
        };
    } else |_| {
        std.debug.print("thread {}: main channel closed\n", .{threadn});
        return;
    }
}

fn selectTest(comptime nthreads: usize) !void {
    var mainchan = TestChan.init();
    var select = TestChan.Select(nthreads).init();
    var childchans: [nthreads]TestChan = undefined;
    var threads: [nthreads]std.Thread = undefined;

    std.debug.print("main thread start\n", .{});

    for (childchans, 0..) |_, i| {
        childchans[i] = TestChan.init();
        threads[i] = try std.Thread.spawn(.{}, testproc4, .{ i, &mainchan, &childchans[i] });
        _ = try select.add(&childchans[i]);
    }

    for (0..100) |i| {
        std.debug.print("main: sending {}\n", .{i});
        try mainchan.send(@intCast(i));
        var sr = try select.select();
        const res = try sr.channel.recv();
        std.debug.print("main: got {} from channel {}\n", .{ res, sr.index });
    }
    for (childchans, 0..) |_, i| childchans[i].close();
    mainchan.close();
    for (threads, 0..) |_, i| threads[i].join();
}

test "multi-thread select test 1" {
    try selectTest(2);
}

test "multi-thread select test 2" {
    try selectTest(4);
}

test "multi-thread select test 3" {
    try selectTest(7);
}
