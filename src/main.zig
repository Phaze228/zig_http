const std = @import("std");
const net = std.net;
const log = std.log;
const Thread = std.Thread;
const Request = @import("http_requests.zig").Request;
const zttp = @import("http_requests.zig");

const ADDRESS = "127.0.0.1";
const PORT = 4221;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Maximum Thread Count: {d}", .{try Thread.getCpuCount()});

    const address = try net.Address.resolveIp(ADDRESS, PORT);
    var server = try zttp.WebServer.init(null);
    defer server.dir.close();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) log.err("-- MEMORY LEAK --\n", .{});
    }
    var thread_pool: Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator, .n_jobs = 10 });
    defer thread_pool.deinit();
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    try stdout.print("Accepting Connections: {s}:{d}\n", .{ ADDRESS, PORT });
    try stdout.print("Running {d} threads\n", .{thread_pool.threads.len});

    while (true) {
        const connection = listener.accept() catch |err| {
            log.err("Could not allow client connection! {any}\n", .{err});
            return;
        };
        try thread_pool.spawn(handle, .{ connection, server, allocator });
    }
}

pub fn handle(con: net.Server.Connection, webserver: zttp.WebServer, allocator: std.mem.Allocator) void {
    defer con.stream.close();
    var buffer: [4096]u8 = undefined;
    var connection = con;
    const request_size = connection.stream.read(&buffer) catch |err| {
        log.err("Error reading buf: {s} | {any} | \n", .{ buffer, err });
        return;
    };

    var req = Request.parse(buffer[0..request_size], allocator) catch |err| {
        log.err("Could not parse request! {any}\n", .{err});
        return;
    };

    log.info("Client: {any} - Path: {s}", .{ connection.address, req.route });
    defer req.deinit();

    req.handle(&connection, webserver) catch |err| {
        log.err("Could not process request! {any}\n", .{err});
        return;
    };
}
