const std = @import("std");
const log = std.log;
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const Client = struct {
    const Self = @This();

    epfd: i32,
    c: std.net.Server.Connection,
    ev: linux.epoll_event,
    wfifo: std.fifo.LinearFifo(u8, .Dynamic),
    rbuf: [2048]u8,
    // wbuf: [2048]u8,
    // wlen: usize,

    pub fn init(allocator: Allocator, epfd: i32, conn: std.net.Server.Connection, ev: linux.epoll_event) !Self {
        return .{
            .epfd = epfd,
            .c = conn,
            .ev = ev,
            .rbuf = undefined,
            .wfifo = std.fifo.LinearFifo(u8, .Dynamic).init(allocator),
            // .wbuf = undefined,
            // .wlen = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.wfifo.deinit();
        self.c.stream.close();
    }

    pub fn write(self: *Self, data: []const u8) !void {
        var sum: usize = 0;
        var send_buf_size = data.len;

        while (send_buf_size > 0) {
            const n = self.c.stream.write(data) catch |err| switch (err) {
                error.WouldBlock => {
                    log.info("buffer is full", .{});
                    try self.wfifo.write(data[sum..]);
                    var ev: linux.epoll_event = .{
                        .events = linux.EPOLL.OUT | linux.EPOLL.IN | linux.EPOLL.ET,
                        .data = linux.epoll_data{ .fd = self.c.stream.handle },
                    };
                    try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, self.c.stream.handle, &ev);
                    return;
                },
                else => {
                    log.err("client {d} write data error. {?}", .{ self.c.stream.handle, err });
                    return;
                },
            };
            sum += n;
            log.info("write data {d} success", .{sum});
            send_buf_size -= n;
        }
    }

    pub fn epoll_write(self: *Self) !void {
        var ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = linux.epoll_data{ .fd = self.c.stream.handle },
        };
        try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, self.c.stream.handle, &ev);

        const data = self.wfifo.readableSlice(0);
        var sum: usize = 0;
        var send_buf_size = data.len;
        while (send_buf_size > 0) {
            const n = self.c.stream.write(data[sum..]) catch |err| switch (err) {
                error.WouldBlock => {
                    log.info("epoll write buffer is full", .{});
                    if (self.wfifo.readableLength() > 0) {
                        ev.events = linux.EPOLL.OUT | linux.EPOLL.IN | linux.EPOLL.ET;
                        try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, self.c.stream.handle, &ev);
                    }
                    return;
                },
                else => return err,
            };
            self.wfifo.discard(n);
            send_buf_size -= n;
            sum += n;
            log.info("epoll write len: {d}", .{n});
        }
    }
};
const host = "127.0.0.1";
const port = 8080;

const Server = struct {
    const max_size: comptime_int = 1024;
    const Self = @This();

    allocator: Allocator,
    clients: std.AutoHashMap(i32, Client),
    running: bool,

    pub fn init(allocator: Allocator) !Server {
        return Server{
            .allocator = allocator,
            .clients = std.AutoHashMap(i32, Client).init(allocator),
            .running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("server deinit: {d}", .{max_size});
        var it = self.*.clients.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deinit();
        }
        self.*.clients.deinit();
    }

    fn handle_server_event(self: *Self, epfd: i32, server: *std.net.Server, e: *const linux.epoll_event) !void {
        log.info("server event {d}", .{e.data.fd});
        if (e.events == linux.EPOLL.IN) {
            const connect = try server.accept();
            errdefer connect.stream.close();
            // 设置socket为非阻塞
            _ = try posix.fcntl(connect.stream.handle, posix.F.SETFL, posix.SOCK.NONBLOCK);

            const key = connect.stream.handle;
            try self.*.clients.put(key, try Client.init(self.allocator, epfd, connect, .{
                .events = linux.EPOLL.IN | linux.EPOLL.ET,
                .data = linux.epoll_data{ .fd = key },
            }));
            // try self.*.clients.put(key, .{
            //     .epfd = epfd,
            //     .c = connect,
            //     .ev = .{
            //         .events = linux.EPOLL.IN | linux.EPOLL.ET,
            //         .data = linux.epoll_data{ .fd = key },
            //     },
            //     .rbuf = undefined,
            //     .wbuf = undefined,
            //     .wlen = 0,
            // });
            errdefer _ = self.*.clients.remove(key);

            const client = self.*.clients.getPtr(connect.stream.handle);

            try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, connect.stream.handle, &client.?.*.ev);
            _ = std.Thread.spawn(.{}, write_hello, .{client.?}) catch |err| {
                log.err("failed to run write hello thread. {?}", .{err});
            };
            log.info("new connect {d}", .{connect.stream.handle});
        } else {
            log.err("unknown type: {d}", .{e.events});
        }
    }

    fn handle_client_event(self: *Self, _: i32, e: *const linux.epoll_event) !void {
        if (self.clients.getPtr(e.data.fd)) |client| {
            if (e.events & linux.EPOLL.IN > 0) {
                log.info("client read event: {d}", .{e.data.fd});
                while (true) {
                    if (client.c.stream.read(&client.rbuf)) |n| {
                        if (n == 0) {
                            log.info("read data len is 0", .{});
                            defer {
                                client.c.stream.close();
                                _ = self.clients.remove(e.data.fd);
                            }
                            break;
                        }
                        log.info("read data: {s}", .{client.rbuf[0..n]});
                    } else |err| switch (err) {
                        error.WouldBlock => break,
                        else => {
                            log.err("failed to read data: {?}", .{err});
                            break;
                        },
                    }
                }
            }

            if (e.events & linux.EPOLL.OUT > 0) {
                log.info("client write event: {d}", .{e.data.fd});
                client.epoll_write() catch |err| {
                    log.err("failed to write data: {?}", .{err});
                    _ = self.*.clients.remove(e.data.fd);
                    return;
                };
                log.info("epoll write data success", .{});
            }
        }
    }

    pub fn run_server(self: *Self) void {
        const epfd = posix.epoll_create1(0) catch |err| {
            log.err("failed to create epoll fd: {?}", .{err});
            return;
        };
        defer posix.close(epfd);

        log.info("epfd: {d}", .{epfd});
        const address = std.net.Address.parseIp(host, port) catch |err| {
            log.err("failed to parse address. addr: {s}:{d}, error: {?}", .{ host, port, err });
            return;
        };

        var server = address.listen(.{ .reuse_port = true }) catch |err| {
            log.err("failed to listen address: {?}", .{err});
            return;
        };
        defer server.deinit();

        const listen_fd = server.stream.handle;
        log.info("listen: {d} {s}:{d}", .{ listen_fd, host, port });
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = linux.epoll_data{ .fd = server.stream.handle },
        };
        posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listen_fd, &ev) catch |err| {
            log.err("failed to add listen_fd: {?}", .{err});
            return;
        };

        var events: [max_size]linux.epoll_event = undefined;
        var events_count: usize = 0;

        self.running = true;
        while (self.running) {
            events_count = posix.epoll_wait(epfd, events[0..max_size], -1);
            for (events[0..events_count]) |e| {
                if (e.data.fd == server.stream.handle) { // 服务端监听服务fd
                    self.*.handle_server_event(epfd, &server, &e) catch |err| {
                        log.err("failed to handle server event{?}", .{err});
                    };
                } else { // 客户端连接fd
                    self.*.handle_client_event(epfd, &e) catch |err| {
                        log.err("failed to handle client event{?}", .{err});
                    };
                }
            }
        }
    }

    pub fn stop_server(self: *Self) void {
        self.running = false;
    }
};

fn write_hello(client: *Client) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const gpa_deinit_status = gpa.deinit();
        if (gpa_deinit_status == .leak) @panic("TEST FAIL");
    }
    const data = allocator.alloc(u8, 204800000) catch |err| {
        log.err("failed to create write data. {?}", .{err});
        return;
    };
    defer allocator.free(data);

    std.time.sleep(std.time.ns_per_s * 1);
    client.write(data) catch |err| {
        log.err("write hello error. {?}", .{err});
    };
}

fn stop_server(server: *Server) void {
    log.info("run stop server thread", .{});
    std.time.sleep(std.time.ns_per_min * 30);
    server.stop_server();
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const gpa_deinit_status = gpa.deinit();
        if (gpa_deinit_status == .leak) @panic("TEST FAIL");
    }

    var server = Server.init(allocator) catch |err| {
        log.err("failed to init server: {?}", .{err});
        return;
    };
    defer server.deinit();

    _ = std.Thread.spawn(.{}, stop_server, .{&server}) catch |err| {
        log.err("failed to run stop server thread. {?}", .{err});
    };

    server.run_server();
}
