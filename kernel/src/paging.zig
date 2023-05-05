const Table = packed struct(u64) {
    present: bool,
    writable: bool,
    user_accesible: bool,
    wtc: bool,
    cache_disabled: bool,
    accessed: bool,
    dirty: bool,
    ps: bool,
    global: bool,
    available: u3,
    phys_addr: u40,
    available2: u11,
    exec_forbidden: bool,

    pub fn get_next_table(self: *@This()) *[512]Table {
        const offset = @import("main.zig").offset;

        return @intToPtr(*[512]Table, @intCast(u64, self.phys_addr) * 4096 + offset);
    }
};

pub fn getPML4Table() *[512]Table {
    var cr3 = asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );

    return @intToPtr(*[512]Table, cr3 & 0x000f_ffff_ffff_f000);
}
