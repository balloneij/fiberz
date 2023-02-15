const std = @import("std");
const testing = std.testing;

const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const panic = std.debug.panic;

const Type = std.builtin.Type;

const Runtime = struct {
    pub fn init() Runtime {
        return Runtime{};
    }
};

const CooperativeScheduler = struct {
    const FiberFn = fn (anytype) anyopaque;

    allocator: Allocator,
    fibers: ArrayList(*anyopaque),

    pub fn init(allocator: Allocator) CooperativeScheduler {
        return .{
            .allocator = allocator,
            .fibers = ArrayList(*anyopaque).init(allocator),
        };
    }

    pub fn deinit(self: *CooperativeScheduler) void {
        if (self.fibers.items.len > 0) {
            panic("Deinit {s} when there are still {} fibers running", .{ @typeName(CooperativeScheduler), self.fibers.items.len });
        }
        self.fibers.deinit();
    }

    pub fn runtime(self: *CooperativeScheduler) Runtime {
        _ = self;
        return Runtime.init();
    }

    pub fn addFiber(self: *CooperativeScheduler, fiber: *anyopaque) void {
        try self.fibers.append(*fiber);
    }

    pub fn removeFiber(self: *CooperativeScheduler, fiber: *anyopaque) void {
        const ptr = @ptrToInt(fiber);
        var i: usize = 0;
        while (@ptrToInt(self.fibers.items[i]) != ptr and i < self.fibers.items.len) {
            i += 1;
        }

        if (i == self.fibers.items.len) {
            panic("Attempted to remove a fiber that doesn't exist in runtime");
        }

        _ = self.fibers.orderedRemove(i);
    }

    pub fn createFiber(self: *CooperativeScheduler, comptime func: anytype) !*Fiber(func) {
        var fiber = try self.allocator.create(Fiber(func));
        self.addFiber(fiber);
        try self.fibers.append(fiber);
        return fiber;
    }

    pub fn destroyFiber(self: *CooperativeScheduler, comptime FiberType: anytype, fiber: *FiberType) void {
        self.removeFiber(fiber);
        self.allocator.destroy(fiber);
    }
};

fn FiberContext(comptime Input: type, comptime Output: type) type {
    return struct {
        const Self = @This();

        const InputType = Input;
        const OutputType = Output;
        const SuspensionFrame = @Frame(suspension);

        input: **Input,
        output: *Output,
        suspension_frame: *SuspensionFrame,
        fiber_state: *FiberState,

        pub fn yield(self: Self, value: Output) *SuspensionFrame {
            self.fiber_state.* = .Yielded;
            self.output.* = value;
            self.suspension_frame.* = async suspension(self.input);
            return self.suspension_frame;
        }

        fn suspension(fiber_input: **Input) InputType {
            var input: Input = undefined;
            fiber_input.* = &input;
            suspend {}
            return input;
        }
    };
}

const FiberState = enum {
    Ready,
    Yielded,
    Finished,
};

fn Fiber(comptime func: anytype) type {
    const FuncType = @TypeOf(func);
    const type_info = @typeInfo(FuncType);
    const ReturnType = type_info.Fn.return_type.?;
    const ContextType = type_info.Fn.args[0].arg_type.?;
    const InputType = ContextType.InputType;
    const OutputType = ContextType.OutputType;
    const Arg = type_info.Fn.args[1].arg_type.?;

    return struct {
        const Self = @This();

        runtime: Runtime,

        frame: anyframe->ReturnType = undefined,
        frame_buffer: [@sizeOf(@Frame(func))]u8 align(@alignOf(@Frame(func))) = undefined,
        suspension_frame: ContextType.SuspensionFrame = undefined,

        input: *InputType = undefined,
        output: InputType = undefined,
        result_value: ReturnType = undefined,

        state: FiberState = .Ready,

        pub fn init(runtime: Runtime) Self {
            return Self{ .runtime = runtime };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Run the fiber until yield or completion.
        pub fn start(self: *Self, arg: Arg) void {
            switch (self.state) {
                .Ready => {
                    const context = ContextType{
                        .input = &self.input,
                        .output = &self.output,
                        .suspension_frame = &self.suspension_frame,
                        .fiber_state = &self.state,
                    };
                    self.frame = @asyncCall(&self.frame_buffer, &self.result_value, func, .{ context, arg });

                    nosuspend {
                        _ = await self.frame;
                    }

                    if (self.state == .Ready) {
                        // No yields were encountered. Fiber ran to completion
                        self.state = .Finished;
                    }
                },
                .Yielded => panic("Fiber is yielded", .{}),
                .Finished => panic("Fiber is finished", .{}),
            }
        }

        /// Run the fiber until completion. Panics if the fiber yields.
        /// Use start() if a yield is expected.
        pub fn call(self: *Self, arg: Arg) ReturnType {
            self.start(arg);

            switch (self.state) {
                .Finished => return self.result_value,
                .Yielded => panic("Fiber yielded and did not complete", .{}),
                .Ready => unreachable,
            }
        }

        pub fn is_complete(self: *Self) bool {
            return self.state == .Finished;
        }

        /// Returns the result if fiber function has returned.
        pub fn result(self: *Self) ReturnType {
            switch (self.state) {
                .Finished => return self.result_value,
                .Yielded => panic("Fiber is yielded", .{}),
                .Ready => panic("Fiber is not started", .{}),
            }
        }

        /// Transfers control to the yielding fiber. Input value is given to
        /// the fiber as the return value of context.yield().
        pub fn transfer(self: *Self, input: InputType) void {
            switch (self.state) {
                .Yielded => {
                    self.input.* = input;
                    self.state = .Ready;

                    nosuspend {
                        resume self.suspension_frame;
                        _ = await self.frame;
                    }

                    if (self.state == .Ready) {
                        // No yields were encountered. Fiber ran to completion
                        self.state = .Finished;
                    }
                },
                .Ready, .Finished => unreachable,
            }
        }

        pub fn is_yielded(self: *Self) bool {
            return self.state == .Yielded;
        }

        pub fn yieldResult(self: *Self) OutputType {
            switch (self.state) {
                .Yielded => return self.output,
                .Finished => panic("Fiber is finished", .{}),
                .Ready => panic("Fiber is not started", .{}),
            }
        }
    };
}

fn add(context: FiberContext(i32, i32), y: i32) i32 {
    const x = await context.yield(3);
    return x + y;
}

fn addOne(context: FiberContext(void, void), x: i32) i32 {
    _ = context;

    suspend {
        resume @frame();
    }

    return x + 1;
}

test {
    var scheduler = CooperativeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    const runtime = scheduler.runtime();

    var fiber = Fiber(add).init(runtime);
    defer fiber.deinit();

    fiber.start(2);

    var x = fiber.yieldResult();
    try testing.expect(x == 3);

    fiber.transfer(5);

    var z = fiber.result();
    try testing.expectEqual(z, 7);
}

test "No yields" {
    var scheduler = CooperativeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    const runtime = scheduler.runtime();

    var fiber = Fiber(addOne).init(runtime);
    defer fiber.deinit();

    var x = fiber.call(1);
    try testing.expect(x == 2);
}
