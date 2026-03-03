const std = @import("std");
const pyoz = @import("PyOZ");
const version = @import("version");

const project = @import("project.zig");
const builder = @import("builder.zig");
const commands = @import("commands.zig");
const wheel = @import("wheel.zig");

const InitArgs = pyoz.Args(struct {
    name: ?[]const u8 = null,
    in_current_dir: ?bool = null,
    local_pyoz_path: ?[]const u8 = null,
    package_layout: ?bool = null,
});

fn init_project(args: InitArgs) !void {
    try project.create(std.heap.page_allocator, args.value.name, args.value.in_current_dir orelse false, args.value.local_pyoz_path, args.value.package_layout orelse false);
}

const BuildArgs = pyoz.Args(struct {
    release: ?bool = null,
    stubs: ?bool = null,
});

fn build_wheel(args: BuildArgs) ![]const u8 {
    const alloc = std.heap.page_allocator;
    return try wheel.buildWheel(alloc, args.value.release orelse false, args.value.stubs orelse true);
}

fn develop_mode() !void {
    try builder.developMode(std.heap.page_allocator);
}

const PublishArgs = pyoz.Args(struct {
    test_pypi: ?bool = null,
});

fn publish_wheels(args: PublishArgs) !void {
    try wheel.publish(std.heap.page_allocator, args.value.test_pypi orelse false);
}

const TestArgs = pyoz.Args(struct {
    release: ?bool = null,
    verbose: ?bool = null,
});

fn run_tests(args: TestArgs) !void {
    var args_buf: [2][]const u8 = undefined;
    var args_len: usize = 0;
    if (args.value.release orelse false) {
        args_buf[args_len] = "--release";
        args_len += 1;
    }
    if (args.value.verbose orelse false) {
        args_buf[args_len] = "--verbose";
        args_len += 1;
    }
    try commands.runTests(std.heap.page_allocator, args_buf[0..args_len]);
}

fn run_bench() !void {
    const bench_args = [_][]const u8{};
    try commands.runBench(std.heap.page_allocator, &bench_args);
}

fn get_version() []const u8 {
    return version.string;
}

pub const PyOZCli = pyoz.module(.{
    .name = "_pyoz",
    .doc = "PyOZ native CLI library - build Python extensions in Zig",
    .classes = &.{},
    .funcs = &.{
        pyoz.kwfunc("init", init_project, "Create a new PyOZ project"),
        pyoz.kwfunc("build", build_wheel, "Build extension module and create wheel"),
        pyoz.func("develop", develop_mode, "Build and install in development mode"),
        pyoz.kwfunc("publish", publish_wheels, "Publish wheel(s) to PyPI"),
        pyoz.kwfunc("run_tests", run_tests, "Run embedded tests"),
        pyoz.func("run_bench", run_bench, "Run embedded benchmarks"),
        pyoz.func("version", get_version, "Get PyOZ version string"),
    },
    .consts = &.{
        pyoz.constant("__version__", version.string),
    },
});
