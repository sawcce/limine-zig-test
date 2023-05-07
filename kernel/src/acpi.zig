const std = @import("std");
const debug_print = @import("main.zig").debug_print;

pub const RSDPDescriptor = extern struct {
    signature: [8]u8,
    checksum: u8,
    OEMID: [6]u8,
    revision: u8,
    rsdt_address: u32,
};

pub const RSDPDescriptor20 = extern struct {
    first_part: RSDPDescriptor,
    length: u32,
    Xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,

    pub fn doChecksum(self: *align(1) @This()) bool {
        const bytes = @ptrCast([*]const u8, self);
        var sum: u8 = 0;

        for (0..self.length) |i| {
            sum +%= bytes[i];
        }

        return sum == 0;
    }
};

pub const ACPISDTHeader = extern struct {
    signature: Signature align(1),
    length: u32,
    revision: u8,
    checksum: u8,
    OMEID: [6]u8,
    OEMTableID: [8]u8,
    OEMRevision: u32,
    creatorID: u32,
    creatorRevision: u32,

    pub fn doChecksum(self: *const @This()) bool {
        const bytes = @ptrCast([*]const u8, self);
        var sum: u8 = 0;

        for (0..self.length) |i| {
            sum +%= bytes[i];
        }

        return sum == 0;
    }

    pub fn into(self: *@This(), comptime dest: type) *dest {
        return @ptrCast(*dest, @alignCast(@alignOf(dest), self));
    }
};

pub const XSDT = extern struct {
    header: ACPISDTHeader,

    pub fn getEntriesAmount(self: *const @This()) usize {
        return (self.header.length - @sizeOf(ACPISDTHeader)) / 8;
    }

    pub fn getEntry(self: *const @This(), i: usize) *ACPISDTHeader {
        const addr = @intToPtr(*align(1) u64, @ptrToInt(self) + @sizeOf(ACPISDTHeader) + @sizeOf(u64) * i);
        return @intToPtr(*ACPISDTHeader, addr.*);
    }
};

pub const Signature = enum(u32) {
    APIC = @ptrCast(*align(1) const u32, "APIC").*,
    FACP = @ptrCast(*align(1) const u32, "FACP").*,
    HPET = @ptrCast(*align(1) const u32, "HPET").*,
    MCFG = @ptrCast(*align(1) const u32, "MCFG").*,
    WAET = @ptrCast(*align(1) const u32, "WAET").*,
    _,

    pub fn format(
        self: Signature,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll(@ptrCast(*const [4]u8, &self));
    }
};

const RecordHeader = packed struct(u16) {
    type: u8,
    length: u8,
};

pub const APIC = extern struct {
    header: ACPISDTHeader,
    localAddress: u32,
    flags: u32,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 0x2c);
    }

    pub const MADTFlags = packed struct(u32) {
        pcat_compatibility: bool,
        reserved: u31 = 0,
    };

    pub fn loopEntries(self: *const @This()) void {
        try debug_print("Self: {*}", .{self});
        var i: usize = @ptrToInt(self) + @sizeOf(APIC);
        const base = i;
        try debug_print("{}", .{i});

        while (i < base + self.header.length - @sizeOf(@This())) {
            const header = @intToPtr(*RecordHeader, i);
            try debug_print("{} | {}", .{ header.*, i });
            i += header.length;
        }
    }
};

pub const MCFG = extern struct { header: ACPISDTHeader, _: u64 align(4) };
