pub const Module = extern struct {
    context: *anyopaque,
    init: fn (context: *anyopaque) void,
    deinit: fn (context: *anyopaque) void,

    pub fn new(init: fn (*anyopaque) void, deinit: fn (*anyopaque) void) void {}
};

// pub fn Module(context: type, init: ) type {

// }
