pub const PortHeader = extern struct {
    clb: u32, // 0x00, command list base address, 1K-byte aligned
    clbu: u32, // 0x04, command list base address upper 32 bits
    fb: u32, // 0x08, FIS base address, 256-byte aligned
    fbu: u32, // 0x0C, FIS base address upper 32 bits
    is: u32, // 0x10, interrupt status
    ie: u32, // 0x14, interrupt enable
    cmd: u32, // 0x18, command and status
    rsv0: u32, // 0x1C, Reserved
    tfd: u32, // 0x20, task file data
    sig: Signature, // 0x24, signature
    ssts: u32, // 0x28, SATA status (SCR0:SStatus)
    sctl: u32, // 0x2C, SATA control (SCR2:SControl)
    serr: u32, // 0x30, SATA error (SCR1:SError)
    sact: u32, // 0x34, SATA active (SCR3:SActive)
    ci: u32, // 0x38, command issue
    sntf: u32, // 0x3C, SATA notification (SCR4:SNotification)
    fbs: u32, // 0x40, FIS-based switch control
    rsv1: [11]u32, // 0x44 ~ 0x6F, Reserved
    vendor: [4]u32, // 0x70 ~ 0x7F, vendor specific
};

pub const Signature = enum(u32) {
    SATA = 0x101,
    ATAPI = 0xEB140101,
    _,
};
