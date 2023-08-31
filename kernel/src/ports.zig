const std = @import("std");

pub fn Port(comptime T: type) type {
    return struct {
        port: u16,

        const Self = @This();

        pub fn new(port: u16) Self {
            if (T != u8 and T != u16 and T != u32) {
                @compileError("Port type is not supported");
            }

            return Self{ .port = port };
        }

        pub fn write(self: Self, value: T) void {
            switch (T) {
                u8 => asm volatile ("outb %[value],%[port]"
                    :
                    : [value] "{al}" (value),
                      [port] "N{dx}" (self.port),
                ),
                u16 => asm volatile ("outw %[value],%[port]"
                    :
                    : [value] "{al}" (value),
                      [port] "N{dx}" (self.port),
                ),
                u32 => asm volatile ("outl %[value],%[port]"
                    :
                    : [value] "{eax}" (value),
                      [port] "N{dx}" (self.port),
                ),
                else => {
                    @compileError("Port type not supported!");
                },
            }
        }

        pub fn read(self: Self) T {
            return switch (T) {
                u8 => asm volatile ("inb %[port],%[ret]"
                    : [ret] "={al}" (-> u8),
                    : [port] "N{dx}" (self.port),
                ),
                u16 => asm volatile ("inw %[port],%[ret]"
                    : [ret] "={al}" (-> u16),
                    : [port] "N{dx}" (self.port),
                ),
                u32 => asm volatile ("inl %[port],%[ret]"
                    : [ret] "={eax}" (-> u32),
                    : [port] "N{dx}" (self.port),
                ),
                else => {
                    @compileError("Port type not supported!");
                },
            };
        }
    };
}

const LineStatus = packed struct(u8) {
    input_full: bool = false,
    _: u4 = 0,
    output_empty: bool = false,
    __: u2 = 0,

    const Empty = @This(){
        .output_empty = true,
    };
};

pub const SerialPort = struct {
    data: Port(u8),
    int_en: Port(u8),
    fifo_ctrl: Port(u8),
    line_ctrl: Port(u8),
    modem_ctrl: Port(u8),
    line_sts: Port(u8),

    pub fn new(base: u16) @This() {
        return SerialPort{
            .data = Port(u8).new(base),
            .int_en = Port(u8).new(base + 1),
            .fifo_ctrl = Port(u8).new(base + 2),
            .line_ctrl = Port(u8).new(base + 3),
            .modem_ctrl = Port(u8).new(base + 4),
            .line_sts = Port(u8).new(base + 5),
        };
    }

    pub fn init(self: SerialPort) void {
        // Disable interrupts
        self.int_en.write(0x00);

        // Enable DLAB
        self.line_ctrl.write(0x80);

        // Set maximum speed to 38400 bps by configuring DLL and DLM
        self.data.write(0x03);
        self.int_en.write(0x00);

        // Disable DLAB and set data word length to 8 bits
        self.line_ctrl.write(0x03);

        // Enable FIFO, clear TX/RX queues and
        // set interrupt watermark at 14 bytes
        self.fifo_ctrl.write(0xC7);

        // Mark data terminal ready, signal request to send
        // and enable auxilliary output #2 (used as interrupt line for CPU)
        self.modem_ctrl.write(0x0B);

        // Enable interrupts
        self.int_en.write(0x01);
    }

    pub fn send(self: SerialPort, data: u8) void {
        while (@as(*const LineStatus, @ptrCast(&self.line_sts.read())).output_empty != true) {}

        self.data.write(data);
    }

    pub fn write_message(self: @This(), message: []const u8) error{}!usize {
        for (message) |letter| {
            self.send(letter);
        }

        return message.len;
    }

    pub const Writer = std.io.Writer(@This(), error{}, write_message);

    pub fn writer(self: @This()) Writer {
        return .{ .context = self };
    }
};
