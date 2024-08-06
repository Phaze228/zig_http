const std = @import("std");
const fs = std.fs;
const Dir = std.fs.Dir;
const Method = @import("http_methods.zig").Method;
const Status = @import("http_status.zig").Status;
const Allocator = std.mem.Allocator;
const RequestMap = std.AutoHashMap(RequestHeader, []const u8);

const HTTP_HEAD =
    "{s} {s}\r\n" ++
    "Connection: close\r\n" ++
    "Content-Type: {s}\r\n" ++
    "Content-Length: {}\r\n" ++
    "\r\n";

const Version = enum {
    @"HTTP/1.0",
    @"HTTP/1.1",
    @"HTTP/1.2",
    @"HTTP/2.0",
    @"HTTP/3.0",

    pub fn format(self: Version, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(@tagName(self));
    }
};

const mimes = std.ComptimeStringMap([]const u8, .{
    .{ ".html", "text/html" },
    .{ ".txt", "text/html" },
    .{ ".css", "text/css" },
    .{ ".map", "application/json" },
    .{ ".svg", "image/svg+xml" },
    .{ ".jpg", "image/jpg" },
    .{ ".png", "image/png" },
});

pub fn apiEcho(request: *Request, connection: *std.net.Server.Connection, _: WebServer) anyerror!void {
    var splits = std.mem.tokenizeScalar(u8, request.route, '/');
    _ = splits.next() orelse "";
    const to_echo = splits.next() orelse "";
    const mime = mimes.get(".txt").?;
    const writer = connection.stream.writer();
    try writer.print(HTTP_HEAD, .{ request.version, Status.OK, mime, to_echo.len });
    try writer.writeAll(to_echo);
}

const ECHO = API{ .path = "/echo", .action = @constCast(&apiEcho) };

pub const API_LIST = [_]API{
    ECHO,
};

pub const API = struct {
    const ActionFunction = *fn (self: *Request, connection: *std.net.Server.Connection, server: WebServer) anyerror!void;
    path: []const u8,
    action: ActionFunction,
};

pub const Request = struct {
    const Self = @This();
    allocator: Allocator,
    method: Method,
    version: Version,
    header: RequestMap,
    route: []const u8,

    pub fn parse(request_text: []const u8, allocator: Allocator) !Self {
        var map = RequestMap.init(allocator);
        var hdr_itr = std.mem.tokenizeSequence(u8, request_text, "\r\n");
        const initial_request = hdr_itr.next() orelse return error.EmptyRequest;
        var req_iter = std.mem.tokenizeScalar(u8, initial_request, ' ');
        const method_str = req_iter.next() orelse return error.InvalidRequest;
        const path_str = req_iter.next() orelse return error.InvalidRequest;
        const version_str = req_iter.next() orelse return error.InvalidRequest;
        // std.debug.print("{s} {s} {s}\n", .{ method_str, path_str, version_str });

        while (hdr_itr.next()) |section| {
            var sec_itr = std.mem.tokenizeSequence(u8, section, ": ");
            const key_str = sec_itr.next() orelse "";
            const value = sec_itr.next() orelse "";
            if (key_str.len == 0) continue;
            var buf: [4096]u8 = undefined;
            toLower(key_str, &buf);
            errdefer {
                var itr = map.iterator();
                while (itr.next()) |entry| {
                    allocator.free(entry.value_ptr.*);
                }

                map.deinit();
            }
            // // std.debug.print("Key: {s} || Value: {s}\n", .{ &buf, value });
            const key = std.meta.stringToEnum(RequestHeader, buf[0..key_str.len]) orelse return error.InvalidHeaderField;
            const trimmed_value = std.mem.trim(u8, value, " ");
            const copied = try allocator.dupe(u8, trimmed_value);

            try map.put(key, copied);
        }
        return Self{
            .allocator = allocator,
            .method = std.meta.stringToEnum(Method, method_str) orelse return error.InvalidRequest,
            .version = std.meta.stringToEnum(Version, version_str) orelse return error.InvalidVersion,
            .route = path_str,
            .header = map,
        };
    }

    pub fn deinit(self: *Self) void {
        var itr = self.header.iterator();
        while (itr.next()) |entry| {
            // std.debug.print("{s}\n", .{entry.value_ptr.*});
            self.allocator.free(entry.value_ptr.*);
        }
        self.header.deinit();
    }

    pub fn handle(self: *Self, connection: *std.net.Server.Connection, server: WebServer) !void {
        switch (self.method) {
            .GET => try self.handleGet(connection, server),
            else => return,
        }
    }

    fn handleGet(self: *Self, connection: *std.net.Server.Connection, server: WebServer) !void {
        for (API_LIST) |api| {
            if (std.mem.startsWith(u8, self.route, api.path)) {
                try api.action(self, connection, server);
                return;
            }
        }
        var buf: [8096]u8 = undefined;
        const content = try server.get(self.route);
        const reader = content.file.reader();
        const bytes = try reader.readAll(&buf);
        const writer = connection.stream.writer();
        try writer.print(HTTP_HEAD, .{ self.version, content.status, content.kind, bytes });
        try writer.writeAll(buf[0..bytes]);
    }
};

pub fn toLower(string: []const u8, buf: []u8) void {
    for (0..string.len) |i| {
        buf[i] = std.ascii.toLower(string[i]);
    }
}

pub const WebServer = struct {
    const Self = @This();
    dir: Dir,

    pub fn init(path: ?[]const u8) !Self {
        if (path) |p| {
            return WebServer{ .dir = try fs.openDirAbsolute(p, .{ .iterate = true }) };
        }
        return WebServer{ .dir = try fs.cwd().openDir(".", .{ .iterate = true }) };
    }

    pub fn get(self: *const Self, file_name: []const u8) !Content {
        var file_iter = self.dir.iterate();
        while (try file_iter.next()) |entry| {
            if (std.mem.containsAtLeast(u8, file_name, 1, entry.name)) {
                if (entry.kind != .file) continue;
                const file_type = mimes.get(fs.path.extension(entry.name)) orelse continue;
                return try Content.init(self.dir, entry.name, file_type);
            }
        }
        return try Content.init(self.dir, null, ".html");
    }
};

pub const Content = struct {
    const Self = @This();
    file: fs.File,
    kind: []const u8,
    status: Status,

    pub fn init(dir: Dir, name: ?[]const u8, file_type: []const u8) !Self {
        const file_name = name orelse "not_found.html";
        const file = try dir.openFile(file_name, .{});

        if (name == null) {
            return Self{
                .file = file,
                .kind = file_type,
                .status = .@"Not Found",
            };
        }
        return Self{
            .file = file,
            .kind = file_type,
            .status = .OK,
        };
    }
};

pub const RequestHeader = enum {
    accept,
    @"accept-charset",
    @"accept-encoding",
    @"accept-language",
    @"accept-ranges",
    age,
    allow,
    authorization,
    @"cache-control",
    connection,
    @"content-encoding",
    @"content-language",
    @"content-length",
    @"content-location",
    @"content-md5",
    @"content-range",
    @"content-type",
    date,
    etag,
    expect,
    expires,
    from,
    host,
    @"if-match",
    @"if-modified-since",
    @"if-none-match",
    @"if-range",
    @"if-unmodified-since",
    @"last-modified",
    location,
    @"max-forwards",
    pragma,
    @"proxy-authenticate",
    @"proxy-authorization",
    range,
    referer,
    @"retry-after",
    server,
    TE,
    trailer,
    @"transfer-encoding",
    upgrade,
    @"user-agent",
    vary,
    via,
    warning,
    @"www-authenticate",
};
