const std = @import("std");
const patch = @import("patch");
const PatchStep = patch.PatchStep;
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) void {
    @setEvalBranchQuota(10_000);
    const target = b.standardTargetOptions(.{});
    const target_triplet = target.result.linuxTriple(b.allocator) catch @panic("OOM");
    const native_target = b.resolveTargetQuery(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vm_platform_dill_option = b.option(LazyPath, "vm_platform_strong.dill", "vm_platform_strong.dill file");

    const mimalloc_dep = b.dependency("mimalloc", .{
        .target = native_target,
        .optimize = optimize,
    });
    const mimalloc_mod = mimalloc_dep.module("mimalloc");

    const clap_dep = b.dependency("clap", .{
        .target = native_target,
        .optimize = optimize,
    });
    const clap_mod = clap_dep.module("clap");

    const zeit_dep = b.dependency("zeit", .{
        .target = native_target,
        .optimize = optimize,
    });
    const zeit_mod = zeit_dep.module("zeit");

    const maybe_prebuilt_dart_dep = prebuilt_dart_dep: {
        if (native_target.result.os.tag == .windows) {
            if (native_target.result.cpu.arch == .x86_64) {
                break :prebuilt_dart_dep b.lazyDependency("prebuilt_dart_windows_x86_64", .{});
            }
            if (native_target.result.cpu.arch == .aarch64) {
                break :prebuilt_dart_dep b.lazyDependency("prebuilt_dart_windows_aarch64", .{});
            }
        }
        if (native_target.result.os.tag == .macos) {
            if (native_target.result.cpu.arch == .x86_64) {
                break :prebuilt_dart_dep b.lazyDependency("prebuilt_dart_macos_x86_64", .{});
            }
            if (native_target.result.cpu.arch == .aarch64) {
                break :prebuilt_dart_dep b.lazyDependency("prebuilt_dart_macos_aarch64", .{});
            }
        }
        if (native_target.result.os.tag == .linux) {
            if (native_target.result.cpu.arch == .x86_64) {
                break :prebuilt_dart_dep b.lazyDependency("prebuilt_dart_linux_x86_64", .{});
            }
            if (native_target.result.cpu.arch == .aarch64) {
                break :prebuilt_dart_dep b.lazyDependency("prebuilt_dart_linux_aarch64", .{});
            }
            if (native_target.result.cpu.arch == .arm) {
                break :prebuilt_dart_dep b.lazyDependency("prebuilt_dart_linux_arm", .{});
            }
            if (native_target.result.cpu.arch == .riscv64) {
                break :prebuilt_dart_dep b.lazyDependency("prebuilt_dart_linux_riscv64", .{});
            }
        }
        const fail = b.addFail("unsupported host");
        b.getInstallStep().dependOn(&fail.step);
        break :prebuilt_dart_dep null;
    };

    const upstream_dep = b.dependency("dart", .{});
    const third_party = upstream_dep.path("third_party");
    const pkg = upstream_dep.path("pkg");
    b.addNamedLazyPath("pkg", pkg);

    const dart_patch = PatchStep.create(b, .{
        .root_directory = upstream_dep.path("runtime"),
        .target = native_target,
        .optimize = optimize,
        .strip = 2,
    });
    dart_patch.addPatch(b.path("patch/0001-fix-global-pollution.patch"));
    dart_patch.addPatch(b.path("patch/0002-fix-rpc-str.patch"));
    dart_patch.addPatch(b.path("patch/0003-fix-double-conversion-include.patch"));
    dart_patch.addPatch(b.path("patch/0004-fix-msvc-only.patch"));
    dart_patch.addPatch(b.path("patch/0005-va-args.patch"));
    const runtime = dart_patch.getDirectory();
    b.addNamedLazyPath("runtime", runtime);

    const native_icu_dep = b.dependency("icu", .{
        .target = native_target,
        .optimize = optimize,
    });
    const native_icuuc = native_icu_dep.artifact("icuuc");
    const native_icui18n = native_icu_dep.artifact("icui18n");

    const icu_dep = b.dependency("icu", .{
        .target = target,
        .optimize = optimize,
    });
    const icuuc = icu_dep.artifact("icuuc");
    const icui18n = icu_dep.artifact("icui18n");

    const native_z_dep = b.dependency("z", .{
        .target = native_target,
        .optimize = optimize,
    });
    const native_z = native_z_dep.artifact("z");

    const z_dep = b.dependency("z", .{
        .target = target,
        .optimize = optimize,
    });
    const z = z_dep.artifact("z");

    const native_boringssl = b.dependency("boringssl", .{
        .target = native_target,
        .optimize = optimize,
    });
    const native_ssl = native_boringssl.artifact("ssl");

    const boringssl = b.dependency("boringssl", .{
        .target = target,
        .optimize = optimize,
    });
    const ssl = boringssl.artifact("ssl");

    const dart_custom_config = .{
        "-Wno-format",
        "-fms-extensions",
        "-DU_IMPORT=", // fixes icu linking problems with ms-extensions enabled
    };

    const dart_default_config = .{
        "-Wno-unused-parameter",
        "-Wno-unused-private-field",
        "-Wnon-virtual-dtor",
        "-Wvla",
        "-Woverloaded-virtual",
        "-Wno-comments",
        "-g3",
        "-ggdb3",
        "-fno-rtti",
        "-fno-exceptions",
        if (optimize == .Debug) "-DDEBUG" else "-DNDEBUG",
    };
    const dart_config = dart_default_config ++ dart_custom_config;
    const dart_precompiler_config = .{
        "-DDART_PRECOMPILER",
        "-fno-omit-frame-pointer",
        if (optimize == .Debug) "-DTARGET_USES_THREAD_SANITIZER" else "",
        if (optimize == .Debug) "-DTARGET_USES_MEMORY_SANITIZER" else "",
    };
    // TODO: find out how product mode works
    const dart_maybe_product_config = .{""};
    const dart_arch_config = dart_arch_config: {
        switch (target.result.cpu.arch) {
            .arm => break :dart_arch_config .{"-DTARGET_ARCH_ARM"},
            .aarch64 => break :dart_arch_config .{"-DTARGET_ARCH_ARM64"},
            .x86_64 => break :dart_arch_config .{"-DTARGET_ARCH_X64"},
            .x86 => break :dart_arch_config .{"-DTARGET_ARCH_IA32"},
            .riscv32 => break :dart_arch_config .{"-DTARGET_ARCH_RISCV32"},
            .riscv64 => break :dart_arch_config .{"-DTARGET_ARCH_RISCV64"},
            else => {
                const fail = b.addFail("unsupported target architecture");
                b.getInstallStep().dependOn(&fail.step);
                break :dart_arch_config .{""};
            },
        }
    };
    const dart_os_config = dart_os_config: {
        switch (target.result.os.tag) {
            .linux => {
                if (target.result.abi.isAndroid()) {
                    break :dart_os_config .{ "-DDART_TARGET_OS_ANDROID", "" };
                }
                break :dart_os_config .{ "-DDART_TARGET_OS_LINUX", "" };
            },
            .ios => break :dart_os_config .{ "-DDART_TARGET_OS_MACOS", "-DDART_TARGET_OS_MACOS_IOS" },
            .macos => break :dart_os_config .{ "-DART_TARGET_OS_MACOS", "" },
            .windows => break :dart_os_config .{ "-DART_TARGET_OS_WINDOWS", "" },
            else => {
                const fail = b.addFail("unsupported target os");
                b.getInstallStep().dependOn(&fail.step);
                break :dart_os_config .{ "", "" };
            },
        }
    };
    const _base_config = dart_arch_config ++ dart_config ++ dart_os_config;
    const _precompiler_base = dart_precompiler_config;
    const _maybe_product = dart_maybe_product_config;
    const _precompiler_config = _base_config ++ _precompiler_base ++ _maybe_product;
    const _jit_config = _base_config ++ _maybe_product;

    const bin_to_linkable_mod = b.createModule(.{
        .root_source_file = b.path("src/bin_to_linkable.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    bin_to_linkable_mod.addImport("mimalloc", mimalloc_mod);
    bin_to_linkable_mod.addImport("clap", clap_mod);
    const bin_to_linkable_exe = b.addExecutable(.{
        .name = "bin_to_linkable",
        .root_module = bin_to_linkable_mod,
    });

    const make_version_mod = b.createModule(.{
        .root_source_file = b.path("src/make_version.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    make_version_mod.addImport("mimalloc", mimalloc_mod);
    make_version_mod.addImport("clap", clap_mod);
    make_version_mod.addImport("zeit", zeit_mod);
    const make_version_exe = b.addExecutable(.{
        .name = "make_version",
        .root_module = make_version_mod,
    });

    const make_version_cmd = b.addRunArtifact(make_version_exe);
    make_version_cmd.addArg("--version_str");
    make_version_cmd.addArg("3.8.1");
    make_version_cmd.addArg("--runtime_dir");
    make_version_cmd.addDirectoryArg(runtime);
    make_version_cmd.addArg("--input");
    make_version_cmd.addFileArg(runtime.path(b, "vm/version_in.cc"));
    make_version_cmd.addArg("--output");
    const version_cc = make_version_cmd.addOutputFileArg("version.cc");
    inline for (vm_snapshot_files) |src| {
        make_version_cmd.addArg(src);
    }

    const native_libdouble_conversion = b.addLibrary(.{
        .name = "libdouble_conversion",
        .root_module = b.createModule(.{
            .target = native_target,
            .optimize = optimize,
        }),
    });
    native_libdouble_conversion.linkLibCpp();
    native_libdouble_conversion.addIncludePath(third_party.path(b, "double-conversion/src"));
    native_libdouble_conversion.addCSourceFiles(.{
        .root = third_party.path(b, "double-conversion/src"),
        .files = &.{
            "bignum-dtoa.cc",
            "bignum.cc",
            "cached-powers.cc",
            "double-to-string.cc",
            "fast-dtoa.cc",
            "fixed-dtoa.cc",
            "string-to-double.cc",
            "strtod.cc",
        },
        .flags = &(dart_arch_config ++ dart_config ++ dart_os_config),
    });
    native_libdouble_conversion.installHeadersDirectory(third_party.path(b, "double-conversion/src"), "double-conversion", .{});

    const libdouble_conversion = b.addLibrary(.{
        .name = "libdouble_conversion",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    libdouble_conversion.linkLibCpp();
    libdouble_conversion.addIncludePath(third_party.path(b, "double-conversion/src"));
    libdouble_conversion.addCSourceFiles(.{
        .root = third_party.path(b, "double-conversion/src"),
        .files = &.{
            "bignum-dtoa.cc",
            "bignum.cc",
            "cached-powers.cc",
            "double-to-string.cc",
            "fast-dtoa.cc",
            "fixed-dtoa.cc",
            "string-to-double.cc",
            "strtod.cc",
        },
        .flags = &(dart_arch_config ++ dart_config ++ dart_os_config),
    });
    libdouble_conversion.installHeadersDirectory(third_party.path(b, "double-conversion/src"), "double-conversion", .{});

    const libdart_compiler_precompiler = library_libdart_compiler(b, .{
        .name = "libdart_compiler_precompiler",
        .target = target,
        .optimize = optimize,
        .flags = &_precompiler_config,
        .runtime = runtime,
    });

    const libdart_vm_precompiler = library_libdart_vm(b, .{
        .name = "libdart_vm_precompiler",
        .target = native_target,
        .optimize = optimize,
        .flags = &_precompiler_config,
        .runtime = runtime,
        .icui18n = native_icui18n,
        .icuuc = native_icuuc,
        .libdouble_conversion = native_libdouble_conversion,
    });

    const libdart_lib_precompiler = library_libdart_lib(b, .{
        .name = "libdart_lib_precompiler",
        .target = native_target,
        .optimize = optimize,
        .flags = &_precompiler_config,
        .runtime = runtime,
    });

    const libdart_platform_no_tsan_precompiler = b.addLibrary(.{
        .name = "dart_platform_no_tsan_precompiler",
        .root_module = b.createModule(.{
            .target = native_target,
            .optimize = optimize,
        }),
    });
    libdart_platform_no_tsan_precompiler.root_module.sanitize_thread = false;
    libdart_platform_no_tsan_precompiler.linkLibCpp();
    libdart_platform_no_tsan_precompiler.addIncludePath(runtime);
    libdart_platform_no_tsan_precompiler.addCSourceFiles(.{
        .root = runtime.path(b, "platform"),
        .files = &.{"no_tsan.cc"},
        .flags = &_precompiler_config,
    });

    const libdart_platform_precompiler = library_libdart_platform(b, .{
        .name = "libdart_platform_precompiler",
        .target = native_target,
        .optimize = optimize,
        .flags = &_precompiler_config,
        .runtime = runtime,
        .version_cc = version_cc,
    });

    const libdart_precompiler = library_libdart(b, .{
        .name = "libdart_precompiler",
        .target = native_target,
        .optimize = optimize,
        .flags = &_precompiler_config,
        .runtime = runtime,
        .version_cc = version_cc,
    });

    const libdart_builtin = b.addLibrary(.{
        .name = "libdart_builtin",
        .root_module = b.createModule(.{
            .target = native_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(libdart_builtin);
    libdart_builtin.linkLibCpp();
    libdart_builtin.addIncludePath(runtime);
    inline for (builtin_impl_sources) |src| {
        comptime if (!std.mem.endsWith(u8, src, ".cc")) continue;
        libdart_builtin.addCSourceFile(.{
            .file = runtime.path(b, b.pathJoin(&.{ "bin", src })),
            .flags = &(dart_config ++ dart_maybe_product_config ++ dart_arch_config ++ dart_os_config),
        });
    }

    const gen_snapshot_dart_io = b.addLibrary(.{
        .name = "gen_snapshot_dart_io",
        .root_module = b.createModule(.{
            .target = native_target,
            .optimize = optimize,
        }),
    });
    gen_snapshot_dart_io.linkLibCpp();
    gen_snapshot_dart_io.linkLibrary(native_z);
    gen_snapshot_dart_io.linkLibrary(native_ssl);
    gen_snapshot_dart_io.addIncludePath(runtime);

    const gen_snapshot_dart_io_flags = dart_config ++ dart_precompiler_config ++ dart_maybe_product_config ++ dart_arch_config ++ dart_os_config ++ .{"-DDART_IO_SECURE_SOCKET_DISABLED"};
    inline for (io_impl_sources) |src| {
        comptime if (!std.mem.endsWith(u8, src, ".cc")) continue;
        gen_snapshot_dart_io.addCSourceFile(.{
            .file = runtime.path(b, b.pathJoin(&.{ "bin", src })),
            .flags = &gen_snapshot_dart_io_flags,
        });
    }
    gen_snapshot_dart_io.addCSourceFile(.{
        .file = runtime.path(b, "bin/io_natives.cc"),
        .flags = &gen_snapshot_dart_io_flags,
    });
    switch (gen_snapshot_dart_io.root_module.resolved_target.?.result.os.tag) {
        .macos, .ios => {
            gen_snapshot_dart_io.addCSourceFile(.{
                .file = runtime.path(b, "bin/platform_macos_cocoa.mm"),
                .flags = &gen_snapshot_dart_io_flags,
            });
        },
        else => {},
    }

    const gen_snapshot = b.addExecutable(.{
        .name = "gen_snapshot",
        .root_module = b.createModule(.{
            .target = native_target,
            .optimize = optimize,
        }),
    });
    gen_snapshot.root_module.sanitize_thread = false;
    gen_snapshot.linkLibCpp();
    gen_snapshot.linkLibrary(native_z);
    gen_snapshot.linkLibrary(native_icuuc);
    gen_snapshot.linkLibrary(native_icui18n);
    gen_snapshot.linkLibrary(gen_snapshot_dart_io);
    gen_snapshot.linkLibrary(libdart_builtin);
    gen_snapshot.linkLibrary(libdart_precompiler);
    gen_snapshot.linkLibrary(libdart_platform_precompiler);
    gen_snapshot.linkLibrary(libdart_platform_no_tsan_precompiler);
    gen_snapshot.linkLibrary(libdart_vm_precompiler);
    gen_snapshot.linkLibrary(libdart_lib_precompiler);
    gen_snapshot.linkLibrary(libdart_compiler_precompiler);
    switch (gen_snapshot.root_module.resolved_target.?.result.os.tag) {
        .windows => {
            gen_snapshot.linkSystemLibrary("iphlpapi");
            gen_snapshot.linkSystemLibrary("ws2_32");
            gen_snapshot.linkSystemLibrary("Rpcrt4");
            gen_snapshot.linkSystemLibrary("shlwapi");
            gen_snapshot.linkSystemLibrary("winmm");
            gen_snapshot.linkSystemLibrary("psapi");
            gen_snapshot.linkSystemLibrary("advapi32");
            gen_snapshot.linkSystemLibrary("shell32");
            gen_snapshot.linkSystemLibrary("ntdll");
            gen_snapshot.linkSystemLibrary("dbghelp");
            gen_snapshot.linkSystemLibrary("ole32");
            gen_snapshot.linkSystemLibrary("oleaut32");
            gen_snapshot.linkSystemLibrary("crypt32");
            gen_snapshot.linkSystemLibrary("bcrypt");
            gen_snapshot.linkSystemLibrary("api-ms-win-core-path-l1-1-0");

            const maybe_comsupp_dep = b.lazyDependency("comsupp", .{
                .target = gen_snapshot.root_module.resolved_target.?,
                .optimize = gen_snapshot.root_module.optimize.?,
            });
            if (maybe_comsupp_dep) |comsupp_dep| {
                gen_snapshot.linkLibrary(comsupp_dep.artifact("comsupp"));
            }
        },
        .macos, .ios => {
            gen_snapshot.linkFramework("CoreFoundation");
            gen_snapshot.linkFramework("CoreServices");
            gen_snapshot.linkFramework("Foundation");
        },
        else => {},
    }
    gen_snapshot.addIncludePath(runtime);
    gen_snapshot.addCSourceFiles(.{
        .root = runtime.path(b, "bin"),
        .files = &.{
            "builtin.cc",
            "error_exit.cc",
            "gzip.cc",
            "loader.cc",
            "snapshot_utils.cc",
            "builtin_gen_snapshot.cc",
            "dfe.cc",
            "gen_snapshot.cc",
            "options.cc",
            "vmservice_impl.cc",
        },
        .flags = &(dart_config ++ dart_precompiler_config ++ dart_maybe_product_config ++ dart_arch_config ++ dart_os_config ++ .{"-DEXCLUDE_CFE_AND_KERNEL_PLATFORM"}),
    });
    const package_config_step = PackageConfigStep.create(b);
    package_config_step.add("_fe_analyzer_shared", pkg.path(b, "_fe_analyzer_shared"), "lib");
    package_config_step.add("front_end", pkg.path(b, "front_end"), "lib");
    package_config_step.add("kernel", pkg.path(b, "kernel"), "lib");
    package_config_step.add("compiler", pkg.path(b, "compiler"), "lib");
    package_config_step.add("dart2wasm", pkg.path(b, "dart2wasm"), "lib");
    package_config_step.add("dev_compiler", pkg.path(b, "dev_compiler"), "lib");
    package_config_step.add("vm", pkg.path(b, "vm"), "lib");
    package_config_step.add("build_integration", pkg.path(b, "build_integration"), "lib");
    package_config_step.add("vm_service", pkg.path(b, "vm_service"), "lib");
    package_config_step.add("_js_interop_checks", pkg.path(b, "_js_interop_checks"), "lib");
    package_config_step.add("js_runtime", pkg.path(b, "js_runtime"), "lib");
    package_config_step.add("meta", pkg.path(b, "meta"), "lib");
    package_config_step.add("wasm_builder", pkg.path(b, "wasm_builder"), "lib");
    package_config_step.add("record_use", pkg.path(b, "record_use"), "lib");

    const tools_dep = b.dependency("dart_tools", .{});
    package_config_step.add("package_config", tools_dep.path("pkgs/package_config"), "lib");
    package_config_step.add("yaml", tools_dep.path("pkgs/yaml"), "lib");
    package_config_step.add("collection", tools_dep.path("pkgs/collection"), "lib");
    package_config_step.add("source_span", tools_dep.path("pkgs/source_span"), "lib");
    package_config_step.add("string_scanner", tools_dep.path("pkgs/string_scanner"), "lib");
    package_config_step.add("term_glyph", tools_dep.path("pkgs/term_glyph"), "lib");
    package_config_step.add("pub_semver", tools_dep.path("pkgs/pub_semver"), "lib");

    const core_dep = b.dependency("dart_core", .{});
    package_config_step.add("collection", core_dep.path("pkgs/collection"), "lib");
    package_config_step.add("path", core_dep.path("pkgs/path"), "lib");
    package_config_step.add("args", core_dep.path("pkgs/args"), "lib");
    package_config_step.add("crypto", core_dep.path("pkgs/crypto"), "lib");
    package_config_step.add("typed_data", core_dep.path("pkgs/typed_data"), "lib");

    const package_config = package_config_step.getPath();
    b.addNamedLazyPath("package_config.json", package_config);

    const prebuilt_dart_exe: ?LazyPath = prebuilt_dart: {
        if (maybe_prebuilt_dart_dep) |prebuilt_dart_dep| {
            const ext = std.Target.exeFileExt(&native_target.result);
            break :prebuilt_dart prebuilt_dart_dep.path(b.fmt("bin/dart{s}", .{ext}));
        } else {
            break :prebuilt_dart null;
        }
    };

    const vm_platform_dill = vm_platform_dill_option orelse platform_dill: {
        const output, _ = gen_vm_platform(b, .{
            .dart_exe = prebuilt_dart_exe,
            .package_config = package_config,
            .pkg = pkg,
            .is_product = false,
            .exclude_source = false,
        });
        break :platform_dill output;
    };

    const kernel_service_dill = gen_kernel_service(b, .{
        .dart_exe = prebuilt_dart_exe,
        .package_config = package_config,
        .pkg = pkg,
        .vm_platform_strong = vm_platform_dill,
    });

    const vm_snapshot_data, const vm_snapshot_instructions, const isolate_snapshot_data, const isolate_snapshot_instructions = gen_snapshot_action(b, .{
        .exe = gen_snapshot,
        .platform_dill = vm_platform_dill,
    });

    const vm_snapshot_data_linkable = bin_to_linkable(b, .{
        .exe = bin_to_linkable_exe,
        .target = target_triplet,
        .input = vm_snapshot_data,
        .output = "vm_snapshot_data.S",
        .symbol = "kDartVmSnapshotData",
        .executable = false,
    });
    b.addNamedLazyPath("vm_snapshot_data_linkable", vm_snapshot_data_linkable);
    const vm_snapshot_instructions_linkable = bin_to_linkable(b, .{
        .exe = bin_to_linkable_exe,
        .target = target_triplet,
        .input = vm_snapshot_instructions,
        .output = "vm_snapshot_instructions.S",
        .symbol = "kDartVmSnapshotInstructions",
        .executable = true,
    });
    b.addNamedLazyPath("vm_snapshot_instructions_linkable", vm_snapshot_instructions_linkable);

    const isolate_snapshot_data_linkable = bin_to_linkable(b, .{
        .exe = bin_to_linkable_exe,
        .target = target_triplet,
        .input = isolate_snapshot_data,
        .output = "isolate_snapshot_data.S",
        .symbol = "kDartCoreIsolateSnapshotData",
        .executable = false,
    });
    b.addNamedLazyPath("isolate_snapshot_data_linkable", isolate_snapshot_data_linkable);
    const isolate_snapshot_instructions_linkable = bin_to_linkable(b, .{
        .exe = bin_to_linkable_exe,
        .target = target_triplet,
        .input = isolate_snapshot_instructions,
        .output = "isolate_snapshot_instructions.S",
        .symbol = "kDartCoreIsolateSnapshotInstructions",
        .executable = true,
    });
    b.addNamedLazyPath("isolate_snapshot_instructions_linkable", isolate_snapshot_instructions_linkable);

    const platform_strong_dill_linkable = bin_to_linkable(b, .{
        .exe = bin_to_linkable_exe,
        .target = target_triplet,
        .input = vm_platform_dill,
        .output = "vm_platform_strong.S",
        .symbol = "kPlatformStrongDill",
        .size_symbol = "kPlatformStrongDillSize",
        .executable = false,
    });
    b.addNamedLazyPath("platform_strong_dill_linkable", platform_strong_dill_linkable);
    const kernel_service_dill_linkable = bin_to_linkable(b, .{
        .exe = bin_to_linkable_exe,
        .target = target_triplet,
        .input = kernel_service_dill,
        .output = "kernel_service.S",
        .symbol = "kKernelServiceDill",
        .size_symbol = "kKernelServiceDillSize",
        .executable = false,
    });
    b.addNamedLazyPath("kernel_service_dill_linkable", kernel_service_dill_linkable);

    const libdart_jit = library_libdart(b, .{
        .name = "libdart_jit",
        .target = target,
        .optimize = optimize,
        .flags = &_jit_config,
        .runtime = runtime,
        .version_cc = version_cc,
    });
    b.installArtifact(libdart_jit);
    const libdart_platform_jit = library_libdart_platform(b, .{
        .name = "libdart_platform_jit",
        .target = target,
        .optimize = optimize,
        .flags = &_jit_config,
        .runtime = runtime,
        .version_cc = version_cc,
    });
    b.installArtifact(libdart_platform_jit);

    const standalone_dart_io = b.addLibrary(.{
        .name = "standalone_dart_io",
        .root_module = b.createModule(.{
            .target = native_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(standalone_dart_io);
    standalone_dart_io.linkLibCpp();
    standalone_dart_io.linkLibrary(native_z);
    standalone_dart_io.linkLibrary(native_ssl);
    standalone_dart_io.linkLibrary(libdart_builtin);
    standalone_dart_io.addIncludePath(runtime);

    const standalone_dart_io_flags = dart_config ++ dart_maybe_product_config ++ dart_arch_config ++ dart_os_config ++ .{"-DDART_IO_SECURE_SOCKET_DISABLED"};
    inline for (io_impl_sources) |src| {
        comptime if (!std.mem.endsWith(u8, src, ".cc")) continue;
        standalone_dart_io.addCSourceFile(.{
            .file = runtime.path(b, b.pathJoin(&.{ "bin", src })),
            .flags = &standalone_dart_io_flags,
        });
    }
    standalone_dart_io.addCSourceFiles(.{
        .root = runtime.path(b, "bin"),
        .files = &.{
            "builtin_natives.cc",
            "io_natives.cc",
        },
        .flags = &standalone_dart_io_flags,
    });
    switch (standalone_dart_io.root_module.resolved_target.?.result.os.tag) {
        .macos, .ios => {
            standalone_dart_io.addCSourceFile(.{
                .file = runtime.path(b, "bin/platform_macos_cocoa.mm"),
                .flags = &standalone_dart_io_flags,
            });
        },
        else => {},
    }

    const libdart_vm_jit = library_libdart_vm(b, .{
        .name = "libdart_vm_jit",
        .target = native_target,
        .optimize = optimize,
        .flags = &_jit_config,
        .runtime = runtime,
        .icui18n = native_icui18n,
        .icuuc = native_icuuc,
        .libdouble_conversion = native_libdouble_conversion,
    });
    b.installArtifact(libdart_vm_jit);
    const libdart_platform_no_tsan_jit = b.addLibrary(.{
        .name = "libdart_platform_no_tsan_jit",
        .root_module = b.createModule(.{
            .target = native_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(libdart_platform_no_tsan_jit);
    libdart_platform_no_tsan_jit.root_module.sanitize_thread = false;
    libdart_platform_no_tsan_jit.linkLibCpp();
    libdart_platform_no_tsan_jit.addIncludePath(runtime);
    libdart_platform_no_tsan_jit.addCSourceFiles(.{
        .root = runtime.path(b, "platform"),
        .files = &.{"no_tsan.cc"},
        .flags = &_jit_config,
    });

    const libdart_lib_jit = library_libdart_lib(b, .{
        .name = "libdart_lib_jit",
        .target = native_target,
        .optimize = optimize,
        .flags = &_jit_config,
        .runtime = runtime,
    });
    b.installArtifact(libdart_lib_jit);

    const libdart_compiler_jit = library_libdart_compiler(b, .{
        .name = "libdart_compiler_jit",
        .target = target,
        .optimize = optimize,
        .flags = &_jit_config,
        .runtime = runtime,
    });
    b.installArtifact(libdart_compiler_jit);

    const crashpad = b.addLibrary(.{
        .name = "crashpad",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(crashpad);
    crashpad.linkLibCpp();
    crashpad.addIncludePath(runtime);
    crashpad.addCSourceFiles(.{
        .root = runtime.path(b, "bin"),
        .files = &.{"crashpad.cc"},
        .flags = &(dart_arch_config ++ dart_config ++ dart_os_config),
    });

    const native_assets_api = b.addLibrary(.{
        .name = "native_assets_api",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(native_assets_api);
    native_assets_api.linkLibCpp();
    native_assets_api.addIncludePath(runtime);
    inline for (native_assets_impl_sources) |src| {
        native_assets_api.addCSourceFile(.{
            .file = runtime.path(b, b.pathJoin(&.{ "bin", src })),
            .flags = &(dart_config ++ dart_maybe_product_config ++ dart_os_config ++ dart_arch_config),
        });
    }

    const observatory = b.addLibrary(.{
        .name = "observatory",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(observatory);
    observatory.linkLibCpp();
    observatory.addIncludePath(runtime);
    observatory.addCSourceFiles(.{
        .root = runtime.path(b, "bin"),
        .files = &.{"observatory_assets_empty.cc"},
        .flags = &(dart_arch_config ++ dart_config ++ dart_os_config),
    });

    const dart = b.addExecutable(.{
        .name = "dart",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    dart.root_module.sanitize_thread = false;
    dart.linkLibCpp();
    dart.linkLibrary(z);
    dart.linkLibrary(ssl);
    dart.linkLibrary(icuuc);
    dart.linkLibrary(icui18n);
    dart.linkLibrary(libdart_jit);
    dart.linkLibrary(libdart_platform_jit);
    dart.linkLibrary(libdart_platform_no_tsan_jit);
    dart.linkLibrary(libdart_builtin);
    dart.linkLibrary(standalone_dart_io);
    dart.linkLibrary(libdart_vm_jit);
    dart.linkLibrary(libdart_compiler_jit);
    dart.linkLibrary(libdart_lib_jit);
    dart.linkLibrary(crashpad);
    dart.linkLibrary(native_assets_api);
    dart.linkLibrary(observatory);
    dart.addAssemblyFile(vm_snapshot_data_linkable);
    dart.addAssemblyFile(vm_snapshot_instructions_linkable);
    dart.addAssemblyFile(isolate_snapshot_data_linkable);
    dart.addAssemblyFile(isolate_snapshot_instructions_linkable);
    dart.addAssemblyFile(kernel_service_dill_linkable);
    dart.addAssemblyFile(platform_strong_dill_linkable);
    switch (dart.root_module.resolved_target.?.result.os.tag) {
        .windows => {
            dart.linkSystemLibrary("iphlpapi");
            dart.linkSystemLibrary("ws2_32");
            dart.linkSystemLibrary("Rpcrt4");
            dart.linkSystemLibrary("shlwapi");
            dart.linkSystemLibrary("winmm");
            dart.linkSystemLibrary("psapi");
            dart.linkSystemLibrary("advapi32");
            dart.linkSystemLibrary("shell32");
            dart.linkSystemLibrary("ntdll");
            dart.linkSystemLibrary("dbghelp");
            dart.linkSystemLibrary("ole32");
            dart.linkSystemLibrary("oleaut32");
            dart.linkSystemLibrary("crypt32");
            dart.linkSystemLibrary("bcrypt");
            dart.linkSystemLibrary("api-ms-win-core-path-l1-1-0");

            const maybe_comsupp_dep = b.lazyDependency("comsupp", .{
                .target = dart.root_module.resolved_target.?,
                .optimize = dart.root_module.optimize.?,
            });
            if (maybe_comsupp_dep) |comsupp_dep| {
                dart.linkLibrary(comsupp_dep.artifact("comsupp"));
            }
        },
        .macos, .ios => {
            dart.linkFramework("CoreFoundation");
            dart.linkFramework("CoreServices");
            dart.linkFramework("Foundation");
            dart.linkFramework("Security");
        },
        else => {},
    }
    dart.addIncludePath(runtime);
    const dart_flags = dart_arch_config ++ dart_config ++ dart_os_config ++ .{"-DDART_IO_SECURE_SOCKET_DISABLED"};
    // sources
    dart.addCSourceFiles(.{
        .root = runtime.path(b, "bin"),
        .files = &.{
            "dart_embedder_api_impl.cc",
            "error_exit.cc",
            "icu.cc",
            "main_options.cc",
            "options.cc",
            "snapshot_utils.cc",
            "vmservice_impl.cc",
        },
        .flags = &dart_flags,
    });
    // extra sources
    dart.addCSourceFiles(.{
        .root = runtime.path(b, "bin"),
        .files = &.{
            "builtin.cc",
            "dartdev_isolate.cc",
            "dfe.cc",
            "gzip.cc",
            "loader.cc",
            "main.cc",
            "main_impl.cc",
        },
        .flags = &dart_flags,
    });
    b.installArtifact(dart);

    const package_config_test_step = PackageConfigStep.create(b);
    var package_it = package_config_step.map.iterator();
    while (package_it.next()) |pkg_entry| {
        package_config_test_step.map.put(b.allocator, pkg_entry.key_ptr.*, pkg_entry.value_ptr.*) catch @panic("OOM");
    }
    package_config_test_step.add("test_runner", pkg.path(b, "test_runner"), "lib");
    package_config_test_step.add("smith", pkg.path(b, "smith"), "lib");
    package_config_test_step.add("status_file", pkg.path(b, "status_file"), "lib");
    package_config_test_step.add("shell_arg_splitter", pkg.path(b, "shell_arg_splitter"), "lib");
    package_config_test_step.add("dart2js_tools", pkg.path(b, "dart2js_tools"), "lib");
    package_config_test_step.add("expect", pkg.path(b, "expect"), "lib");
    package_config_test_step.add("async_helper", pkg.path(b, "async_helper"), "lib");
    package_config_test_step.add("native_stack_traces", pkg.path(b, "native_stack_traces"), "lib");
    package_config_test_step.add("dart_internal", pkg.path(b, "dart_internal"), "lib");

    package_config_test_step.add("pool", tools_dep.path("pkgs/pool"), "lib");
    package_config_test_step.add("stack_trace", tools_dep.path("pkgs/stack_trace"), "lib");
    package_config_test_step.add("source_maps", tools_dep.path("pkgs/source_maps"), "lib");
    package_config_test_step.add("boolean_selector", tools_dep.path("pkgs/boolean_selector"), "lib");

    package_config_test_step.add("async", core_dep.path("pkgs/async"), "lib");

    const webdriver_dep = b.dependency("dart_webdriver", .{});
    package_config_test_step.add("webdriver", webdriver_dep.path("."), "lib");

    const test_dep = b.dependency("dart_test", .{});
    package_config_test_step.add("matcher", test_dep.path("pkgs/matcher"), "lib");
    package_config_test_step.add("test_api", test_dep.path("pkgs/test_api"), "lib");

    const sync_http_dep = b.dependency("dart_sync_http", .{});
    package_config_test_step.add("sync_http", sync_http_dep.path("."), "lib");

    const native_dep = b.dependency("dart_native", .{});
    package_config_test_step.add("ffi", native_dep.path("pkgs/ffi"), "lib");

    const package_config_test = package_config_test_step.getPath();

    const ffi_test_dynamic_library = b.addLibrary(.{
        .name = "ffi_test_dynamic_library",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .Debug,
        }),
        .linkage = .dynamic,
    });
    ffi_test_dynamic_library.linkLibCpp();
    ffi_test_dynamic_library.addIncludePath(runtime);
    ffi_test_dynamic_library.addCSourceFile(.{
        .file = runtime.path(b, "bin/ffi_test/ffi_test_dynamic_library.cc"),
        .flags = &.{""},
    });
    const install_ffi_test_dynamic_library = b.addInstallArtifact(ffi_test_dynamic_library, .{});

    const ffi_test_functions = b.addLibrary(.{
        .name = "ffi_test_functions",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .Debug,
        }),
        .linkage = .dynamic,
    });
    ffi_test_functions.linkLibCpp();
    ffi_test_functions.addIncludePath(runtime);
    ffi_test_functions.addCSourceFiles(.{
        .root = runtime.path(b, "bin"),
        .files = &.{
            "../include/dart_api_dl.c",
            "ffi_test/ffi_test_fields.c",
            "ffi_test/ffi_test_functions.cc",
            "ffi_test/ffi_test_functions_generated.cc",
            "ffi_test/ffi_test_functions_generated_2.cc",
            "ffi_test/ffi_test_functions_vmspecific.cc",
        },
        .flags = &.{""},
    });
    if (ffi_test_functions.root_module.resolved_target.?.result.os.tag == .windows) {
        ffi_test_functions.addCSourceFile(.{
            .file = runtime.path(b, "bin/dart_api_win.c"),
            .flags = &.{""},
        });
    }
    ffi_test_functions.addAssemblyFile(
        switch (ffi_test_functions.root_module.resolved_target.?.result.cpu.arch) {
            .x86_64 => runtime.path(b, "bin/ffi_test/clobber_x64.S"),
            .x86 => runtime.path(b, "bin/ffi_test/clobber_x86.S"),
            .arm => runtime.path(b, "bin/ffi_test/clobber_arm.S"),
            .aarch64 => runtime.path(b, "bin/ffi_test/clobber_arm64.S"),
            .riscv32 => runtime.path(b, "bin/ffi_test/clobber_riscv32.S"),
            .riscv64 => runtime.path(b, "bin/ffi_test/clobber_riscv64.S"),
            else => @panic("Unsupported architecture"),
        },
    );
    const install_ffi_test_functions = b.addInstallArtifact(ffi_test_functions, .{});

    // use the prebuilt dart instead of the compile one
    // in order to rule out test runner errors
    const test_cmd = test_cmd: {
        if (prebuilt_dart_exe) |dart_exe| {
            const dart_cmd = std.Build.Step.Run.create(b, "run dart test suite");
            dart_cmd.addFileArg(dart_exe);
            break :test_cmd dart_cmd;
        } else {
            const dart_cmd = b.addSystemCommand(&.{"dart"});
            break :test_cmd dart_cmd;
        }
    };
    test_cmd.setCwd(upstream_dep.path("."));
    test_cmd.addPrefixedFileArg("--packages=", package_config_test);
    test_cmd.addFileArg(pkg.path(b, "test_runner/bin/test_runner.dart"));
    test_cmd.addPrefixedFileArg("--packages=", package_config_test);
    test_cmd.addPrefixedFileArg("--dart=", dart.getEmittedBin());
    if (optimize != .ReleaseFast) {
        // it is very slow
        test_cmd.addArg("--timeout=180");
    } else {
        test_cmd.addArg("--timeout=30");
    }
    test_cmd.addArg("corelib");
    test_cmd.addArg("ffi");
    test_cmd.addArg("language");
    test_cmd.addArg("lib");
    test_cmd.addArg("samples");
    test_cmd.addArg("standalone");

    test_cmd.step.dependOn(&install_ffi_test_dynamic_library.step);
    test_cmd.step.dependOn(&install_ffi_test_functions.step);
    test_cmd.addPathDir(b.exe_dir);

    const test_step = b.step("test", "Run the dart test suite");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_cmd.step);
}

fn bin_to_linkable(b: *std.Build, options: struct {
    exe: *std.Build.Step.Compile,
    target: []const u8,
    input: LazyPath,
    output: []const u8,
    symbol: []const u8,
    size_symbol: ?[]const u8 = null,
    executable: bool,
}) LazyPath {
    const cmd = b.addRunArtifact(options.exe);
    cmd.addArg("--target");
    cmd.addArg(options.target);
    cmd.addArg("--input");
    cmd.addFileArg(options.input);
    cmd.addArg("--output");
    const output = cmd.addOutputFileArg(options.output);
    cmd.addArg("--symbol_name");
    cmd.addArg(options.symbol);
    if (options.size_symbol) |size_symbol| {
        cmd.addArg("--size_symbol_name");
        cmd.addArg(size_symbol);
    }
    if (options.executable) {
        cmd.addArg("--executable");
    }

    return output;
}

fn gen_snapshot_action(b: *std.Build, options: struct {
    exe: *std.Build.Step.Compile,
    platform_dill: LazyPath,
}) std.meta.Tuple(&.{ LazyPath, LazyPath, LazyPath, LazyPath }) {
    const cmd = b.addRunArtifact(options.exe);
    cmd.addArg("--deterministic");
    cmd.addArg("--snapshot_kind=core");
    const vm_snapshot_data = cmd.addPrefixedOutputFileArg("--vm_snapshot_data=", "vm_snapshot_data.bin");
    const vm_snapshot_instructions = cmd.addPrefixedOutputFileArg("--vm_snapshot_instructions=", "vm_snapshot_instructions.bin");
    const isolate_snapshot_data = cmd.addPrefixedOutputFileArg("--isolate_snapshot_data=", "isolate_snapshot_data.bin");
    const isolate_snapshot_instructions = cmd.addPrefixedOutputFileArg("--isolate_snapshot_instructions=", "isolate_snapshot_instructions.bin");
    cmd.addFileArg(options.platform_dill);
    return .{ vm_snapshot_data, vm_snapshot_instructions, isolate_snapshot_data, isolate_snapshot_instructions };
}

fn library_libdart(b: *std.Build, options: struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags: []const []const u8,
    runtime: LazyPath,
    version_cc: LazyPath,
}) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    lib.linkLibCpp();
    lib.addIncludePath(options.runtime);
    lib.addCSourceFile(.{
        .file = options.version_cc,
        .flags = options.flags,
    });
    lib.addCSourceFiles(.{
        .root = options.runtime,
        .files = &.{
            "vm/analyze_snapshot_api_impl.cc",
            "vm/dart_api_impl.cc",
            "vm/native_api_impl.cc",
        },
        .flags = options.flags,
    });
    return lib;
}

fn library_libdart_platform(b: *std.Build, options: struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags: []const []const u8,
    runtime: LazyPath,
    version_cc: LazyPath,
}) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    lib.linkLibCpp();
    lib.addIncludePath(options.runtime);
    inline for (platform_sources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "platform", src })),
            .flags = options.flags,
        });
    }
    return lib;
}

fn library_libdart_vm(b: *std.Build, options: struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags: []const []const u8,
    runtime: LazyPath,
    icui18n: *std.Build.Step.Compile,
    icuuc: *std.Build.Step.Compile,
    libdouble_conversion: *std.Build.Step.Compile,
}) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    lib.linkLibCpp();
    lib.linkLibrary(options.icui18n);
    lib.linkLibrary(options.icuuc);
    lib.linkLibrary(options.libdouble_conversion);
    lib.addIncludePath(options.runtime);
    inline for (vm_sources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "vm", src })),
            .flags = options.flags,
        });
    }
    inline for (compiler_api_sources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "vm/compiler", src })),
            .flags = options.flags,
        });
    }
    inline for (disassembler_sources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "vm/compiler", src })),
            .flags = options.flags,
        });
    }
    inline for (ffi_sources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "vm/ffi", src })),
            .flags = options.flags,
        });
    }
    inline for (heap_sources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "vm/heap", src })),
            .flags = options.flags,
        });
    }
    inline for (regexp_sources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "vm/regexp", src })),
            .flags = options.flags,
        });
    }
    return lib;
}

fn library_libdart_compiler(b: *std.Build, options: struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags: []const []const u8,
    runtime: LazyPath,
}) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    lib.linkLibCpp();
    lib.addIncludePath(options.runtime);
    inline for (compiler_sources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "vm", "compiler", src })),
            .flags = options.flags,
        });
    }
    return lib;
}

fn library_libdart_lib(b: *std.Build, options: struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags: []const []const u8,
    runtime: LazyPath,
}) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    lib.linkLibCpp();
    lib.addIncludePath(options.runtime);
    lib.addCSourceFile(.{
        .file = options.runtime.path(b, "vm/bootstrap.cc"),
        .flags = options.flags,
    });
    inline for (allsources) |src| {
        lib.addCSourceFile(.{
            .file = options.runtime.path(b, b.pathJoin(&.{ "lib", src })),
            .flags = options.flags,
        });
    }
    return lib;
}

fn gen_vm_platform(b: *std.Build, options: struct {
    dart_exe: ?LazyPath,
    pkg: LazyPath,
    package_config: LazyPath,
    is_product: bool,
    exclude_source: bool,
    libraries: ?[]const u8 = null,
}) std.meta.Tuple(&.{ LazyPath, LazyPath }) {
    const cmd = cmd: {
        if (options.dart_exe) |dart_exe| {
            const dart_cmd = std.Build.Step.Run.create(b, "run dart");
            dart_cmd.addFileArg(dart_exe);
            break :cmd dart_cmd;
        } else {
            const dart_cmd = b.addSystemCommand(&.{"dart"});
            break :cmd dart_cmd;
        }
    };

    cmd.addPrefixedFileArg("--packages=", options.package_config);
    cmd.addFileArg(options.pkg.path(b, "front_end/tool/compile_platform.dart"));
    cmd.addArg("dart:core");
    if (options.is_product) {
        cmd.addArg("-Ddart.vm.product=true");
    } else {
        cmd.addArg("-Ddart.vm.product=false");
    }
    cmd.addArg("-Ddart.isVM=true");
    if (options.exclude_source) {
        cmd.addArg("--exclude-source");
    }
    if (options.libraries) |libraries| {
        cmd.addArg(libraries);
    } else {
        cmd.addArg("--single-root-scheme=org-dartlang-sdk");
        cmd.addPrefixedDirectoryArg("--single-root-base=", options.pkg.path(b, ".."));
        cmd.addArg("org-dartlang-sdk:///sdk/lib/libraries.json");
    }
    _ = cmd.addOutputFileArg("vm_outline_strong.dill");
    const vm_platform = cmd.addOutputFileArg("vm_platform_strong.dill");
    const vm_outline = cmd.addOutputFileArg("vm_outline_strong.dill");

    return .{ vm_platform, vm_outline };
}

pub fn genVmPlatform(b: *std.Build, options: struct {
    dart_exe: ?LazyPath = null,
    pkg: ?LazyPath = null,
    package_config: ?LazyPath = null,
    is_product: bool,
    exclude_source: bool,
    libraries: ?[]const u8,
}) std.meta.Tuple(&.{ LazyPath, LazyPath }) {
    const this_dep = b.dependencyFromBuildZig(@This(), .{});
    return gen_vm_platform(b, .{
        .dart_exe = options.dart_exe orelse this_dep.namedLazyPath("prebuilt_dart"),
        .pkg = options.pkg orelse this_dep.namedLazyPath("pkg"),
        .package_config = options.package_config orelse this_dep.namedLazyPath("package_config.json"),
        .is_product = options.is_product,
        .exclude_source = options.exclude_source,
        .libraries = options.libraries,
    });
}

pub fn gen_kernel_service(b: *std.Build, options: struct {
    dart_exe: ?LazyPath,
    pkg: LazyPath,
    package_config: LazyPath,
    vm_platform_strong: LazyPath,
}) LazyPath {
    const cmd = cmd: {
        if (options.dart_exe) |dart_exe| {
            const dart_cmd = std.Build.Step.Run.create(b, "run dart");
            dart_cmd.addFileArg(dart_exe);
            break :cmd dart_cmd;
        } else {
            const dart_cmd = b.addSystemCommand(&.{"dart"});
            break :cmd dart_cmd;
        }
    };
    cmd.addPrefixedFileArg("--packages=", options.package_config);
    cmd.addFileArg(options.pkg.path(b, "vm/bin/gen_kernel.dart"));
    cmd.addPrefixedFileArg("--packages=", options.package_config);
    cmd.addPrefixedFileArg("--platform=", options.vm_platform_strong);
    cmd.addPrefixedDirectoryArg("--filesystem-root=", options.pkg.path(b, ".."));
    cmd.addArg("--filesystem-scheme=org-dartlang-kernel-service");
    cmd.addArg("--no-aot");
    cmd.addArg("--no-embed-sources");
    const dill = cmd.addPrefixedOutputFileArg("--output=", "kernel_service.dill");
    cmd.addArg("org-dartlang-kernel-service:///pkg/vm/bin/kernel_service.dart");

    return dill;
}

pub const PackageConfigStep = struct {
    const Entry = struct {
        root_path: LazyPath,
        sub_path: []const u8,
    };
    step: std.Build.Step,
    map: std.StringHashMapUnmanaged(Entry),
    generated_file: std.Build.GeneratedFile,

    pub fn create(b: *std.Build) *PackageConfigStep {
        const step = std.Build.Step.init(.{
            .id = .custom,
            .name = "write .packages",
            .owner = b,
            .makeFn = make,
        });

        const packages = b.allocator.create(PackageConfigStep) catch @panic("OOM");
        packages.* = .{
            .step = step,
            .map = .{},
            .generated_file = .{ .step = &packages.step },
        };
        return packages;
    }

    pub fn add(packages: *PackageConfigStep, name: []const u8, root_path: LazyPath, sub_path: []const u8) void {
        const allocator = packages.step.owner.allocator;
        root_path.addStepDependencies(&packages.step);
        packages.map.put(allocator, name, .{
            .root_path = root_path,
            .sub_path = sub_path,
        }) catch @panic("OOM");
    }

    pub fn getPath(packages: *const PackageConfigStep) LazyPath {
        return .{ .generated = .{ .file = &packages.generated_file } };
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const b = step.owner;
        const allocator = b.allocator;
        const packages: *PackageConfigStep = @fieldParentPtr("step", step);
        step.clearWatchInputs();

        var man = b.graph.cache.obtain();
        defer man.deinit();
        man.hash.add(@as(u32, 0x43da6fb6));

        {
            var it = packages.map.iterator();
            while (it.next()) |entry| {
                man.hash.addBytes(entry.key_ptr.*);
                const item = entry.value_ptr.*;
                const path = item.root_path.getPath3(b, step);
                const abs_path = b.pathResolve(&.{ path.root_dir.path orelse ".", path.sub_path });
                man.hash.addBytes(abs_path);
                man.hash.addBytes(item.sub_path);
            }
        }

        if (try step.cacheHitAndWatch(&man)) {
            const digest = man.final();
            packages.generated_file.path = try b.cache_root.join(allocator, &.{ "o", &digest, "package_config.json" });
            return;
        }

        const digest = man.final();
        packages.generated_file.path = try b.cache_root.join(allocator, &.{ "o", &digest, "package_config.json" });
        const cache_path = b.pathJoin(&.{ "o", &digest });

        var cache_dir = b.cache_root.handle.makeOpenPath(cache_path, .{}) catch |err| {
            return step.fail("unable to make path '{f}{s}': {s}", .{
                b.cache_root, cache_path, @errorName(err),
            });
        };
        defer cache_dir.close();

        var file = cache_dir.createFile("package_config.json", .{}) catch |err| {
            return step.fail("unable to create file '{f}{s}': {s}", .{
                b.cache_root, "package_config.json", @errorName(err),
            });
        };
        defer file.close();
        var file_buffer: [1024]u8 = undefined;
        var file_writer = file.writer(&file_buffer);

        var stream: std.json.Stringify = .{
            .writer = &file_writer.interface,
            .options = .{ .whitespace = .indent_2 },
        };

        try stream.beginObject();
        try stream.objectField("configVersion");
        try stream.write(2);
        try stream.objectField("packages");
        try stream.beginArray();
        {
            var it = packages.map.iterator();
            while (it.next()) |entry| {
                try stream.beginObject();
                try stream.objectField("name");
                try stream.write(entry.key_ptr.*);
                try stream.objectField("rootUri");
                const item = entry.value_ptr.*;
                const path = item.root_path.getPath3(b, step);
                const abs_path = b.pathResolve(&.{ path.root_dir.path orelse ".", path.sub_path });
                if (abs_path.len > 2 and abs_path[1] == ':') {
                    std.mem.replaceScalar(u8, abs_path, '\\', '/');
                    try stream.write(b.fmt("file:///{s}", .{abs_path}));
                } else {
                    try stream.write(b.fmt("file://{s}", .{abs_path}));
                }
                try stream.objectField("packageUri");
                try stream.write(item.sub_path);
                try stream.endObject();
            }
        }
        try stream.endArray();
        try stream.endObject();
        try file_writer.interface.flush();
        try man.writeManifest();
    }
};

const io_impl_sources = .{
    "console_posix.cc",
    "console_win.cc",
    "eventhandler.cc",
    "eventhandler_fuchsia.cc",
    "eventhandler_linux.cc",
    "eventhandler_macos.cc",
    "eventhandler_win.cc",
    "file_system_watcher.cc",
    "file_system_watcher_fuchsia.cc",
    "file_system_watcher_linux.cc",
    "file_system_watcher_macos.cc",
    "file_system_watcher_win.cc",
    "filter.cc",
    "ifaddrs.cc",
    "io_service.cc",
    "io_service_no_ssl.cc",
    "namespace.cc",
    "namespace_fuchsia.cc",
    "namespace_linux.cc",
    "namespace_macos.cc",
    "namespace_win.cc",
    "platform.cc",
    "platform_fuchsia.cc",
    "platform_linux.cc",
    "platform_macos.cc",
    "platform_win.cc",
    "process.cc",
    "process_fuchsia.cc",
    "process_linux.cc",
    "process_macos.cc",
    "process_win.cc",
    "root_certificates_unsupported.cc",
    "secure_socket_filter.cc",
    "secure_socket_unsupported.cc",
    "secure_socket_utils.cc",
    "security_context.cc",
    "security_context_fuchsia.cc",
    "security_context_linux.cc",
    "security_context_macos.cc",
    "security_context_win.cc",
    "socket.cc",
    "socket_base.cc",
    "socket_base_fuchsia.cc",
    "socket_base_linux.cc",
    "socket_base_macos.cc",
    "socket_base_posix.cc",
    "socket_base_win.cc",
    "socket_fuchsia.cc",
    "socket_linux.cc",
    "socket_macos.cc",
    "socket_win.cc",
    "stdio.cc",
    "stdio_fuchsia.cc",
    "stdio_linux.cc",
    "stdio_macos.cc",
    "stdio_win.cc",
    "sync_socket.cc",
    "sync_socket_fuchsia.cc",
    "sync_socket_linux.cc",
    "sync_socket_macos.cc",
    "sync_socket_win.cc",
    "typed_data_utils.cc",
};

const builtin_impl_sources = .{
    "crypto.cc",
    "crypto_fuchsia.cc",
    "crypto_linux.cc",
    "crypto_macos.cc",
    "crypto_win.cc",
    "dartutils.cc",
    "directory.cc",
    "directory_fuchsia.cc",
    "directory_linux.cc",
    "directory_macos.cc",
    "directory_win.cc",
    "exe_utils.cc",
    "fdutils_fuchsia.cc",
    "fdutils_linux.cc",
    "fdutils_macos.cc",
    "file.cc",
    "file_fuchsia.cc",
    "file_linux.cc",
    "file_macos.cc",
    "file_support.cc",
    "file_win.cc",
    "io_buffer.cc",
    "isolate_data.cc",
    "thread.cc",
    "thread_absl.cc",
    "thread_fuchsia.cc",
    "thread_linux.cc",
    "thread_macos.cc",
    "thread_win.cc",
    "uri.cc",
    "utils.cc",
    "utils_fuchsia.cc",
    "utils_linux.cc",
    "utils_macos.cc",
    "utils_win.cc",
};

const platform_sources = .{
    "allocation.cc",
    "assert.cc",
    "floating_point_win.cc",
    "hashmap.cc",
    "synchronization_absl.cc",
    "synchronization_posix.cc",
    "synchronization_win.cc",
    "syslog_android.cc",
    "syslog_fuchsia.cc",
    "syslog_linux.cc",
    "syslog_macos.cc",
    "syslog_win.cc",
    "text_buffer.cc",
    "unicode.cc",
    "unwinding_records.cc",
    "unwinding_records_win.cc",
    "utils.cc",
    "utils_android.cc",
    "utils_fuchsia.cc",
    "utils_linux.cc",
    "utils_macos.cc",
    "utils_win.cc",
};

const async_runtime_cc_files = .{
    "async.cc",
};

const concurrent_runtime_cc_files = .{
    "concurrent.cc",
};
const core_runtime_cc_files = .{
    "array.cc",
    "bool.cc",
    "date.cc",
    "double.cc",
    "errors.cc",
    "function.cc",
    "growable_array.cc",
    "identical.cc",
    "integers.cc",
    "object.cc",
    "regexp.cc",
    "stacktrace.cc",
    "stopwatch.cc",
    "string.cc",
    "uri.cc",
};
const developer_runtime_cc_files = .{
    "developer.cc",
    "profiler.cc",
    "timeline.cc",
};
const ffi_runtime_cc_files = .{
    "ffi.cc",
    "ffi_dynamic_library.cc",
};
const isolate_runtime_cc_files = .{
    "isolate.cc",
};
const math_runtime_cc_files = .{
    "math.cc",
};
const mirrors_runtime_cc_files = .{
    "mirrors.cc",
};
const typed_data_runtime_cc_files = .{
    "typed_data.cc",
    "simd128.cc",
};
const vmservice_runtime_cc_files = .{
    "vmservice.cc",
};

const allsources = async_runtime_cc_files ++ concurrent_runtime_cc_files ++
    core_runtime_cc_files ++ developer_runtime_cc_files ++
    ffi_runtime_cc_files ++ isolate_runtime_cc_files ++
    math_runtime_cc_files ++ mirrors_runtime_cc_files ++
    typed_data_runtime_cc_files ++ vmservice_runtime_cc_files;

const vm_sources = .{
    "allocation.cc",
    "app_snapshot.cc",
    "base64.cc",
    "bit_vector.cc",
    "bitmap.cc",
    "bootstrap_natives.cc",
    "bss_relocs.cc",
    "bytecode_reader.cc",
    "canonical_tables.cc",
    "class_finalizer.cc",
    "class_table.cc",
    "closure_functions_cache.cc",
    "code_comments.cc",
    "code_descriptors.cc",
    "code_observers.cc",
    "code_patcher.cc",
    "code_patcher_arm.cc",
    "code_patcher_arm64.cc",
    "code_patcher_ia32.cc",
    "code_patcher_riscv.cc",
    "code_patcher_x64.cc",
    "constants_arm.cc",
    "constants_arm64.cc",
    "constants_ia32.cc",
    "constants_kbc.cc",
    "constants_riscv.cc",
    "constants_x64.cc",
    "cpu_arm.cc",
    "cpu_arm64.cc",
    "cpu_ia32.cc",
    "cpu_riscv.cc",
    "cpu_x64.cc",
    "cpuid.cc",
    "cpuinfo_android.cc",
    "cpuinfo_fuchsia.cc",
    "cpuinfo_linux.cc",
    "cpuinfo_macos.cc",
    "cpuinfo_win.cc",
    "dart.cc",
    "dart_api_state.cc",
    "dart_entry.cc",
    "datastream.cc",
    "debugger.cc",
    "debugger_arm.cc",
    "debugger_arm64.cc",
    "debugger_ia32.cc",
    "debugger_riscv.cc",
    "debugger_x64.cc",
    "deferred_objects.cc",
    "deopt_instructions.cc",
    "dispatch_table.cc",
    "double_conversion.cc",
    "dwarf.cc",
    "elf.cc",
    "exceptions.cc",
    "experimental_features.cc",
    "ffi_callback_metadata.cc",
    "field_table.cc",
    "flags.cc",
    "gdb_helpers.cc",
    "handles.cc",
    "image_snapshot.cc",
    "instructions.cc",
    "instructions_arm.cc",
    "instructions_arm64.cc",
    "instructions_ia32.cc",
    "instructions_riscv.cc",
    "instructions_x64.cc",
    "interpreter.cc",
    "isolate.cc",
    "isolate_reload.cc",
    "json_stream.cc",
    "json_writer.cc",
    "kernel.cc",
    "kernel_binary.cc",
    "kernel_isolate.cc",
    "kernel_loader.cc",
    "lockers.cc",
    "log.cc",
    "longjump.cc",
    "megamorphic_cache_table.cc",
    "memory_region.cc",
    "message.cc",
    "message_handler.cc",
    "message_snapshot.cc",
    "metrics.cc",
    "native_entry.cc",
    "native_message_handler.cc",
    "native_symbol_posix.cc",
    "native_symbol_win.cc",
    "object.cc",
    "object_graph.cc",
    "object_graph_copy.cc",
    "object_id_ring.cc",
    "object_reload.cc",
    "object_service.cc",
    "object_store.cc",
    "os.cc",
    "os_android.cc",
    "os_fuchsia.cc",
    "os_linux.cc",
    "os_macos.cc",
    "os_thread.cc",
    "os_thread_absl.cc",
    "os_thread_android.cc",
    "os_thread_fuchsia.cc",
    "os_thread_linux.cc",
    "os_thread_macos.cc",
    "os_thread_win.cc",
    "os_win.cc",
    "parser.cc",
    "pending_deopts.cc",
    "port.cc",
    "proccpuinfo.cc",
    "profiler.cc",
    "profiler_service.cc",
    "program_visitor.cc",
    "random.cc",
    "raw_object.cc",
    "raw_object_fields.cc",
    "report.cc",
    "resolver.cc",
    "reverse_pc_lookup_cache.cc",
    "runtime_entry.cc",
    "runtime_entry_arm.cc",
    "runtime_entry_arm64.cc",
    "runtime_entry_ia32.cc",
    "runtime_entry_riscv.cc",
    "runtime_entry_x64.cc",
    "scopes.cc",
    "service.cc",
    "service_event.cc",
    "service_isolate.cc",
    "signal_handler_android.cc",
    "signal_handler_fuchsia.cc",
    "signal_handler_linux.cc",
    "signal_handler_macos.cc",
    "signal_handler_win.cc",
    "simulator_arm.cc",
    "simulator_arm64.cc",
    "simulator_riscv.cc",
    "simulator_x64.cc",
    "snapshot.cc",
    "source_report.cc",
    "stack_frame.cc",
    "stack_trace.cc",
    "stub_code.cc",
    "symbols.cc",
    "tags.cc",
    "thread.cc",
    "thread_interrupter.cc",
    "thread_interrupter_android.cc",
    "thread_interrupter_fuchsia.cc",
    "thread_interrupter_linux.cc",
    "thread_interrupter_macos.cc",
    "thread_interrupter_win.cc",
    "thread_pool.cc",
    "thread_registry.cc",
    "thread_stack_resource.cc",
    "thread_state.cc",
    "timeline.cc",
    "timeline_android.cc",
    "timeline_fuchsia.cc",
    "timeline_linux.cc",
    "timeline_macos.cc",
    "timer.cc",
    "token.cc",
    "token_position.cc",
    "type_testing_stubs.cc",
    "unicode.cc",
    "unicode_data.cc",
    "unwinding_records.cc",
    "unwinding_records_win.cc",
    "v8_snapshot_writer.cc",
    "virtual_memory.cc",
    "virtual_memory_compressed.cc",
    "virtual_memory_fuchsia.cc",
    "virtual_memory_posix.cc",
    "virtual_memory_win.cc",
    "visitor.cc",
    "zone.cc",
    "zone_text_buffer.cc",
};

const compiler_api_sources = .{
    "api/print_filter.cc",
    "jit/compiler.cc",
    "runtime_api.cc",
};

const disassembler_sources = .{
    "assembler/disassembler.cc",
    "assembler/disassembler_arm.cc",
    "assembler/disassembler_arm64.cc",
    "assembler/disassembler_kbc.cc",
    "assembler/disassembler_riscv.cc",
    "assembler/disassembler_x86.cc",
};
const ffi_sources = .{
    "native_assets.cc",
};

const heap_sources = .{
    "become.cc",
    "compactor.cc",
    "freelist.cc",
    "gc_shared.cc",
    "heap.cc",
    "incremental_compactor.cc",
    "marker.cc",
    "page.cc",
    "pages.cc",
    "pointer_block.cc",
    "safepoint.cc",
    "sampler.cc",
    "scavenger.cc",
    "sweeper.cc",
    "verifier.cc",
    "weak_code.cc",
    "weak_table.cc",
};
const regexp_sources = .{
    "regexp.cc",
    "regexp_assembler.cc",
    "regexp_assembler_bytecode.cc",
    "regexp_assembler_ir.cc",
    "regexp_ast.cc",
    "regexp_interpreter.cc",
    "regexp_parser.cc",
    "unibrow.cc",
};
const compiler_sources = .{
    "aot/aot_call_specializer.cc",
    "aot/dispatch_table_generator.cc",
    "aot/precompiler.cc",
    "aot/precompiler_tracer.cc",
    "asm_intrinsifier.cc",
    "asm_intrinsifier_arm.cc",
    "asm_intrinsifier_arm64.cc",
    "asm_intrinsifier_ia32.cc",
    "asm_intrinsifier_riscv.cc",
    "asm_intrinsifier_x64.cc",
    "assembler/assembler_arm.cc",
    "assembler/assembler_arm64.cc",
    "assembler/assembler_base.cc",
    "assembler/assembler_ia32.cc",
    "assembler/assembler_riscv.cc",
    "assembler/assembler_x64.cc",
    "backend/block_scheduler.cc",
    "backend/branch_optimizer.cc",
    "backend/code_statistics.cc",
    "backend/constant_propagator.cc",
    "backend/dart_calling_conventions.cc",
    "backend/evaluator.cc",
    "backend/flow_graph.cc",
    "backend/flow_graph_checker.cc",
    "backend/flow_graph_compiler.cc",
    "backend/flow_graph_compiler_arm.cc",
    "backend/flow_graph_compiler_arm64.cc",
    "backend/flow_graph_compiler_ia32.cc",
    "backend/flow_graph_compiler_riscv.cc",
    "backend/flow_graph_compiler_x64.cc",
    "backend/il.cc",
    "backend/il_arm.cc",
    "backend/il_arm64.cc",
    "backend/il_ia32.cc",
    "backend/il_printer.cc",
    "backend/il_riscv.cc",
    "backend/il_serializer.cc",
    "backend/il_x64.cc",
    "backend/inliner.cc",
    "backend/linearscan.cc",
    "backend/locations.cc",
    "backend/loops.cc",
    "backend/parallel_move_resolver.cc",
    "backend/range_analysis.cc",
    "backend/redundancy_elimination.cc",
    "backend/slot.cc",
    "backend/type_propagator.cc",
    "call_specializer.cc",
    "cha.cc",
    "compiler_pass.cc",
    "compiler_state.cc",
    "compiler_timings.cc",
    "ffi/abi.cc",
    "ffi/callback.cc",
    "ffi/frame_rebase.cc",
    "ffi/marshaller.cc",
    "ffi/native_calling_convention.cc",
    "ffi/native_location.cc",
    "ffi/native_type.cc",
    "ffi/recognized_method.cc",
    "frontend/base_flow_graph_builder.cc",
    "frontend/constant_reader.cc",
    "frontend/flow_graph_builder.cc",
    "frontend/kernel_binary_flowgraph.cc",
    "frontend/kernel_fingerprints.cc",
    "frontend/kernel_to_il.cc",
    "frontend/kernel_translation_helper.cc",
    "frontend/prologue_builder.cc",
    "frontend/scope_builder.cc",
    "graph_intrinsifier.cc",
    "intrinsifier.cc",
    "jit/jit_call_specializer.cc",
    "method_recognizer.cc",
    "relocation.cc",
    "stub_code_compiler.cc",
    "stub_code_compiler_arm.cc",
    "stub_code_compiler_arm64.cc",
    "stub_code_compiler_ia32.cc",
    "stub_code_compiler_riscv.cc",
    "stub_code_compiler_x64.cc",
    "write_barrier_elimination.cc",
};

const native_assets_impl_sources = .{
    "native_assets_api_impl.cc",
};

const vm_snapshot_files = .{
    // Header files.
    "app_snapshot.h",
    "datastream.h",
    "image_snapshot.h",
    "object.h",
    "raw_object.h",
    "snapshot.h",
    "symbols.h",
    // Source files.
    "app_snapshot.cc",
    "dart.cc",
    "dart_api_impl.cc",
    "image_snapshot.cc",
    "object.cc",
    "raw_object.cc",
    "snapshot.cc",
    "symbols.cc",
};
