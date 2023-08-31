const std = @import("std");
const debug_print = @import("main.zig").debug_print;

const handlers_amount = 256;
pub var idt = [1]InterruptDescriptor{undefined} ** handlers_amount;

const Trampoline = fn () callconv(.Naked) void;

fn generate_trampolines() [handlers_amount]*const Trampoline {
    var result: [handlers_amount]*const Trampoline = undefined;

    inline for (0..256) |interruptIdx| {
        result[interruptIdx] = comptime make_trampoline(interruptIdx);
    }

    return result;
}

var trampolines: [handlers_amount]*const Trampoline = generate_trampolines();

pub fn make_trampoline(comptime interruptIdx: u8) *const Trampoline {
    return struct {
        fn trampoline() callconv(.Naked) void {
            asm volatile ("push %[int]\njmp catcher\n"
                :
                : [int] "i" (@as(u8, interruptIdx)),
            );
        }
    }.trampoline;
}

export fn catcher() callconv(.Naked) void {
    asm volatile (
        \\mov %%rsp, %%rdi
        \\call handler_fn
        \\pop %%rax
        // \\add $8, %rsp
        \\iretq
    );

    // unreachable;
}

const Frame = extern struct {
    idx: u64,
    ec: u64,

    // fn debug(self: *const @This()) void {
    //     try debug_print("Frame: Idx {}; Ec {}; Rip {}; Eflags {}; Rsp {}; Ss {};", .{
    //         self.idx,
    //         self.ec,
    //         self.rip,
    //         self.eflags,
    //         self.rsp,
    //         self.ss,
    //     });
    // }
};

export fn handler_fn(frame: *Frame) void {
    try debug_print("Interrupt: {}\n", .{frame});

    while (frame.idx != 3) {
        asm volatile ("hlt");
    }
}

pub fn load() void {
    const idtr = IDTR{
        .base = @intFromPtr(&idt),
        .limit = @sizeOf(@TypeOf(idt)) - 1,
    };

    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
    );
}

pub fn add_interrupt(idx: u8) void {
    const pointer = @intFromPtr(trampolines[idx]);
    // var pointer = @intCast(usize, 4567);

    try debug_print("Interrupt: {}", .{idx});

    var cs = asm ("mov %%cs, %[ret]"
        : [ret] "=r" (-> u16),
    );

    var entry = InterruptDescriptor{};

    entry.selector = cs;
    entry.options.gate_type = 0xE;

    entry.offset_low = @as(u16, @truncate(pointer));
    entry.offset_mid = @as(u16, @truncate(pointer >> 16));
    entry.offset_high = @as(u32, @truncate(pointer >> 32));

    entry.options.present = true;

    idt[idx] = entry;

    try debug_print("Interrupts: {}\n", .{entry});
}

const EntryOptions = packed struct(u16) {
    ist: u3 = 0,
    // Reserved do not use
    reserved1: u5 = 0,
    // default: interrupt gate (0b1110)
    gate_type: u4 = 0x0,
    // Reserved do not use
    reserved2: u1 = 0,
    privledge_level: u2 = 0,
    present: bool = false,
};

const InterruptDescriptor = extern struct {
    offset_low: u16 = 0,
    selector: u16 = 0,
    options: EntryOptions = .{},
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,
};

pub const IDTR = packed struct {
    limit: u16,
    base: u64,
};
