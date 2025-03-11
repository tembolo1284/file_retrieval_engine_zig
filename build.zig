// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add the common module that will be shared by all executables
    const common_module = b.addModule("common", .{
        .source_file = .{ .path = "src/common/thread_pool.zig" },
    });

    // Add server module
    const server_module = b.addModule("server", .{
        .source_file = .{ .path = "src/server/index_store/index_store.zig" },
        .dependencies = &.{
            .{ .name = "common", .module = common_module },
        },
    });

    // Add client module
    const client_module = b.addModule("client", .{
        .source_file = .{ .path = "src/client/engine.zig" },
        .dependencies = &.{
            .{ .name = "common", .module = common_module },
        },
    });

    // --- SERVER EXECUTABLE ---
    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_source_file = .{ .path = "src/bin/server.zig" },
        .target = target,
        .optimize = optimize,
    });
    server_exe.addModule("server", server_module);
    server_exe.addModule("common", common_module);
    b.installArtifact(server_exe);

    // --- CLIENT EXECUTABLE ---
    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_source_file = .{ .path = "src/bin/client.zig" },
        .target = target,
        .optimize = optimize,
    });
    client_exe.addModule("client", client_module);
    client_exe.addModule("common", common_module);
    b.installArtifact(client_exe);

    // --- BENCHMARK EXECUTABLE ---
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = .{ .path = "src/bin/benchmark.zig" },
        .target = target,
        .optimize = optimize,
    });
    benchmark_exe.addModule("client", client_module);
    benchmark_exe.addModule("common", common_module);
    b.installArtifact(benchmark_exe);

    // Add run steps
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_cmd.step.dependOn(b.getInstallStep());
    const run_server_step = b.step("run-server", "Run the server");
    run_server_step.dependOn(&run_server_cmd.step);

    const run_client_cmd = b.addRunArtifact(client_exe);
    run_client_cmd.step.dependOn(b.getInstallStep());
    const run_client_step = b.step("run-client", "Run the client");
    run_client_step.dependOn(&run_client_cmd.step);

    const run_benchmark_cmd = b.addRunArtifact(benchmark_exe);
    run_benchmark_cmd.step.dependOn(b.getInstallStep());
    const run_benchmark_step = b.step("run-benchmark", "Run the benchmark");
    run_benchmark_step.dependOn(&run_benchmark_cmd.step);

    // Add tests
    const test_step = b.step("test", "Run all tests");
    
    const server_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/server/index_store/index_store.zig" },
        .target = target,
        .optimize = optimize,
    });
    server_tests.addModule("common", common_module);
    
    const client_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/client/engine.zig" },
        .target = target,
        .optimize = optimize,
    });
    client_tests.addModule("common", common_module);
    
    const common_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/common/thread_pool.zig" },
        .target = target,
        .optimize = optimize,
    });
    
    const run_server_tests = b.addRunArtifact(server_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    const run_common_tests = b.addRunArtifact(common_tests);
    
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_client_tests.step);
    test_step.dependOn(&run_common_tests.step);
}
