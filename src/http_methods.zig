const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    OPTIONS,
    HEAD,
    DELETE,
    TRACE,
    CONNECT,

    fn parse(header: []const u8) Method {
        return std.meta.stringToEnum(Method, header) orelse .GET;
    }

    pub fn format(self: *Method, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) void {
        try writer.writeAll(@tagName(self));
    }
};
