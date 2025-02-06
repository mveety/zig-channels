const std = @import("std");

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

        pub fn send(self: *Self, data: T) !void {
            if (self.closed) return error.ChannelClosed;
            self.sendlock.lock();
            defer self.sendlock.unlock();
            self.buffer = data;
            self.full = true;
            self.recvsem.post();
            if (self.mselectsem) |selectsem|
                selectsem.post();
            if (self.closed) return error.ChannelClosed;
            self.sendsem.wait();
        }

        pub fn recv(self: *Self) !T {
            if (self.closed) return error.ChannelClosed;
            self.recvlock.lock();
            defer self.recvlock.unlock();
            self.recvsem.wait();
            if (self.closed) return error.ChannelClosed;
            const data = self.buffer;
            self.buffer = undefined;
            self.full = false;
            self.sendsem.post();
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
                lock: std.Thread.Mutex,
                sem: std.Thread.Semaphore,
                chans: [N]?*Self,
                n: usize,

                pub fn select(selself: *SelSelf) !*Self {
                    if (selself.n == 0) return error.SelectEmpty;
                    selself.lock.lock();
                    defer selself.lock.unlock();
                    while (true) {
                        for (selself.chans) |mchan| {
                            if (mchan) |chan| {
                                if (chan.closed) return error.ChannelClosed;
                                if (chan.canRecv()) return chan;
                            }
                        }
                        selself.sem.wait();
                    }
                }

                pub fn add(selself: *SelSelf, chan: *Self) !void {
                    selself.lock.lock();
                    defer selself.lock.unlock();
                    for (0..selself.chans.len) |i| {
                        if (selself.chans[i] != null) continue;
                        selself.chans[i] = chan;
                        chan.mselectsem = &selself.sem;
                        selself.n += 1;
                        return;
                    }
                    return error.SelectFull;
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

fn testproc3(c: *TestChan) void {
    std.debug.print("recv thread start\n", .{});
    const res = c.recv() catch unreachable;
    std.debug.print("thread got {}\n", .{res});
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

    try select.add(&chan);
    const t1 = try std.Thread.spawn(.{}, testproc2, .{&chan});

    var c = try select.select();
    const res = try c.recv();
    std.debug.print("main select thread got {}\n", .{res});
    t1.join();
}
