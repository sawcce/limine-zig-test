const std = @import("std");

pub const Config = packed struct {
    vendorID: u16,
    deviceID: u16,
    status: u16,
    command: u16,
    revisionID: u8,
    classCode: u24,
    cacheLineSize: u8,
    latency: u8,
    headerType: u8,
    bist: u8,
    bar0: u32,
    bar1: u32,
    bar2: u32,
    bar3: u32,
    bar4: u32,
    bar5: u32,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try std.fmt.format(writer, "PCI {{ vendor: 0x{x}, device: 0x{x}, class: 0x{x}, " ++
            "type: {}, bar0: {}}}", .{
            self.vendorID,
            self.deviceID,
            self.classCode,
            self.headerType,
            self.bar0,
        });
    }
};
