const limine = @import("limine");
const std = @import("std");
const ports = @import("ports.zig");
const rtc_ = @import("rtc.zig");
const idt = @import("idt.zig");
const mem = @import("mem.zig");
const img = @import("zigimg");
const acpi = @import("acpi.zig");

const pic_mod = @import("pic.zig");
const PIC_STRUCT = pic_mod.PIC;

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
pub export var framebuffer_req: limine.FramebufferRequest = .{};

inline fn done() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

const serial_port = SerialPort.new(0x3F8);
pub var offset: u64 = undefined;

pub const Display = struct {
    framebuffer: *limine.Framebuffer,

    pub inline fn set_pixel(self: @This(), x_pos: u64, y_pos: u64, color: u32) void {
        const pixel_offset = x_pos * 4 + y_pos * self.framebuffer.pitch;
        @as(*align(4) u32, @ptrCast(@alignCast(self.framebuffer.address + pixel_offset))).* = color;
    }

    pub fn fill_blank(self: @This()) void {
        for (0..self.framebuffer.height) |y_pos| {
            for (0..self.framebuffer.width) |x_pos| {
                self.set_pixel(x_pos, y_pos, 0x121212);
            }
        }
    }

    pub fn write(_self: @This(), message: []const u8) error{}!usize {
        _ = _self;
        write_message(message);

        return message.len;
    }

    pub const Writer = std.io.Writer(@This(), error{}, write);

    pub fn writer(self: @This()) Writer {
        return .{ .context = self };
    }
};

pub var current_display: ?Display = null;

const bg_color: u32 = 0x121212;
const text_color: u32 = 0xF05E48;

var x: u64 = 10;
var y: u64 = 10;

pub fn debug_print(comptime fmt: []const u8, args: anytype) !void {
    _ = try serial_port.write_message("[KERNEL] ");
    try std.fmt.format(serial_port.writer(), fmt, args);
    _ = try serial_port.write_message("\n");

    if (current_display) |dis| {
        write_message("[KERNEL]");
        try std.fmt.format(dis.writer(), fmt, args);
        write_message("\n");
    }
}

const fonts = @import("fonts.zig");
const font = fonts.font8x8_basic;

fn write_message(message: []const u8) void {
    if (current_display) |d| {
        const fb = d.framebuffer;

        for (message) |char| {
            // try debug_print("Char: {any}", .{font[char]});

            if ((char == '\n') or (x > fb.width - 20)) {
                x = 10;
                y += 10;

                if (y > fb.height - 10) {
                    y = 140;
                }

                for (0..10) |yy| {
                    for (0..fb.width) |xx| {
                        const pixel_offset = (x + xx) * 4 + (y + yy) * fb.pitch;
                        @as(*align(4) u32, @ptrCast(@alignCast(fb.address + pixel_offset))).* = bg_color;
                    }
                }

                continue;
            }

            const bm = font[char];

            for (bm, 0..) |line, y2| {
                // var t: [8]u8 = undefined;

                for (0..8) |z| {
                    const pixel_offset = (x + z) * 4 + (y + y2) * fb.pitch;
                    const is_set = std.math.shr(u8, line, z) & 1;
                    // t[z] = is_set;

                    const color: u32 = switch (is_set) {
                        0 => @intCast(bg_color),
                        1 => @intCast(text_color),
                        else => @intCast(0xFF0000),
                    };

                    @as(*align(4) u32, @ptrCast(@alignCast(fb.address + pixel_offset))).* = color;
                }
            }

            x += 10;
        }
    }
}

fn display(framebuffer_request: limine.FramebufferRequest) void {
    if (framebuffer_request.response) |framebuffer_response| {
        const framebuffers = framebuffer_response.framebuffers();
        try debug_print("Found {} framebuffer(s)", .{framebuffers.len});

        if (framebuffer_response.framebuffer_count >= 1) {
            for (framebuffers, 0..) |fb, idx| {
                try debug_print("Fb (ID: {}), Resolution {}x{}, BPP: {}", .{ idx, fb.width, fb.height, fb.bpp });
            }

            const d = Display{ .framebuffer = framebuffer_response.framebuffers()[0] };
            d.fill_blank();

            try debug_print("Selected framebuffer ID:0\n", .{});
            current_display = d;

            const message =
                \\ $$\      $$\                                      $$$$$$\   $$$$$$\  $$\
                \\ $$$\    $$$ |                                    $$  __$$\ $$  __$$\ $$ |
                \\ $$$$\  $$$$ | $$$$$$\   $$$$$$\   $$$$$$\        $$ /  $$ |$$ /  \__|$$ |
                \\ $$\$$\$$ $$ |$$  __$$\ $$  __$$\ $$  __$$\       $$ |  $$ |\$$$$$$\  $$ |
                \\ $$ \$$$  $$ |$$$$$$$$ |$$$$$$$$ |$$ /  $$ |      $$ |  $$ | \____$$\ \__|
                \\ $$ |\$  /$$ |$$   ____|$$   ____|$$ |  $$ |      $$ |  $$ |$$\   $$ |
                \\ $$ | \_/ $$ |\$$$$$$$\ \$$$$$$$\ $$$$$$$  |       $$$$$$  |\$$$$$$  |$$\
                \\ \__|     \__| \_______| \_______|$$  ____/        \______/  \______/ \__|
                \\                                  $$ |
                \\                                  $$ |
                \\                                  \__|
            ;

            write_message(message);
            x = 0;
            y = 140;
        }
    }
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
        _ = ret_address;
        const aligned_len = std.mem.alignForward(usize, len, mem.page_size);
        debug_print("Alloc: {}, {}, {}, aligned_len: {}", .{ ctx, len, ptr_align, aligned_len }) catch {};

        const frame = mem.frame_alloc() catch {
            return null;
        };
        const ptr: [*]u8 = @ptrCast(frame.ptr);

        return ptr;
    }

    fn free(_: *anyopaque, slice: []u8, _: u8, _: usize) void {
        try debug_print("Free: {any}", .{slice});
        try mem.free_zone(slice.ptr, slice.len);
    }

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

fn testHandler(frame: *idt.Frame) void {
    try debug_print("Interrupt: {}", .{frame.*});
}

fn trapHandler(frame: *idt.Frame) void {
    try debug_print("Interrupt: {}", .{frame.*});

    while (true) {
        asm volatile ("hlt");
    }
}

fn timerHandler(frame: *idt.Frame) void {
    _ = frame;
    // try debug_print("PIC: {}", .{frame});
    pic_mod.GLOBAL_PIC.?.eoi(32);
}

const kbdEvent = packed struct {
    key: u7,
    press: bool,
};

const KeyCode = enum {
    // ========= Row 1 (the F-keys) =========
    /// Top Left of the Keyboard
    Escape,
    /// Function Key F1
    F1,
    /// Function Key F2
    F2,
    /// Function Key F3
    F3,
    /// Function Key F4
    F4,
    /// Function Key F5
    F5,
    /// Function Key F6
    F6,
    /// Function Key F7
    F7,
    /// Function Key F8
    F8,
    /// Function Key F9
    F9,
    /// Function Key F10
    F10,
    /// Function Key F11
    F11,
    /// Function Key F12
    F12,

    /// The Print Screen Key
    PrintScreen,
    /// The Sys Req key (you get this keycode with Alt + PrintScreen)
    SysRq,
    /// The Scroll Lock key
    ScrollLock,
    /// The Pause/Break key
    PauseBreak,

    // ========= Row 2 (the numbers) =========
    /// Symbol key to the left of `Key1`
    Oem8,
    /// Number Line, Digit 1
    Key1,
    /// Number Line, Digit 2
    Key2,
    /// Number Line, Digit 3
    Key3,
    /// Number Line, Digit 4
    Key4,
    /// Number Line, Digit 5
    Key5,
    /// Number Line, Digit 6
    Key6,
    /// Number Line, Digit 7
    Key7,
    /// Number Line, Digit 8
    Key8,
    /// Number Line, Digit 9
    Key9,
    /// Number Line, Digit 0
    Key0,
    /// US Minus/Underscore Key (right of 'Key0')
    OemMinus,
    /// US Equals/Plus Key (right of 'OemMinus')
    OemPlus,
    /// Backspace
    Backspace,

    /// Top Left of the Extended Block
    Insert,
    /// Top Middle of the Extended Block
    Home,
    /// Top Right of the Extended Block
    PageUp,

    /// The Num Lock key
    NumpadLock,
    /// The Numpad Divide (or Slash) key
    NumpadDivide,
    /// The Numpad Multiple (or Star) key
    NumpadMultiply,
    /// The Numpad Subtract (or Minus) key
    NumpadSubtract,

    // ========= Row 3 (QWERTY) =========
    /// The Tab Key
    Tab,
    /// Letters, Top Row #1
    Q,
    /// Letters, Top Row #2
    W,
    /// Letters, Top Row #3
    E,
    /// Letters, Top Row #4
    R,
    /// Letters, Top Row #5
    T,
    /// Letters, Top Row #6
    Y,
    /// Letters, Top Row #7
    U,
    /// Letters, Top Row #8
    I,
    /// Letters, Top Row #9
    O,
    /// Letters, Top Row #10
    P,
    /// US ANSI Left-Square-Bracket key
    Oem4,
    /// US ANSI Right-Square-Bracket key
    Oem6,
    /// US ANSI Backslash Key / UK ISO Backslash Key
    Oem5,
    /// The UK/ISO Hash/Tilde key (ISO layout only)
    Oem7,

    /// The Delete key - bottom Left of the Extended Block
    Delete,
    /// The End key - bottom Middle of the Extended Block
    End,
    /// The Page Down key - -bottom Right of the Extended Block
    PageDown,

    /// The Numpad 7/Home key
    Numpad7,
    /// The Numpad 8/Up Arrow key
    Numpad8,
    /// The Numpad 9/Page Up key
    Numpad9,
    /// The Numpad Add/Plus key
    NumpadAdd,

    // ========= Row 4 (ASDF) =========
    /// Caps Lock
    CapsLock,
    /// Letters, Middle Row #1
    A,
    /// Letters, Middle Row #2
    S,
    /// Letters, Middle Row #3
    D,
    /// Letters, Middle Row #4
    F,
    /// Letters, Middle Row #5
    G,
    /// Letters, Middle Row #6
    H,
    /// Letters, Middle Row #7
    J,
    /// Letters, Middle Row #8
    K,
    /// Letters, Middle Row #9
    L,
    /// The US ANSI Semicolon/Colon key
    Oem1,
    /// The US ANSI Single-Quote/At key
    Oem3,

    /// The Return Key
    Return,

    /// The Numpad 4/Left Arrow key
    Numpad4,
    /// The Numpad 5 Key
    Numpad5,
    /// The Numpad 6/Right Arrow key
    Numpad6,

    // ========= Row 5 (ZXCV) =========
    /// Left Shift
    LShift,
    /// Letters, Bottom Row #1
    Z,
    /// Letters, Bottom Row #2
    X,
    /// Letters, Bottom Row #3
    C,
    /// Letters, Bottom Row #4
    V,
    /// Letters, Bottom Row #5
    B,
    /// Letters, Bottom Row #6
    N,
    /// Letters, Bottom Row #7
    M,
    /// US ANSI `,<` key
    OemComma,
    /// US ANSI `.>` Key
    OemPeriod,
    /// US ANSI `/?` Key
    Oem2,
    /// Right Shift
    RShift,

    /// The up-arrow in the inverted-T
    ArrowUp,

    /// Numpad 1/End Key
    Numpad1,
    /// Numpad 2/Arrow Down Key
    Numpad2,
    /// Numpad 3/Page Down Key
    Numpad3,
    /// Numpad Enter
    NumpadEnter,

    // ========= Row 6 (modifers and space bar) =========
    /// The left-hand Control key
    LControl,
    /// The left-hand 'Windows' key
    LWin,
    /// The left-hand Alt key
    LAlt,
    /// The Space Bar
    Spacebar,
    /// The right-hand AltGr key
    RAltGr,
    /// The right-hand Win key
    RWin,
    /// The 'Apps' key (aka 'Menu' or 'Right-Click')
    Apps,
    /// The right-hand Control key
    RControl,

    /// The left-arrow in the inverted-T
    ArrowLeft,
    /// The down-arrow in the inverted-T
    ArrowDown,
    /// The right-arrow in the inverted-T
    ArrowRight,

    /// The Numpad 0/Insert Key
    Numpad0,
    /// The Numppad Period/Delete Key
    NumpadPeriod,

    // ========= JIS 109-key extra keys =========
    /// Extra JIS key (0x7B)
    Oem9,
    /// Extra JIS key (0x79)
    Oem10,
    /// Extra JIS key (0x70)
    Oem11,
    /// Extra JIS symbol key (0x73)
    Oem12,
    /// Extra JIS symbol key (0x7D)
    Oem13,

    // ========= Extra Keys =========
    /// Multi-media keys - Previous Track
    PrevTrack,
    /// Multi-media keys - Next Track
    NextTrack,
    /// Multi-media keys - Volume Mute Toggle
    Mute,
    /// Multi-media keys - Open Calculator
    Calculator,
    /// Multi-media keys - Play
    Play,
    /// Multi-media keys - Stop
    Stop,
    /// Multi-media keys - Increase Volume
    VolumeDown,
    /// Multi-media keys - Decrease Volume
    VolumeUp,
    /// Multi-media keys - Open Browser
    WWWHome,
    /// Sent when the keyboard boots
    PowerOnTestOk,
    /// Sent by the keyboard when too many keys are pressed
    TooManyKeys,
    /// Used as a 'hidden' Right Control Key (Pause = RControl2 + Num Lock)
    RControl2,
    /// Used as a 'hidden' Right Alt Key (Print Screen = RAlt2 + PrntScr)
    RAlt2,
};

fn keyboardHandler(_: *idt.Frame) void {
    try debug_print("KBD", .{});
    const port = Port(u8).new(0x60);
    const scancode: *const kbdEvent = @ptrCast(&port.read());
    try debug_print("Scancode: {}, {}", .{scancode, mapKey(@intCast(scancode.key))});

    pic_mod.GLOBAL_PIC.?.eoi(33);
}

fn mapKey(key: u8) KeyCode {
    return switch (key) {
        0x01 => KeyCode.Escape,
        0x02 => KeyCode.Key1,
        0x03 => KeyCode.Key2,
        0x04 => KeyCode.Key3,
        0x05 => KeyCode.Key4,
        0x06 => KeyCode.Key5,
        0x07 => KeyCode.Key6,
        0x08 => KeyCode.Key7,
        0x09 => KeyCode.Key8,
        0x0A => KeyCode.Key9,
        0x0B => KeyCode.Key0,
        0x0C => KeyCode.OemMinus,
        0x0D => KeyCode.OemPlus,
        0x0E => KeyCode.Backspace,
        0x0F => KeyCode.Tab,
        0x10 => KeyCode.Q,
        0x11 => KeyCode.W,
        0x12 => KeyCode.E,
        0x13 => KeyCode.R,
        0x14 => KeyCode.T,
        0x15 => KeyCode.Y,
        0x16 => KeyCode.U,
        0x17 => KeyCode.I,
        0x18 => KeyCode.O,
        0x19 => KeyCode.P,
        0x1A => KeyCode.Oem4,
        0x1B => KeyCode.Oem6,
        0x1C => KeyCode.Return,
        0x1D => KeyCode.LControl,
        0x1E => KeyCode.A,
        0x1F => KeyCode.S,
        0x20 => KeyCode.D,
        0x21 => KeyCode.F,
        0x22 => KeyCode.G,
        0x23 => KeyCode.H,
        0x24 => KeyCode.J,
        0x25 => KeyCode.K,
        0x26 => KeyCode.L,
        0x27 => KeyCode.Oem1,
        0x28 => KeyCode.Oem3,
        0x29 => KeyCode.Oem8,
        0x2A => KeyCode.LShift,
        0x2B => KeyCode.Oem7,
        0x2C => KeyCode.Z,
        0x2D => KeyCode.X,
        0x2E => KeyCode.C,
        0x2F => KeyCode.V,
        0x30 => KeyCode.B,
        0x31 => KeyCode.N,
        0x32 => KeyCode.M,
        0x33 => KeyCode.OemComma,
        0x34 => KeyCode.OemPeriod,
        0x35 => KeyCode.Oem2,
        0x36 => KeyCode.RShift,
        0x37 => KeyCode.NumpadMultiply,
        0x38 => KeyCode.LAlt,
        0x39 => KeyCode.Spacebar,
        0x3A => KeyCode.CapsLock,
        0x3B => KeyCode.F1,
        0x3C => KeyCode.F2,
        0x3D => KeyCode.F3,
        0x3E => KeyCode.F4,
        0x3F => KeyCode.F5,
        0x40 => KeyCode.F6,
        0x41 => KeyCode.F7,
        0x42 => KeyCode.F8,
        0x43 => KeyCode.F9,
        0x44 => KeyCode.F10,
        0x45 => KeyCode.NumpadLock,
        0x46 => KeyCode.ScrollLock,
        0x47 => KeyCode.Numpad7,
        0x48 => KeyCode.Numpad8,
        0x49 => KeyCode.Numpad9,
        0x4A => KeyCode.NumpadSubtract,
        0x4B => KeyCode.Numpad4,
        0x4C => KeyCode.Numpad5,
        0x4D => KeyCode.Numpad6,
        0x4E => KeyCode.NumpadAdd,
        0x4F => KeyCode.Numpad1,
        0x50 => KeyCode.Numpad2,
        0x51 => KeyCode.Numpad3,
        0x52 => KeyCode.Numpad0,
        0x53 => KeyCode.NumpadPeriod,
        0x54 => KeyCode.SysRq,
        0x56 => KeyCode.Oem5,
        0x57 => KeyCode.F11,
        0x58 => KeyCode.F12,
        else => KeyCode.A,
    };
}

// The following will be our kernel's entry point.
export fn _start() callconv(.C) void {
    serial_port.init();

    idt.add_interrupt(3, testHandler);
    idt.add_interrupt(13, trapHandler);

    idt.add_interrupt(32, timerHandler);
    idt.add_interrupt(33, keyboardHandler);

    idt.load();

    const pic = PIC_STRUCT.new();
    _ = pic;
    PIC_STRUCT.enable();

    if (hhdm_req.response) |hhdm_res| {
        try debug_print("Offset: {x}", .{hhdm_res.offset});
        offset = hhdm_res.offset;
    }

    display(framebuffer_req);

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

    // asm volatile ("int $3");

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

    // const allocator = ExperimentalAllocator;
    // const a = allocator.allocator() catch {
    //     panic("Couldn't init", null, null);
    // };

    // var b = a.alloc(*const []u8, 3) catch {panic("Couldn't alloc", null, null);};
    // b[0] = @alignCast(@ptrCast("Hello, world"));
    // // b[1] = "Test";
    // // b[2] = "Test 2";

    // for(b) |item| {
    //     try debug_print("Test: {s}", .{item.*});
    // }

    // a.free(b);

    try debug_print("Test!", .{});

    done();
    const exit = Port(u32).new(0xf4);
    exit.write(0x10);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, e: ?usize) noreturn {
    @setCold(true);

    try debug_print("{s}, {?}", .{ msg, e });
    try debug_print("{?}", .{error_return_trace});

    const exit = Port(u32).new(0xf4);
    exit.write(0x10);
    unreachable;
}
