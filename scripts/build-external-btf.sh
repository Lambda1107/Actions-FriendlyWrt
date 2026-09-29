#!/usr/bin/env bash
# Build a DWARF-full shadow of szr's current kernel; never build/install an image.
set -Eeuo pipefail
export LC_ALL=C
export TZ=UTC

trap 'printf "external BTF build failed at line %s\n" "$LINENO" >&2' ERR
fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 3 ]] || fail "usage: $0 KERNEL_DIR CROSS_COMPILE_PREFIX OUTPUT_DIR"
for dependency in python3 git make gcc g++ bc bison flex pkg-config pahole sha256sum nproc; do
    command -v "$dependency" >/dev/null || fail "missing dependency: $dependency"
done
pkg-config --exists libelf openssl || fail 'libelf-dev and libssl-dev are required'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_dir="$(cd -- "$script_dir/.." && pwd -P)"
baseline="$repo_dir/btf/szr-6.6.134+.config"
config_guard="$script_dir/check-btf-config.py"
expected_config_sha=02caafed7756644660646a58b89534712c198cd8db7774974dcb5a3387c4833d
expected_source=22d95ec20869e9a713f677156a3ba039e5034555
expected_release=6.6.134+
expected_compiler='aarch64-linux-gnu-gcc (ctng-1.25.0-119g-FA) 11.3.0'
[[ -f "$baseline" && -f "$config_guard" ]] || fail 'runtime config or config guard is missing'
config_sha="$(sha256sum "$baseline")"
config_sha="${config_sha%% *}"
[[ "$config_sha" == "$expected_config_sha" ]] || fail "runtime config SHA256 mismatch: $config_sha"

kernel_dir="$(cd -- "$1" && pwd -P)"
cross_gcc="$(command -v "${2}gcc")" || fail "cross compiler not found: ${2}gcc"
cross_gcc="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$cross_gcc")"
cross_compile="${cross_gcc%gcc}"
build_dir="$(python3 -c 'import pathlib, sys; print((pathlib.Path(sys.argv[1]).parent / "btf-build").resolve())' "$kernel_dir")"
output_dir="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$3")"
for path in "$kernel_dir" "$build_dir" "$cross_compile"; do
    [[ "$path" != *[[:space:]]* ]] || fail "Kbuild paths must not contain whitespace: $path"
done
for tool in gcc ld ar nm objcopy objdump readelf strip; do
    [[ -x "${cross_compile}${tool}" ]] || fail "missing cross tool: ${cross_compile}${tool}"
done

compiler_output="$("${cross_compile}gcc" --version)"
compiler_banner="${compiler_output%%$'\n'*}"
compiler_version="$("${cross_compile}gcc" -dumpfullversion -dumpversion)"
compiler_target="$("${cross_compile}gcc" -dumpmachine)"
[[ "$compiler_banner" == "$expected_compiler" ]] || fail "wrong cross compiler: $compiler_banner"
[[ "$compiler_version" == 11.3.0 ]] || fail "wrong compiler version: $compiler_version"
[[ "$compiler_target" == aarch64-linux-gnu || "$compiler_target" == aarch64-cortexa53-linux-gnu ]] || fail "wrong compiler target: $compiler_target"
linker_output="$("${cross_compile}ld" --version)"
linker_banner="${linker_output%%$'\n'*}"
[[ "$linker_banner" == 'GNU ld (GNU Binutils) 2.38' ]] || fail "wrong cross linker: $linker_banner"
pahole_version="$(pahole --version)"
pahole_help="$(pahole --help)"
[[ "$pahole_help" == *--btf_encode_detached* ]] || fail 'pahole lacks detached BTF encoding'

[[ "$(git -C "$kernel_dir" rev-parse --show-toplevel)" == "$kernel_dir" ]] || fail 'KERNEL_DIR must be the kernel Git checkout root'
source_commit="$(git -C "$kernel_dir" rev-parse HEAD)"
[[ "$source_commit" == "$expected_source" ]] || fail "wrong kernel source commit: $source_commit"
source_status="$(git -C "$kernel_dir" status --porcelain=v1 --untracked-files=all --ignored=matching)"
[[ -z "$source_status" ]] || fail "kernel source must be pristine, including generated/ignored files: $source_status"
source_tree="$(git -C "$kernel_dir" rev-parse 'HEAD^{tree}')"
source_origin="$(git -C "$kernel_dir" remote get-url origin)"
source_description="$(git -C "$kernel_dir" show -s --format=fuller HEAD)"
[[ -f "$kernel_dir/Makefile" && -x "$kernel_dir/scripts/config" ]] || fail 'incomplete kernel source checkout'

# Refuse stale products or overlapping trees, without deleting caller-owned files.
python3 - "$kernel_dir" "$build_dir" "$output_dir" <<'PY'
from pathlib import Path
import sys

paths = [Path(value) for value in sys.argv[1:]]
for index, path in enumerate(paths):
    for other in paths[index + 1:]:
        if path == other or path in other.parents or other in path.parents:
            raise SystemExit(f"source, build and output directories must not overlap: {path}, {other}")
for path in paths[1:]:
    if path.exists() and (not path.is_dir() or any(path.iterdir())):
        raise SystemExit(f"refusing nonempty build/output path: {path}")
    path.mkdir(parents=True, exist_ok=True)
PY

printf '%s\n' "$compiler_output" "$linker_output" "pahole: $pahole_version" "kernel source: $source_commit" "runtime config SHA256: $config_sha"
cp -- "$baseline" "$build_dir/.config"
"$kernel_dir/scripts/config" --file "$build_dir/.config" --disable DEBUG_INFO_REDUCED

# A clean make environment prevents ambient compiler flags/config overrides from
# silently changing type layouts. LOCALVERSION=+ preserves the observed release
# without changing CONFIG_LOCALVERSION or relying on shallow-clone tag history.
make_command=(
    env -i "PATH=$PATH" "HOME=${HOME:?HOME must be set}" LC_ALL=C LANG=C TZ=UTC
    KBUILD_BUILD_TIMESTAMP='Tue Jun 9 08:29:57 UTC 2026'
    KBUILD_BUILD_USER=runner KBUILD_BUILD_HOST=runnervmiav63 KBUILD_BUILD_VERSION=1
    make --no-print-directory -C "$kernel_dir" "O=$build_dir"
    ARCH=arm64 "CROSS_COMPILE=$cross_compile" "CC=${cross_compile}gcc" "LD=${cross_compile}ld"
    HOSTCC=gcc HOSTCXX=g++ LOCALVERSION=+ "KCONFIG_CONFIG=$build_dir/.config" PAHOLE=pahole
)
"${make_command[@]}" olddefconfig
release="$("${make_command[@]}" -s kernelrelease)"
[[ "$release" == "$expected_release" ]] || fail "kernel release mismatch: $release"
python3 "$config_guard" "$baseline" "$build_dir/.config" > "$output_dir/config-check.json"

# These are mandatory even if the config guard's allowlist changes in the future.
python3 - "$build_dir/.config" <<'PY'
from pathlib import Path
import sys

config = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("CONFIG_") and "=" in line:
        key, value = line.split("=", 1)
        config[key] = value
expected = {
    "CONFIG_DEBUG_INFO": "y",
    "CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT": "y",
    "CONFIG_DEBUG_INFO_REDUCED": "n",
    "CONFIG_DEBUG_INFO_BTF": "n",
    "CONFIG_KPROBES": "n",
    "CONFIG_BPF_STREAM_PARSER": "n",
    "CONFIG_NET_SOCK_MSG": "y",
    "CONFIG_LOCALVERSION": '""',
    "CONFIG_LOCALVERSION_AUTO": "n",
    "CONFIG_ARM64": "y",
    "CONFIG_CPU_BIG_ENDIAN": "n",
}
for key, value in expected.items():
    actual = config.get(key, "n")
    if actual != value:
        raise SystemExit(f"required config mismatch: {key}={actual}, expected {value}")
PY

printf 'Building shadow vmlinux for %s (no images, modules or installation)\n' "$release"
"${make_command[@]}" -j"$(nproc)" vmlinux
[[ -s "$build_dir/vmlinux" ]] || fail 'vmlinux was not produced'
[[ "$(< "$build_dir/include/config/kernel.release")" == "$expected_release" ]] || fail 'built kernel release changed'
python3 "$config_guard" "$baseline" "$build_dir/.config" > "$output_dir/config-check.json"
elf_sections="$("${cross_compile}readelf" --wide --section-headers "$build_dir/vmlinux")"
[[ "$elf_sections" =~ [[:space:]]\.debug_info[[:space:]]+PROGBITS ]] || fail 'vmlinux is missing DWARF .debug_info'
[[ ! "$elf_sections" =~ [[:space:]]\.BTF[[:space:]] ]] || fail 'shadow kernel unexpectedly contains in-kernel BTF'

btf_path="$output_dir/vmlinux-$expected_release"
pahole --btf_encode_detached="$btf_path" "$build_dir/vmlinux"
[[ -s "$btf_path" ]] || fail 'pahole did not produce standalone BTF'
cp -- "$baseline" "$output_dir/runtime.config"
cp -- "$build_dir/.config" "$output_dir/build.config"
printf 'Built kernel release: %s\n' "$(< "$build_dir/include/config/kernel.release")"
cat -- "$build_dir/include/generated/compile.h"

# Validate the actual file/header, record provenance, then checksum the complete
# artifact set. The workflow adds consumer parsing evidence before upload.
python3 - "$output_dir" "$build_dir" "$source_commit" "$source_tree" "$source_origin" \
    "$source_description" "$cross_compile" "$compiler_output" "$compiler_target" \
    "$linker_output" "$pahole_version" "$expected_config_sha" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import struct
import sys

(output_name, build_name, commit, tree, origin, source_description, cross,
 compiler, target, linker, pahole, baseline_sha) = sys.argv[1:]
out = Path(output_name)
build = Path(build_name)
release = (build / "include/config/kernel.release").read_text().strip()
btf = out / f"vmlinux-{release}"
size = btf.stat().st_size
if not 64 * 1024 <= size <= 128 * 1024 * 1024:
    raise SystemExit(f"implausible standalone BTF size: {size} bytes")
with btf.open("rb") as stream:
    header = stream.read(24)
    if header[:2] != b"\x9f\xeb":
        raise SystemExit("expected raw little-endian BTF magic, not ELF or big-endian BTF")
    magic, version, flags, header_len, type_off, type_len, str_off, str_len = struct.unpack("<HBBIIIII", header)
    if magic != 0xEB9F or version != 1 or flags != 0 or not 24 <= header_len <= size:
        raise SystemExit("invalid BTF header")
    type_start, type_end = header_len + type_off, header_len + type_off + type_len
    str_start, str_end = header_len + str_off, header_len + str_off + str_len
    if (not type_len or not str_len or type_end > size or str_end != size
            or type_end > str_start or type_len % 4):
        raise SystemExit("invalid BTF type/string section bounds")
    stream.seek(str_start)
    if stream.read(1) != b"\0":
        raise SystemExit("BTF string table does not start with an empty string")
    stream.seek(str_end - 1)
    if stream.read(1) != b"\0":
        raise SystemExit("BTF string table is not NUL-terminated")
with (build / "vmlinux").open("rb") as stream:
    elf = stream.read(20)
if elf[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", elf, 18)[0] != 183:
    raise SystemExit("shadow vmlinux is not a little-endian ELF64 AArch64 binary")

def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

if sha256(out / "runtime.config") != baseline_sha:
    raise SystemExit("artifact runtime config hash differs from pinned baseline")
changes = json.loads((out / "config-check.json").read_text())
identity = {
    "KBUILD_BUILD_TIMESTAMP": "Tue Jun 9 08:29:57 UTC 2026",
    "KBUILD_BUILD_USER": "runner",
    "KBUILD_BUILD_HOST": "runnervmiav63",
    "KBUILD_BUILD_VERSION": "1",
    "LOCALVERSION": "+",
}
limits = [
    "External type metadata only: not a bootable kernel, module set or kernel replacement.",
    "Source commit is selected from the matching upstream build-time history; the router's exact source commit is not independently attested.",
    "Matching release, compiler and functional config do not prove every runtime type layout matches an unattested firmware build.",
    "Only CONFIG_DEBUG_INFO_REDUCED is disabled for full DWARF; tooling metadata differences are listed by the config guard.",
    "CONFIG_DEBUG_INFO_BTF, CONFIG_KPROBES and CONFIG_BPF_STREAM_PARSER remain disabled; external BTF cannot add kernel features.",
    "Not router-tested: no router changes, BPF syscalls/program loads or dae installation are performed by this build.",
    "Raw BTF header validation is not consumer compatibility proof; the workflow separately validates cilium/ebpf parsing and core type field bounds.",
]
manifest = {
    "format_version": 1,
    "artifact_kind": "external-kernel-btf",
    "kernel_release": release,
    "architecture": "aarch64",
    "source": {
        "repository": "https://github.com/friendlyarm/kernel-rockchip",
        "checkout_origin": origin,
        "commit": commit,
        "tree": tree,
        "pristine_checkout_required": True,
        "selection": "matching upstream build-time history, not exact router source attestation",
    },
    "toolchain": {
        "repository": "https://github.com/friendlyarm/prebuilts",
        "commit": "b156c94f1d3e90ae935819fe0a7a2910f013aded",
        "archive": "gcc-x64/toolchain-11.3-aarch64.tar.xz",
        "archive_git_blob": "5c01a4c3702d39c0ee88cb5ce23a7e310aab61d2",
        "archive_provenance": "fetched and verified by workflow; script verifies installed compiler/linker versions",
        "cross_compile": cross,
        "compiler": compiler,
        "target": target,
        "compiler_sha256": sha256(cross + "gcc"),
        "linker": linker,
        "linker_sha256": sha256(cross + "ld"),
        "pahole": pahole,
    },
    "build_identity": identity,
    "generated_compile_header": (build / "include/generated/compile.h").read_text(),
    "generated_release_header": (build / "include/generated/utsrelease.h").read_text(),
    "config": {
        "runtime_sha256": baseline_sha,
        "build_sha256": sha256(out / "build.config"),
        "guard_result": changes,
    },
    "btf": {
        "file": btf.name,
        "format": "raw BTF",
        "endianness": "little",
        "version": version,
        "bytes": size,
        "header_bytes": header_len,
        "type_bytes": type_len,
        "string_bytes": str_len,
        "sha256": sha256(btf),
    },
    "compatibility_limits": limits,
    "artifact_created_utc": datetime.now(timezone.utc).isoformat(),
}
info = [
    "External BTF for szr / NanoPi R2S / FriendlyWrt 2026-06-09",
    f"kernel release: {release}",
    "kernel repository: https://github.com/friendlyarm/kernel-rockchip",
    f"kernel checkout origin: {origin}",
    f"kernel commit: {commit}",
    f"kernel tree: {tree}",
    "--- source commit provenance ---", source_description,
    "--- installed compiler ---", compiler,
    f"compiler target: {target}",
    f"compiler SHA256: {manifest['toolchain']['compiler_sha256']}",
    "--- installed linker ---", linker,
    f"linker SHA256: {manifest['toolchain']['linker_sha256']}",
    "toolchain repository: https://github.com/friendlyarm/prebuilts",
    f"toolchain commit: {manifest['toolchain']['commit']}",
    f"toolchain archive: {manifest['toolchain']['archive']}",
    f"toolchain archive Git blob: {manifest['toolchain']['archive_git_blob']}",
    f"toolchain provenance: {manifest['toolchain']['archive_provenance']}",
    f"pahole: {pahole}",
    "--- deterministic build identity ---",
    *[f"{key}={value}" for key, value in identity.items()],
    manifest["generated_compile_header"].rstrip(),
    manifest["generated_release_header"].rstrip(),
    "--- config provenance ---",
    f"runtime config SHA256: {baseline_sha}",
    f"build config SHA256: {manifest['config']['build_sha256']}",
    json.dumps(changes, indent=2, sort_keys=True),
    "--- raw BTF ---",
    f"file: {btf.name}", f"size: {size} bytes", "magic: 0xeb9f (little-endian), version: 1",
    f"type bytes: {type_len}; string bytes: {str_len}",
    f"BTF SHA256: {manifest['btf']['sha256']}",
    "--- compatibility limits ---", *limits,
]
(out / "build-info.txt").write_text("\n".join(info) + "\n")
manifest["files"] = [
    {"name": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}
    for path in sorted(out.iterdir()) if path.is_file()
]
(out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
(out / "SHA256SUMS").write_text("".join(
    f"{sha256(path)}  {path.name}\n"
    for path in sorted(out.iterdir()) if path.is_file() and path.name != "SHA256SUMS"
))
print(f"Validated raw little-endian BTF: {btf.name}, {size} bytes, SHA256 {manifest['btf']['sha256']}")
PY
printf 'External BTF artifacts: %s\n' "$output_dir"
