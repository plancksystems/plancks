const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const version = b.option(
        []const u8,
        "version",
        "Release version (e.g. 0.1.0)",
    ) orelse "0.0.0-dev";

    const wasmer_dir = b.option(
        []const u8,
        "wasmer-dir",
        "wasmer libs root (default: $WASMER_DIR or ~/.wasmer)",
    ) orelse defaultWasmerDir(b);

    const target_str = b.option(
        []const u8,
        "target",
        "Zig target triple (default: native)",
    );

    const target_arch: std.Target.Cpu.Arch, const target_os: std.Target.Os.Tag =
        if (target_str) |s| parseTriple(s) else .{ builtin.cpu.arch, builtin.os.tag };

    const tarball = tarballNaming(target_arch, target_os);
    const rollup_native = comptime rollupNativePackage(builtin.cpu.arch, builtin.os.tag);

    const archive_base = b.fmt(
        "planck-{s}-{s}-{s}",
        .{ version, tarball.arch, tarball.os },
    );
    const archive_filename = b.fmt("{s}.{s}", .{ archive_base, tarball.ext });

    const stage_dir = b.fmt("zig-out/release/{s}", .{archive_base});

    const npm_install = b.addSystemCommand(&.{
        "npm", "install", "--no-audit", "--no-fund",
    });
    npm_install.setCwd(b.path("ui"));

    const rollup_install = b.addSystemCommand(&.{
        "npm", "install", "--no-save", "--no-audit", "--no-fund", rollup_native,
    });
    rollup_install.setCwd(b.path("ui"));
    rollup_install.step.dependOn(&npm_install.step);

    const npm_build = b.addSystemCommand(&.{ "npm", "run", "build" });
    npm_build.setCwd(b.path("ui"));
    npm_build.step.dependOn(&rollup_install.step);

    const wasmer_arg = b.fmt("-Dwasmer-dir={s}", .{wasmer_dir});
    const target_arg = if (target_str) |s| b.fmt("-Dtarget={s}", .{s}) else "";

    const build_db = makeZigBuild(b, "planck", &.{ wasmer_arg, target_arg });
    const build_wb = makeZigBuild(b, "workbench", &.{target_arg});
    build_wb.step.dependOn(&npm_build.step);
    const build_zxc = makeZigBuild(b, "planctl", &.{target_arg});

    const exe_suffix = if (tarball.os_tag == .windows) ".exe" else "";
    const wasmer_shared = wasmerSharedName(tarball.os_tag);
    const downloads_dir = "../ws/dist/downloads";

    const post = if (builtin.os.tag == .windows)
        buildPostScriptWindows(b, .{
            .stage = stage_dir,
            .exe = exe_suffix,
            .wasmer = wasmer_shared,
            .wasmer_dir = wasmer_dir,
            .ver = version,
            .arch = tarball.arch,
            .os = tarball.os,
            .downloads = downloads_dir,
            .archive_base = archive_base,
            .archive_filename = archive_filename,
        })
    else
        buildPostScriptUnix(b, .{
            .stage = stage_dir,
            .exe = exe_suffix,
            .wasmer = wasmer_shared,
            .wasmer_dir = wasmer_dir,
            .ver = version,
            .arch = tarball.arch,
            .os = tarball.os,
            .target_os_tag = tarball.os_tag,
            .downloads = downloads_dir,
            .archive_base = archive_base,
            .archive_filename = archive_filename,
        });

    post.step.dependOn(&build_db.step);
    post.step.dependOn(&build_wb.step);
    post.step.dependOn(&build_zxc.step);

    const release_step = b.step(
        "release",
        "Build native release tarball into ../ws/dist/downloads/",
    );
    release_step.dependOn(&post.step);

    if (builtin.os.tag != .windows) addInstallDevStep(b, .{
        .target_arg = target_arg,
        .wasmer_arg = wasmer_arg,
        .exe_suffix = exe_suffix,
    });
}

const InstallDevArgs = struct {
    target_arg: []const u8,
    wasmer_arg: []const u8,
    exe_suffix: []const u8,
};

fn addInstallDevStep(b: *std.Build, a: InstallDevArgs) void {
    const opt_arg = "-Doptimize=ReleaseFast";

    const dev_ctl = makeZigBuildWithOpt(b, "planctl", &.{a.target_arg}, opt_arg);

    const dev_ui_install = b.addSystemCommand(&.{ "npm", "install", "--no-audit", "--no-fund" });
    dev_ui_install.setCwd(b.path("ui"));
    dev_ui_install.step.dependOn(&dev_ctl.step);

    const dev_ui_build = b.addSystemCommand(&.{ "npm", "run", "build" });
    dev_ui_build.setCwd(b.path("ui"));
    dev_ui_build.step.dependOn(&dev_ui_install.step);

    const dev_wb = makeZigBuildWithOpt(b, "workbench", &.{a.target_arg}, opt_arg);
    dev_wb.step.dependOn(&dev_ui_build.step);

    const dev_db = makeZigBuildWithOpt(b, "planck", &.{ a.wasmer_arg, a.target_arg }, opt_arg);
    dev_db.step.dependOn(&dev_wb.step);

    const home = b.graph.environ_map.get("HOME") orelse {
        std.debug.panic("$HOME not set; cannot run `install-dev`", .{});
    };
    const dev_bin = b.fmt("{s}/.planck/bin", .{home});

    const copy_script = b.fmt(
        \\set -e
        \\mkdir -p "{[bin]s}"
        \\cp planck/vendor/wasmer/aarch64-macos/lib/libwasmer.dylib     "{[bin]s}/libwasmer.dylib"
        \\cp planctl/zig-out/bin/planctl{[ext]s}      "{[bin]s}/planctl{[ext]s}"
        \\cp workbench/zig-out/bin/workbench{[ext]s}  "{[bin]s}/workbench{[ext]s}"
        \\cp planck/zig-out/bin/planck{[ext]s}        "{[bin]s}/planck{[ext]s}"
        \\echo "installed → {[bin]s}"
        \\echo "  planctl, workbench, planck"
        \\echo "next: {[bin]s}/planctl system init"
        \\
    , .{ .bin = dev_bin, .ext = a.exe_suffix });

    const dev_copy = b.addSystemCommand(&.{ "sh", "-c", copy_script });
    dev_copy.step.dependOn(&dev_db.step);

    const install_dev_step = b.step(
        "install-dev",
        "Build planctl/ui/workbench/planck (Debug) and copy binaries to $HOME/.planck/bin/",
    );
    install_dev_step.dependOn(&dev_copy.step);
}

fn makeZigBuildWithOpt(b: *std.Build, subdir: []const u8, extra: []const []const u8, optimize_arg: []const u8) *std.Build.Step.Run {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ "zig", "build", optimize_arg }) catch @panic("OOM");
    for (extra) |a| if (a.len > 0) argv.append(b.allocator, a) catch @panic("OOM");
    const cmd = b.addSystemCommand(argv.items);
    cmd.setCwd(b.path(subdir));
    return cmd;
}

const TarballNaming = struct {
    arch: []const u8,
    os: []const u8,
    ext: []const u8,
    os_tag: std.Target.Os.Tag,
};

fn makeZigBuild(b: *std.Build, subdir: []const u8, extra: []const []const u8) *std.Build.Step.Run {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ "zig", "build", "-Doptimize=ReleaseFast" }) catch @panic("OOM");
    for (extra) |a| if (a.len > 0) argv.append(b.allocator, a) catch @panic("OOM");
    const cmd = b.addSystemCommand(argv.items);
    cmd.setCwd(b.path(subdir));
    return cmd;
}

fn tarballNaming(arch: std.Target.Cpu.Arch, tag: std.Target.Os.Tag) TarballNaming {
    return switch (tag) {
        .macos => .{
            .arch = if (arch == .aarch64) "arm64" else "x86_64",
            .os = "darwin",
            .ext = "tar.gz",
            .os_tag = .macos,
        },
        .linux => .{
            .arch = if (arch == .aarch64) "aarch64" else "x86_64",
            .os = "linux",
            .ext = "tar.gz",
            .os_tag = .linux,
        },
        .windows => .{
            .arch = if (arch == .aarch64) "aarch64" else "x86_64",
            .os = "windows",
            .ext = "zip",
            .os_tag = .windows,
        },
        else => std.debug.panic("unsupported release target: {s}", .{@tagName(tag)}),
    };
}

fn parseTriple(triple: []const u8) struct { std.Target.Cpu.Arch, std.Target.Os.Tag } {
    const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err| {
        std.debug.panic("invalid -Dtarget {s}: {}", .{ triple, err });
    };
    const arch = query.cpu_arch orelse std.debug.panic("-Dtarget {s}: arch unset", .{triple});
    const tag = query.os_tag orelse std.debug.panic("-Dtarget {s}: os unset", .{triple});
    return .{ arch, tag };
}

const PostScriptArgs = struct {
    stage: []const u8,
    exe: []const u8,
    wasmer: []const u8,
    wasmer_dir: []const u8,
    ver: []const u8,
    arch: []const u8,
    os: []const u8,
    target_os_tag: std.Target.Os.Tag = .linux,
    downloads: []const u8,
    archive_base: []const u8,
    archive_filename: []const u8,
};

fn buildPostScriptUnix(b: *std.Build, a: PostScriptArgs) *std.Build.Step.Run {
    const stage_script = b.fmt(
        \\set -e
        \\rm -rf "{[stage]s}"
        \\mkdir -p "{[stage]s}/bin"
        \\cp planck/zig-out/bin/planck{[exe]s}        "{[stage]s}/bin/"
        \\cp workbench/zig-out/bin/workbench{[exe]s}  "{[stage]s}/bin/"
        \\cp planctl/zig-out/bin/planctl{[exe]s}      "{[stage]s}/bin/"
        \\cp "{[wasmer_dir]s}/lib/{[wasmer]s}"        "{[stage]s}/bin/"
        \\printf '%s' "{[ver]s}" > "{[stage]s}/VERSION"
        \\cat > "{[stage]s}/README.md" <<EOF
        \\# Planck {[ver]s} for {[arch]s}-{[os]s}
        \\
        \\Contents:
        \\  bin/planck       Database engine
        \\  bin/workbench       Control plane + web UI (port 2369)
        \\  bin/planctl             Deploy CLI
        \\  bin/{[wasmer]s}     Wasmer runtime (loaded at runtime)
        \\
        \\Install:
        \\  curl -sSL https://plancks.io/downloads/get.sh | sudo sh
        \\
        \\Offline (download tarball + get.sh separately):
        \\  sudo sh get.sh install --offline ./planck-{[ver]s}-{[arch]s}-{[os]s}.tar.gz
        \\EOF
        \\mkdir -p "{[downloads]s}"
        \\
    , .{
        .stage = a.stage,
        .exe = a.exe,
        .wasmer = a.wasmer,
        .wasmer_dir = a.wasmer_dir,
        .ver = a.ver,
        .arch = a.arch,
        .os = a.os,
        .downloads = a.downloads,
    });

    const archive_script = if (a.target_os_tag == .windows)
        b.fmt(
            \\(cd "zig-out/release" && \
            \\ powershell -NoProfile -Command "Compress-Archive -Force -Path '{[base]s}' -DestinationPath '../../{[downloads]s}/{[name]s}'")
            \\
        , .{ .base = a.archive_base, .downloads = a.downloads, .name = a.archive_filename })
    else
        b.fmt(
            \\(cd "zig-out/release" && tar czf "../../{[downloads]s}/{[name]s}" "{[base]s}")
            \\
        , .{ .downloads = a.downloads, .name = a.archive_filename, .base = a.archive_base });

    const sha_script = b.fmt(
        \\CHECKSUMS="{[downloads]s}/SHA256SUMS-{[ver]s}.txt"
        \\touch "$CHECKSUMS"
        \\grep -v "  {[name]s}\$" "$CHECKSUMS" > "$CHECKSUMS.tmp" 2>/dev/null || true
        \\[ -f "$CHECKSUMS.tmp" ] && mv "$CHECKSUMS.tmp" "$CHECKSUMS" || true
        \\(cd "{[downloads]s}" && shasum -a 256 "{[name]s}" >> "SHA256SUMS-{[ver]s}.txt")
        \\echo "Released: {[downloads]s}/{[name]s}"
        \\echo "  $(cd "{[downloads]s}" && shasum -a 256 "{[name]s}" | cut -d' ' -f1)"
        \\
    , .{ .downloads = a.downloads, .ver = a.ver, .name = a.archive_filename });

    const post_script = b.fmt("{s}{s}{s}", .{ stage_script, archive_script, sha_script });
    return b.addSystemCommand(&.{ "sh", "-c", post_script });
}

fn buildPostScriptWindows(b: *std.Build, a: PostScriptArgs) *std.Build.Step.Run {
    const ps = b.fmt(
        \\$ErrorActionPreference = 'Stop'
        \\Remove-Item -Recurse -Force -ErrorAction SilentlyContinue '{[stage]s}'
        \\New-Item -ItemType Directory -Force -Path '{[stage]s}\bin' | Out-Null
        \\Copy-Item -Force 'planck\zig-out\bin\planck{[exe]s}' (Join-Path '{[stage]s}\bin' 'planck{[exe]s}')
        \\Copy-Item -Force 'workbench\zig-out\bin\workbench{[exe]s}' (Join-Path '{[stage]s}\bin' 'workbench{[exe]s}')
        \\Copy-Item -Force 'planctl\zig-out\bin\planctl{[exe]s}' (Join-Path '{[stage]s}\bin' 'planctl{[exe]s}')
        \\Copy-Item -Force '{[wasmer_dir]s}\lib\{[wasmer]s}' (Join-Path '{[stage]s}\bin' '{[wasmer]s}')
        \\Set-Content -Path '{[stage]s}\VERSION' -Value '{[ver]s}' -NoNewline -Encoding ASCII
        \\$readme = @'
        \\# Planck {[ver]s} for {[arch]s}-{[os]s}
        \\
        \\Contents:
        \\  bin/planck       Database engine
        \\  bin/workbench       Control plane + web UI (port 2369)
        \\  bin/planctl             Deploy CLI
        \\  bin/{[wasmer]s}     Wasmer runtime (loaded at runtime)
        \\
        \\Install (Windows, PowerShell as Administrator):
        \\  iwr -useb https://plancks.io/downloads/get.ps1 | iex
        \\
        \\Offline (download archive + get.ps1 separately):
        \\  .\get.ps1 install -Offline .\planck-{[ver]s}-{[arch]s}-{[os]s}.zip
        \\'@
        \\Set-Content -Path '{[stage]s}\README.md' -Value $readme -Encoding UTF8
        \\New-Item -ItemType Directory -Force -Path '{[downloads]s}' | Out-Null
        \\
        \\# ── Archive ──
        \\$archive = Join-Path '{[downloads]s}' '{[archive_filename]s}'
        \\$srcDir  = 'zig-out\release\{[archive_base]s}'
        \\if ('{[archive_filename]s}'.EndsWith('.zip')) {{
        \\    Compress-Archive -Force -Path $srcDir -DestinationPath $archive
        \\}} else {{
        \\    & tar -C 'zig-out\release' -czf $archive '{[archive_base]s}'
        \\    if ($LASTEXITCODE -ne 0) {{ throw "tar failed (exit $LASTEXITCODE)" }}
        \\}}
        \\
        \\# ── SHA256SUMS ──
        \\$hash = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLower()
        \\$sums = Join-Path '{[downloads]s}' 'SHA256SUMS-{[ver]s}.txt'
        \\$lines = if (Test-Path $sums) {{
        \\    @(Get-Content $sums | Where-Object {{ $_ -notmatch '  {[archive_filename]s}$' }})
        \\}} else {{ @() }}
        \\$lines += "$hash  {[archive_filename]s}"
        \\Set-Content -Path $sums -Value $lines -Encoding ASCII
        \\Write-Host "Released: $archive"
        \\Write-Host "  $hash"
    , .{
        .stage = a.stage,
        .exe = a.exe,
        .wasmer = a.wasmer,
        .wasmer_dir = a.wasmer_dir,
        .ver = a.ver,
        .arch = a.arch,
        .os = a.os,
        .downloads = a.downloads,
        .archive_base = a.archive_base,
        .archive_filename = a.archive_filename,
    });
    return b.addSystemCommand(&.{ "powershell", "-NoProfile", "-Command", ps });
}

fn wasmerSharedName(tag: std.Target.Os.Tag) []const u8 {
    return switch (tag) {
        .macos => "libwasmer.dylib",
        .linux => "libwasmer.so",
        .windows => "wasmer.dll",
        else => std.debug.panic("unsupported wasmer target: {s}", .{@tagName(tag)}),
    };
}

fn rollupNativePackage(comptime arch: std.Target.Cpu.Arch, comptime tag: std.Target.Os.Tag) []const u8 {
    return switch (tag) {
        .macos => if (arch == .aarch64) "@rollup/rollup-darwin-arm64" else "@rollup/rollup-darwin-x64",
        .linux => if (arch == .aarch64) "@rollup/rollup-linux-arm64-gnu" else "@rollup/rollup-linux-x64-gnu",
        .windows => "@rollup/rollup-win32-x64-msvc",
        else => @compileError("unsupported rollup host: " ++ @tagName(tag)),
    };
}

fn defaultWasmerDir(b: *std.Build) []const u8 {
    if (b.graph.environ_map.get("WASMER_DIR")) |d| return b.dupe(d);
    const home = b.graph.environ_map.get("HOME") orelse return "vendor/wasmer";
    return b.fmt("{s}/.wasmer", .{home});
}
