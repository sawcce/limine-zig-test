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
                    var page = @intToPtr(*PageAllocatorEntry, entry.base + i * page_size);
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

// Allocates a new 4kib page
pub fn allocate_new() !*anyopaque {
    if (next_page) |page| {
        next_page = page.next;
        page.next = null;

        available_pages -= 1;

        return @ptrCast(*anyopaque, page);
    }

    return error.NoMorePhysicalMemory;
}

pub fn allocate(size: usize) !*anyopaque {
    _ = size;
}

pub fn free(page: *anyopaque) void {
    const new = @ptrCast(*PageAllocatorEntry, @alignCast(8, page));
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
