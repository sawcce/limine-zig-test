const std = @import("std");

pub const VirtAddr = packed struct {
    value: u64,

    /// Tries to create a new canonical virtual address.
    ///
    /// If required this function performs sign extension of bit 47 to make the address canonical.
    pub fn init(addr: u64) error{VirtAddrNotValid}!VirtAddr {
        return switch (bitjuggle.getBits(addr, 47, 17)) {
            0, 0x1ffff => VirtAddr{ .value = addr },
            1 => initTruncate(addr),
            else => return error.VirtAddrNotValid,
        };
    }

    /// Creates a new canonical virtual address.
    ///
    /// If required this function performs sign extension of bit 47 to make the address canonical.
    ///
    /// ## Panics
    /// This function panics if the bits in the range 48 to 64 contain data (i.e. are not null and no sign extension).
    pub fn initPanic(addr: u64) VirtAddr {
        return init(addr) catch @panic("address passed to VirtAddr.init_panic must not contain any data in bits 48 to 64");
    }

    /// Creates a new canonical virtual address, throwing out bits 48..64.
    ///
    /// If required this function performs sign extension of bit 47 to make the address canonical.
    pub fn initTruncate(addr: u64) VirtAddr {
        // By doing the right shift as a signed operation (on a i64), it will
        // sign extend the value, repeating the leftmost bit.

        // Split into individual ops:
        // const no_high_bits = addr << 16;
        // const as_i64 = @bitCast(i64, no_high_bits);
        // const sign_extend_high_bits = as_i64 >> 16;
        // const value = @bitCast(u64, sign_extend_high_bits);
        return VirtAddr{ .value = @bitCast(u64, @bitCast(i64, (addr << 16)) >> 16) };
    }

    /// Creates a new virtual address, without any checks.
    pub fn initUnchecked(addr: u64) VirtAddr {
        return .{ .value = addr };
    }

    /// Creates a virtual address that points to `0`.
    pub fn zero() VirtAddr {
        return .{ .value = 0 };
    }

    /// Convenience method for checking if a virtual address is null.
    pub fn isNull(self: VirtAddr) bool {
        return self.value == 0;
    }

    /// Creates a virtual address from the given pointer
    /// Panics if the given pointer is not a valid virtual address, this should never happen in reality
    pub fn fromPtr(ptr: anytype) VirtAddr {
        comptime if (@typeInfo(@TypeOf(ptr)) != .Pointer) @compileError("not a pointer");
        return initPanic(@ptrToInt(ptr));
    }

    /// Converts the address to a pointer.
    pub fn toPtr(self: VirtAddr, comptime T: type) T {
        return @intToPtr(T, self.value);
    }

    /// Aligns the virtual address upwards to the given alignment.
    /// The alignment must be a power of 2 and greater than 0.
    pub fn alignUp(self: VirtAddr, alignment: usize) VirtAddr {
        return .{ .value = std.mem.alignForward(self.value, alignment) };
    }

    /// Aligns the virtual address downwards to the given alignment.
    /// The alignment must be a power of 2 and greater than 0.
    pub fn alignDown(self: VirtAddr, alignment: usize) VirtAddr {
        return .{ .value = std.mem.alignBackward(self.value, alignment) };
    }

    /// Checks whether the virtual address has the given alignment.
    /// The alignment must be a power of 2 and greater than 0.
    pub fn isAligned(self: VirtAddr, alignment: usize) bool {
        return std.mem.isAligned(self.value, alignment);
    }

    /// Returns the 12-bit page offset of this virtual address.
    pub fn pageOffset(self: VirtAddr) PageOffset {
        return PageOffset.init(@truncate(u12, self.value));
    }

    /// Returns the 9-bit level 1 page table index.
    pub fn p1Index(self: VirtAddr) PageTableIndex {
        return PageTableIndex.init(@truncate(u9, self.value >> 12));
    }

    /// Returns the 9-bit level 2 page table index.
    pub fn p2Index(self: VirtAddr) PageTableIndex {
        return PageTableIndex.init(@truncate(u9, self.value >> 21));
    }

    /// Returns the 9-bit level 3 page table index.
    pub fn p3Index(self: VirtAddr) PageTableIndex {
        return PageTableIndex.init(@truncate(u9, self.value >> 30));
    }

    /// Returns the 9-bit level 4 page table index.
    pub fn p4Index(self: VirtAddr) PageTableIndex {
        return PageTableIndex.init(@truncate(u9, self.value >> 39));
    }

    /// Returns the 9-bit level page table index.
    pub fn pageTableIndex(self: VirtAddr, level: PageTableLevel) PageTableIndex {
        return PageTableIndex.init(@truncate(u9, self.value >> 12 >> ((@enumToInt(level) - 1) * 9)));
    }

    pub fn format(value: VirtAddr, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("VirtAddr(0x{x})", .{value.value});
    }

    test {
        std.testing.refAllDecls(@This());
        try std.testing.expectEqual(@bitSizeOf(u64), @bitSizeOf(VirtAddr));
        try std.testing.expectEqual(@sizeOf(u64), @sizeOf(VirtAddr));
    }
};
