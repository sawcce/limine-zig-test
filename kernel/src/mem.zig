const std = @import("std");
const limine = @import("limine");

const EntryType = limine.MemoryMapEntryType;

const debug_print = @import("main.zig").debug_print;

pub const page_size = 4096;

const PageAllocatorEntry = extern struct {
    next: ?*PageAllocatorEntry = null,
    size: usize = page_size,
};

var first_entry: PageAllocatorEntry = .{};
var next_page: ?*PageAllocatorEntry = null;

pub var available_pages: usize = 0;

pub fn init(entries: []*limine.MemoryMapEntry) void {
    // var last_page_entry = &first_entry;

    for (entries) |entry| {
        switch (entry.kind) {
            EntryType.usable => {
                for (0..entry.length / page_size) |i| {
                    var page = @as(*PageAllocatorEntry, @ptrFromInt(entry.base + i * page_size));
                    page.next = next_page;
                    next_page = page;
                    available_pages += 1;
                }
            },
            else => {},
        }
    }

    // next_page = first_entry.next.?;
}

pub const PageFrame = extern struct {
    ptr: *anyopaque,
    statuses: [512]u8 = undefined,
};

// Allocates a new 4kib page
pub fn allocate_new() !*anyopaque {
    if (next_page) |page| {
        next_page = page.next;
        page.next = null;

        available_pages -= 1;

        return @as(*anyopaque, @ptrCast(page));
    }

    return error.NoMorePhysicalMemory;
}

/// EXPERIMENT: TO BE REWORKED
pub fn frame_alloc() !*PageFrame {
    const frame = try allocate_new();
    const page = try allocate_new();

    const frame_ptr: *PageFrame = @alignCast(@ptrCast(frame));
    frame_ptr.ptr = page;
    frame_ptr.statuses = undefined;

    for (0..frame_ptr.statuses.len) |i| {
        frame_ptr.statuses[i] = 0;
    }

    return frame_ptr;
}

pub fn free_zone(start: *anyopaque, len: usize) !void {
    const startPos: u64 = @intFromPtr(start);
    const page = startPos - @mod(startPos, page_size);
    const index = (startPos - page) / 8;

    for(index..index+len) |i| {
        try debug_print("i: {}", .{i});
    }

    try debug_print("Start Position: {}, page: {}, index: {}, len: {}", .{startPos, page, index, len});
}

pub fn allocate(size: usize) !*anyopaque {
    _ = size;
}

pub fn free(page: *anyopaque) void {
    const new = @as(*align(8) PageAllocatorEntry, @ptrCast(@alignCast(page)));
    new.next = next_page;
    next_page = new;

    available_pages += 1;
}

pub fn debug_traverse() void {
    var current_page = next_page;

    while (current_page.?.next) |page| : (current_page = current_page.?.next) {
        try debug_print("Page: {?*}\n", .{page.next});
    }
}
