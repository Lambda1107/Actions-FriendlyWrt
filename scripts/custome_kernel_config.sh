#!/bin/bash

# Custom kernel defconfig tweaks, applied to
# kernel/arch/arm64/configs/<first field of TARGET_KERNEL_CONFIG>.
#
# Added for dae (eBPF-based transparent proxy) support:
#   - CONFIG_DEBUG_INFO_BTF: BTF type info is embedded into the kernel and
#     exposed at /sys/kernel/btf/vmlinux; libbpf / cilium-ebpf uses it to
#     resolve CO-RE relocations when dae loads its eBPF programs.
#   - CONFIG_KPROBES / CONFIG_KPROBE_EVENTS / CONFIG_BPF_STREAM_PARSER:
#     part of dae's documented kernel configuration requirements.
#   - CONFIG_DEBUG_INFO_REDUCED must be "not set", otherwise Kconfig hides
#     CONFIG_DEBUG_INFO_BTF (it depends on DEBUG_INFO && !DEBUG_INFO_REDUCED).
#   - CONFIG_DEBUG_INFO_DWARF4 pins the debug info dialect so that BTF
#     generation works with the build host's pahole version regardless of
#     the compiler's default DWARF version.

CONFIGS=(
  "CONFIG_NET_ACT_CT=m"
  "CONFIG_NET_ACT_CTINFO=m"
  "CONFIG_DEBUG_INFO=y"
  "CONFIG_DEBUG_INFO_DWARF4=y"
  "CONFIG_DEBUG_INFO_BTF=y"
  "CONFIG_KPROBES=y"
  "CONFIG_KPROBE_EVENTS=y"
  "CONFIG_BPF_STREAM_PARSER=y"
)

source .current_config.mk
KCFG=kernel/arch/arm64/configs/$(awk '{print $1}' <<< "$TARGET_KERNEL_CONFIG")

for CFG in "${CONFIGS[@]}"; do
  KEY=${CFG%%=*}
  if grep -q "^#\?${KEY}=" "${KCFG}"; then
    sed -i "s@^#\?${KEY}=.*@${CFG}@g" "${KCFG}"
  else
    echo "$CFG" >> "${KCFG}"
  fi
done

# CONFIG_DEBUG_INFO_REDUCED must be disabled for CONFIG_DEBUG_INFO_BTF to be selectable
if grep -q "^CONFIG_DEBUG_INFO_REDUCED=" "${KCFG}"; then
  sed -i "s@^CONFIG_DEBUG_INFO_REDUCED=.*@# CONFIG_DEBUG_INFO_REDUCED is not set@g" "${KCFG}"
elif ! grep -q "^# CONFIG_DEBUG_INFO_REDUCED is not set" "${KCFG}"; then
  echo "# CONFIG_DEBUG_INFO_REDUCED is not set" >> "${KCFG}"
fi
