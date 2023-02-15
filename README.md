
# Fiberz

Fibers in Zig.

## TODO

- Create fibers from within fibers using the `FiberContext`
- Allow ommitting the `FiberContext` in fiber functions when it isn't used
- Use `@call` instead of `@asyncCall` when the fiber function is sync
- Implement a fiber runtime that has a thread pool
- Allow passing an arbirtrary number of args to a fiber function

