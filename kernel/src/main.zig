const limine = @import("limine");
const std = @import("std");
const ports = @import("ports.zig");
const rtc_ = @import("rtc.zig");
const idt = @import("idt.zig");
const mem = @import("mem.zig");
const img = @import("zigimg");
const acpi = @import("acpi.zig");

const RTC = rtc_.RTC;
const Date = rtc_.Date;

const SerialPort = ports.SerialPort;
const Port = ports.Port;

// The Limine requests can be placed anywhere, but it is important that
// the compiler does not optimise them away, so, usually, they should
// be made volatile or equivalent. In Zig, `export var` is what we use.
// pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var info_request: limine.BootloaderInfoRequest = .{};
pub export var memory_map_request: limine.MemoryMapRequest = .{};
pub export var device_tree_request: limine.DeviceTreeBlobRequest = .{};
pub export var sys_table_request: limine.EfiSystemTableRequest = .{};
pub export var rsdp_request: limine.RsdpRequest = .{};
pub export var hhdm_req: limine.HhdmRequest = .{};

inline fn done() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

const serial_port = SerialPort.new(0x3F8);
var offset: u64 = undefined;

pub fn debug_print(comptime fmt: []const u8, args: anytype) !void {
    _ = try serial_port.write_message("[KERNEL] ");
    try std.fmt.format(serial_port.writer(), fmt, args);
    _ = try serial_port.write_message("\n");
}

fn getBits(number: u64, start: u64, end: u64) u64 {
    const mask = std.math.shl(u64, 1, end - start) - 1;
    // const mask = (@intCast(u64, 1) << (end - start)) - @intCast(u64, 1);
    return std.math.shr(u64, number, start) & mask;
}

const VirtAddr = packed struct(u64) {
    page_offset: u12,
    level1: u9,
    level2: u9,
    level3: u9,
    level4: u9,
    padding: u16,

    fn new(addr: u64) VirtAddr {
        return switch (getBits(addr, 47, 64)) {
            0, 0x1ffff => @ptrCast(*VirtAddr, @constCast(&addr)).*,
            1 => @ptrCast(*VirtAddr, @constCast(&@bitCast(u64, @bitCast(i64, addr << 16) >> 16))).*,
            else => {
                try debug_print("Invalid addr!!!!\n", .{});
                @panic("Tried to create invalid virtual address!");
            },
        };
    }
};

const ExperimentalAllocator = struct {
    size: usize = mem.page_size - @sizeOf(@This()),

    pub fn init() @This() {
        return .{};
    }

    pub fn allocator() !std.mem.Allocator {
        const page = try mem.allocate_new();

        return std.mem.Allocator{
            .ptr = page,
            .vtable = &std.mem.Allocator.VTable{
                .alloc = alloc_,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc_(ctx: *anyopaque, len: usize, ptr_align: u8, ret_address: usize) ?[*]u8 {
        debug_print("Alloc: {*}, {}, {}, {}", .{ ctx, len, ptr_align, ret_address }) catch {};
        return null;
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }
};

const Table = packed struct(u64) {
    present: bool,
    writable: bool,
    user_accesible: bool,
    wtc: bool,
    cache_disabled: bool,
    accessed: bool,
    dirty: bool,
    _: bool,
    global: bool,
    available: u3,
    phys_addr: u40,
    available2: u11,
    exec_forbidden: bool,

    fn next_physical_address(self: *align(1) @This(), index: u9) u64 {
        return @intCast(u64, self.phys_addr) * 4096 + offset + @intCast(u64, index) * 8;
    }

    fn read_next_table(self: *align(1) @This(), index: u9) *align(1) Table {
        // try debug_print("Getting: {}, for {}", .{ index, self });
        return @intToPtr(*align(1) Table, @intCast(u64, self.phys_addr) * 4096 + offset + @intCast(u64, index) * 8);
    }

    fn get_next_table(self: *@This()) *[512]Table {
        return @intToPtr(*[512]Table, @intCast(u64, self.phys_addr) * 4096 + offset);
    }
};

fn paging2(address: VirtAddr) ?*anyopaque {
    var cr3 = asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );

    var lpm4 = @intToPtr(*[512]Table, cr3 & 0x000f_ffff_ffff_f000);

    var addr = address;
    try debug_print("Address: 0b{b} 0x{x}", .{ @ptrCast(*u64, &addr).*, @ptrCast(*u64, &addr).* });
    try debug_print("Address: {}", .{addr});

    var table4 = lpm4.*[address.level4];
    var table3 = table4.get_pointer().*[address.level3];
    var table2 = table3.get_pointer().*[address.level2];
    var table1 = table2.get_pointer().*[address.level1];

    //const table3 = table4.read_next_table(address.level3);
    //const table2 = table3.read_next_table(address.level2);
    //const table1 = table2.read_next_table(address.level1);
    const entry = @intToPtr(*u64, table2.next_physical_address(address.level1));
    _ = entry;

    try debug_print("4: {}", .{table4});
    try debug_print("3: {}", .{table3});
    try debug_print("2: {}", .{table2});
    try debug_print("1: {any}", .{table1});
    try debug_print("Entry: 0x{x}", .{@intCast(u64, table2.phys_addr) * 4096});
    return @intToPtr(?*anyopaque, @intCast(u64, table1.phys_addr) * 4096 + @intCast(u64, address.page_offset) * 4096);
}

// The following will be our kernel's entry point.
export fn _start() callconv(.C) void {
    serial_port.init();

    idt.add_interrupt(3);
    idt.add_interrupt(13);

    idt.load();

    if (hhdm_req.response) |hhdm_res| {
        try debug_print("Offset: {x}", .{hhdm_res.offset});
        offset = hhdm_res.offset;
    }

    if (memory_map_request.response) |memory_map_response| {
        const entries = memory_map_response.entries();
        mem.init(entries);
        //mem.debug_traverse();
        var total_size: u128 = 0;

        try debug_print("Found {} memory map entries", .{entries.len});

        for (entries) |entry| {
            // try debug_print("Found entry of type: {}, base: 0x{x}, length: {} bytes\n", .{ entry.kind, entry.base, entry.length });
            total_size += entry.length;
        }

        try debug_print("{} entries, {} bytes", .{ memory_map_response.entry_count, total_size });
    }

    asm volatile ("int $3");

    // intentional(0);

    if (info_request.response) |info_response| {
        try debug_print("Info request completed!", .{});
        const name: [*:0]u8 = info_response.name;
        const version: [*:0]u8 = info_response.version;

        try debug_print("Using: \"{s}\", Version: {s}", .{ name, version });
    } else {
        try debug_print("Info request failed!", .{});
    }

    if (device_tree_request.response) |device_tree_blob_response| {
        const dtb_e = device_tree_blob_response.dtb;
        try debug_print("DTB found: {?}", .{dtb_e});

        // if (dtb_e) |dtb| {
        //     try debug_print("DTB! {*}", dtb);
        //                const header: *FDT_HEADER = @ptrCast(*FDT_HEADER, @alignCast(4, dtb));
        //              try debug_print("DTB header: {}", .{header});
        // }
    } else {
        try debug_print("DTB Not found!", .{});
    }

    if (sys_table_request.response) |sys_table_res| {
        try debug_print("Table: {}", .{sys_table_res});
    }

    if (rsdp_request.response) |rsdp_res| {
        const rsdp = @ptrCast(*align(1) acpi.RSDPDescriptor20, rsdp_res.address);

        var xsdt = @intToPtr(*acpi.XSDT, rsdp.Xsdt_address);

        try debug_print("RSDP: {}, {}", .{ rsdp, rsdp.doChecksum() });
        try debug_print("{s}", .{rsdp.first_part.OEMID});
        try debug_print("Header: {}; {}; {}", .{ xsdt.header, xsdt.header.doChecksum(), xsdt.getEntriesAmount() });
        try debug_print("'{s}' '{s}', '{s}'", .{ xsdt.header.signature, xsdt.header.OMEID, xsdt.header.OEMTableID });

        for (0..xsdt.getEntriesAmount()) |i| {
            var entry = xsdt.getEntry(i);

            switch (entry.signature) {
                acpi.Signature.MCFG => try debug_print("MCFG!!!", .{}),
                acpi.Signature.APIC => {
                    try debug_print("APIC Found!", .{});
                    const apic = entry.into(acpi.APIC);

                    apic.loopEntries();
                },
                else => {},
            }
        }
    }

    const rtc = RTC.new(0x70, 0x71);

    while (rtc.get_update_in_progress()) {}
    var date: Date = rtc.get_date();

    try debug_print("New date: {}", .{date});

    // Ensure we got a framebuffer.
    var last_address = @intCast(u64, 0);

    try debug_print("--------------", .{});
    try debug_print("{?}", .{paging2(VirtAddr.new(offset))});
    try debug_print("--------------", .{});

    for (0..1) |i| {
        const page = mem.allocate_new() catch {
            try debug_print("Stopped at index: {}", .{i});
            done();
        };

        const new_addr = @ptrToInt(page);
        const diff = @intCast(i64, new_addr) - @intCast(i64, last_address);

        // if (diff / 8 > 4096) {
        try debug_print("New page ({}) at: {*}; Diff with old: {} bytes; {x}", .{
            i,
            page,
            diff,
            @ptrCast(*u64, @alignCast(8, page)).*,
        });

        const virt = VirtAddr.new(new_addr);
        try debug_print("Virt: {}; Paging: {?}", .{ virt, paging2(virt) });

        // }

        last_address = new_addr;
        //mem.free(page);
    }

    done();

    const exit = Port(u32).new(0xf4);
    exit.write(0x10);
}

fn display(framebuffer_request: limine.FramebufferResponse) void {
    if (framebuffer_request.response) |framebuffer_response| {
        const framebuffers = framebuffer_response.framebuffers();
        try debug_print("Found {} framebuffer(s)", .{framebuffers.len});

        if (framebuffer_response.framebuffer_count >= 1) {
            for (framebuffers, 0..) |framebuffer, idx| {
                try debug_print("Framebuffer (ID: {}), Resolution {}x{}", .{ idx, framebuffer.width, framebuffer.height });
            }

            // Get the first framebuffer's information.
            const framebuffer = framebuffer_response.framebuffers()[0];
            try debug_print("Selected framebuffer ID:0\n", .{});

            for (0..100) |x| {
                for (0..100) |y| {
                    const pixel_offset = framebuffer.pitch * x + y * 4;
                    const color: u32 = 0x01 * @intCast(u32, x) + 0x0001 * @intCast(u32, y) + 0x00001 * 255 + 0x000000FF;
                    @ptrCast(*u32, @alignCast(4, framebuffer.address + pixel_offset)).* = color;
                }
                // Write 0xFFFFFFFF to the provided pixel offset to fill it white.
            }
        }
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, e: ?usize) noreturn {
    @setCold(true);

    try debug_print("{s}, {?}", .{ msg, e });
    try debug_print("{?}", .{error_return_trace});

    const exit = Port(u32).new(0xf4);
    exit.write(0x10);
    unreachable;
}
