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
pub var offset: u64 = undefined;

pub fn debug_print(comptime fmt: []const u8, args: anytype) !void {
    _ = try serial_port.write_message("[KERNEL] ");
    try std.fmt.format(serial_port.writer(), fmt, args);
    _ = try serial_port.write_message("\n");
}

fn getBits(number: u64, start: u64, end: u64) u64 {
    const mask = std.math.shl(u64, 1, end - start) - 1;
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
            0, 0x1ffff => @as(*VirtAddr, @ptrCast(@constCast(&addr))).*,
            1 => @as(*VirtAddr, @ptrCast(@constCast(&@as(u64, @bitCast(@as(i64, @bitCast(addr << 16)) >> 16))))).*,
            else => {
                try debug_print("Invalid addr!!!!\n", .{});
                @panic("Tried to create invalid virtual address!");
            },
        };
    }

    fn fromLevels(level1: u64, level2: u64, level3: u64, level4: u64) VirtAddr {
        return VirtAddr.new((level1 << 12) + (level2 << 21) + (level3 << 30) + (level4 << 39));
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

const paging = @import("paging.zig");

fn paging2(address: VirtAddr) ?*anyopaque {
    const pml4 = paging.getPML4Table();

    //var addr = address;
    //try debug_print("Address: 0b{b} 0x{x}", .{ @ptrCast(*u64, &addr).*, @ptrCast(*u64, &addr).* });
    //try debug_print("Address: {}", .{addr});

    var pml4e = pml4.*[address.level4];
    var pdpte = pml4e.getNextTable().*[address.level3];

    if (pdpte.ps == true) {
        try debug_print("1GIB Page", .{});
        @panic("TODO");
        //return @intToPtr(?*anyopaque, @intCast(u64, pdpte.phys_addr) * 4096 + @intCast(u64, address.level1) * 4096);
    }

    var pde = pdpte.getNextTable().*[address.level2];

    if (pde.ps == true) {
        return @ptrFromInt(@as(u64, @intCast(pde.phys_addr)) * 4096 + @as(u64, @intCast(address.level1)) * 4096 + address.page_offset);
    }

    var pte = pde.getNextTable().*[address.level1];

    //try debug_print("4: {}", .{pml4e});
    //try debug_print("3: {}", .{pdpte});
    //try debug_print("2: {}", .{pde});
    //try debug_print("1: {any}", .{pte});
    //try debug_print("Entry: 0x{x}", .{@intCast(u64, pde.phys_addr) * 4096});
    return @ptrFromInt(@as(u64, @intCast(pte.phys_addr)) * 4096 + @as(u64, @intCast(address.page_offset)) * 4096);
}

fn alloc(size: usize) !?*anyopaque {
    const minimum_pages = (size / mem.page_size) + 1;
    var pml4 = paging.getPML4Table();

    var start_addr: ?VirtAddr = VirtAddr.new(0);
    var current_size: usize = 0;

    for (pml4, 0..) |*pml4e, level4| {
        var pdpt = pml4e.getNextTable();

        for (pdpt, 0..) |*pdpte, level3| {
            var pd = pdpte.getNextTable();

            for (pd, 0..) |*pde, level2| {
                var pt = pde.getNextTable();

                for (pt, 0..) |*pte, level1| {
                    if (pte.present) {
                        current_size = 0;
                        start_addr = null;
                        continue;
                    }

                    if (start_addr == null) {
                        start_addr = VirtAddr.fromLevels(level1, level2, level3, level4);
                    }

                    current_size += mem.page_size;

                    if (current_size >= size) {
                        try debug_print("Done: {} {} {} {}", .{ level4, level3, level2, level1 });
                        return @ptrCast(&start_addr);
                    }
                }
            }
        }
    }

    _ = minimum_pages;
    return null;
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

    const uefi = std.os.uefi;
    _ = uefi;

    std.os.uefi.system_table = @as(*std.os.uefi.tables.SystemTable, @ptrCast(@alignCast(sys_table_request.response.?.address)));
    const table = std.os.uefi.system_table;
    try debug_print("Table {?}", .{table.boot_services});
    var buffer: [5]std.os.uefi.Handle = undefined;
    // const status = table.boot_services.?.locateHandle(uefi.tables.LocateSearchType.AllHandles, &uefi.protocols.BlockIoProtocol.guid, null, @constCast(&buffer.len), &buffer);
    // try debug_print("Status: {}", .{status});

    for (buffer) |handle| {
        try debug_print("Found handle: {}", .{handle});
    }

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
    } else {
        try debug_print("DTB Not found!", .{});
    }

    if (rsdp_request.response) |rsdp_res| {
        const rsdp = @as(*align(1) acpi.RSDPDescriptor20, @ptrCast(rsdp_res.address));

        var xsdt = @as(*acpi.XSDT, @ptrFromInt(rsdp.Xsdt_address));

        try debug_print("RSDP: {}, {}", .{ rsdp, rsdp.doChecksum() });
        try debug_print("{s}", .{rsdp.first_part.OEMID});
        try debug_print("Header: {}; {}; {}", .{ xsdt.header, xsdt.header.doChecksum(), xsdt.getEntriesAmount() });
        try debug_print("'{s}' '{s}', '{s}'", .{ xsdt.header.signature, xsdt.header.OMEID, xsdt.header.OEMTableID });

        for (0..xsdt.getEntriesAmount()) |i| {
            var entry = xsdt.getEntry(i);

            switch (entry.signature) {
                acpi.Signature.MCFG => {
                    const mcfg = @as(*acpi.MCFG, @ptrCast(entry));

                    try debug_print("MCFG! {} {}", .{ mcfg, mcfg.header.doChecksum() });
                    const MCFGEntry = packed struct(u128) {
                        base_addr: u64,
                        segment_group: u16,
                        start_bus: u8,
                        end_bus: u8,
                        reserved: u32,
                    };

                    const base = @intFromPtr(mcfg) + @sizeOf(acpi.MCFG);
                    var pi = base;
                    //@compileLog(@sizeOf(acpi.MCFG));

                    while (pi < base + entry.length - @sizeOf(acpi.MCFG)) : (pi += 16) {
                        const PCI = @as(*align(1) MCFGEntry, @ptrFromInt(pi));
                        const Config = @import("pci/config.zig").Config;

                        try debug_print("PCI: 0x{x}@{} ", .{ PCI.base_addr, PCI });

                        for (PCI.start_bus..PCI.end_bus) |id| {
                            for (0..16) |did| {
                                for (0..8) |fid| {
                                    const rc = @as(*align(1) Config, @ptrFromInt(offset + PCI.base_addr + (id << 20) + (did << 15) + (fid << 12)));

                                    switch (rc.classCode) {
                                        0xc0320 => {},
                                        0x10601 => {
                                            const AHCI = @import("pci/ahci.zig");

                                            try debug_print("AHCI Drive: {}", .{rc.bar5});
                                            for (0..31) |port_index| {
                                                const port = @as(*AHCI.PortHeader, @ptrFromInt(offset + rc.bar5 + 256 + 128 * (port_index)));
                                                if (port.sig != AHCI.Signature.SATA) continue;
                                                const slots = (port.sact | port.ci);
                                                try debug_print("Port 0: {} {}", .{ slots, port.sig });
                                            }
                                        },
                                        0xffffff => continue,
                                        else => {},
                                    }
                                    try debug_print("Conf {} 0x{x}", .{ rc, rc.vendorID });
                                }
                            }
                        }
                    }
                },
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
    var last_address = @as(u64, @intCast(0));
    _ = last_address;

    try debug_print("--------------", .{});
    try debug_print("{?}", .{paging2(VirtAddr.new(offset))});
    try debug_print("--------------", .{});

    const testAlloc = alloc(10000) catch {};
    try debug_print("Test alloc: {?}", .{testAlloc});

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
                    const color: u32 = 0x01 * @as(u32, @intCast(x)) + 0x0001 * @as(u32, @intCast(y)) + 0x00001 * 255 + 0x000000FF;
                    @as(*u32, @ptrCast(@alignCast(framebuffer.address + pixel_offset))).* = color;
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
