const std = @import("std");
const Ports = @import("ports.zig");

const Port = Ports.Port;

pub const Date = struct {
    second: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    day: u8 = 0,
    month: u8 = 0,
    year: u8 = 0,
    century: u8 = 0,

    const Self = @This();
};

pub const RTC = struct {
    in: Port(u8),
    out: Port(u8),

    const Self = @This();

    pub fn new(out: u8, in: u8) Self {
        return Self{
            .in = Port(u8).new(in),
            .out = Port(u8).new(out),
        };
    }

    pub fn get_update_in_progress(self: Self) bool {
        return self.read_register(0x0A) & 0x80 == 1;
    }

    fn read_register(self: Self, register: u8) u8 {
        self.out.write(register);
        const value_bcd = self.in.read();
        return (value_bcd & 0x0F) + ((value_bcd / 16) * 10);
    }

    pub fn get_date(self: Self) Date {
        const second = self.read_register(0x00);
        const minute = self.read_register(0x02);
        const hour = self.read_register(0x04);
        const day = self.read_register(0x07);
        const month = self.read_register(0x08);
        const year = self.read_register(0x09);
        const century = 20;

        return Date{
            .second = second,
            .minute = minute,
            .hour = hour,
            .day = day,
            .month = month,
            .year = year,
            .century = century,
        };
    }
};
