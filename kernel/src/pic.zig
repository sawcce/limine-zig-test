const ports = @import("ports.zig");
const Port = ports.Port;
const debug_print = @import("main.zig").debug_print;

const PIC1 = 0x20;
const PIC2 = 0xA0;

const PIC1_COMMAND = PIC1;
const PIC1_DATA = PIC1 + 1;

const PIC2_COMMAND = PIC2;
const PIC2_DATA = PIC2 + 1;

pub var GLOBAL_PIC: ?*const PIC = null;

pub const PIC = struct {
    pic1_command: Port(u8) = Port(u8).new(PIC1_COMMAND),
    pic1_data: Port(u8) = Port(u8).new(PIC1_DATA),
    pic2_command: Port(u8) = Port(u8).new(PIC2_COMMAND),
    pic2_data: Port(u8) = Port(u8).new(PIC2_DATA),
    wait_port: Port(u8) = Port(u8).new(0x80),

    pub fn wait(self: @This()) void {
        self.wait_port.write(0);
        try debug_print("WAIT", .{});
    }

    pub fn new() PIC {
        const self: PIC = .{};
        GLOBAL_PIC = &self;

        // const mask_a = self.pic1_data.read();
        const mask_b = self.pic2_data.read();

        self.pic1_command.write(0x11);
        self.wait();
        self.pic2_command.write(0x11);
        self.wait();

        self.pic1_data.write(32);
        self.wait();
        self.pic2_data.write(40);
        self.wait();

        self.pic1_data.write(4);
        self.wait();
        self.pic2_data.write(2);
        self.wait();

        self.pic1_data.write(0x01);
        self.wait();
        self.pic2_data.write(0x01);
        self.wait();

        self.pic1_data.write(0b0);
        self.wait();
        self.pic2_data.write(mask_b);
        self.wait();

        try debug_print("Done inti pic!", .{});

        return self;
    }

    pub fn eoi(self: @This(), idx: u8) void {
        if(idx >= 40) self.pic2_command.write(0x20);

        self.pic1_command.write(0x20);
    }

    pub fn enable() void {
        asm volatile ("sti");
    }
};
