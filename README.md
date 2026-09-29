# 使用 GitHub Actions 编译 FriendlyWrt
[English](README_en.md)
### 基本信息 
- 用户名：root
- 密码：password
- 后台IP：192.168.2.1
- 固件下载地址： https://github.com/friendlyarm/Actions-FriendlyWrt/releases
- 更多使用说明: https://wiki.friendlyelec.com/wiki/index.php/Template:FriendlyWrt21/zh
### 固件文件说明
- XYZ.img.gz：固件镜像，可写入 SD 卡或 eMMC 启动。
- images-XYZ.tgz：升级包，仅供 "eMMC 刷机助手" 使用，不能直接写入 SD 卡启动。
### 如何刷入 eMMC
- 首次安装：先将 XYZ.img.gz 写入 SD 卡并启动系统，进入 FriendlyWrt 后台 → "系统" → "eMMC 刷机助手"，上传固件直接刷入（无需解压）。完成后弹出 SD 卡，设备会自动重启并从 eMMC 启动。
- 小版本升级（如 25.12.2 → 25.12.3）：在 "eMMC 刷机助手" 中刷入 images-XXYYZZ.tgz，可选择保留数据，但兼容性需自行评估。
- 大版本升级（如 24.10 → 25.12）：建议先[备份配置](https://openwrt.org/docs/guide-user/troubleshooting/backup_restore)，然后使用 XYZ.img.gz 全量安装，以避免兼容性问题。
### 仅构建 szr 当前内核的外置 BTF

在 Actions 中手动运行 **Build External BTF (szr 6.6.134+)**（`build-external-btf.yml`）。它面向 NanoPi R2S、FriendlyWrt 2026/06/09 的 `6.6.134+` 内核，不构建或刷写固件，也不会连接路由器。

- 输入位于 `btf/szr-6.6.134+.config` 和同名 JSON：配置从运行内核导出，源码、FriendlyARM GCC 11.3/binutils 2.38、pahole 1.25 均固定版本。
- 只关闭 `CONFIG_DEBUG_INFO_REDUCED` 以生成完整 DWARF，再用 pahole 提取独立 BTF。任何功能配置漂移都会停止构建；不会开启 KPROBES、BPF_STREAM_PARSER 或内核内置 BTF。
- 成功产物为 `external-btf-szr-6.6.134-plus`，包含原始 BTF 文件 `vmlinux-6.6.134+`、原始/构建配置、来源信息、检查结果和 `SHA256SUMS`。不包含用于刷机的内核镜像或模块包。
- 工作流用 dae v2.1.1 所用的 `cilium/ebpf v0.22.0` 解码产物并检查核心结构体字段边界，不执行任何 BPF 加载。

外置 BTF 已在 szr 的 `6.6.134+` 内核上完成 dae v2.1.1 核心 BPF 加载，以及仅绑定隔离 veth 的 IPv4 TCP 代理路径试验；源码提交与固件镜像原始源码仍未独立核对。当前测试环境使用指向 `/tmp` 的 BTF 链接，重启即失效；正式启用开机服务前必须改为持久存放、核对哈希。工作流不会上传文件到路由器。

原有 `build-kernel-btf.yml` 是更换内核用的另一套流程，会开启额外内核功能。其 BTF 不能直接当作当前未更换内核的匹配文件。

### 构建官方 dae 的 OpenWrt APK

在 Actions 中手动运行 **Build official dae APK (OpenWrt 25.12.4)**（`build-dae-official-apk.yml`）。目标是 NanoPi R2S 的 `rockchip/armv8`、`aarch64_generic`；它使用官方 dae v2.1.1 ARM64 静态二进制及固定哈希，在匹配版本的 OpenWrt SDK 中构建 `dae-official-2.1.1-r2` APK，不编译新的 dae 核心、内核或模块，也不连接路由器。

- APK 声明依赖 OpenWrt 官方 `v2ray-geoip`、`v2ray-geosite`，从 `/usr/share/v2ray` 加载两份 `.dat`；不捆绑重复、易过期的数据文件。外置 BTF 仍需单独、持久地放在 `/usr/lib/debug/boot/vmlinux-6.6.134+`。
- 包拥有 `/usr/bin/dae`、`/etc/init.d/dae`、`/etc/config/dae` 和 `/etc/dae/example.dae`；**不附带**可直接运行的 `/etc/dae/config.dae`，也不自动绑定任何网络接口。示例中的 LAN 绑定已注释，使用前需要检查 DNS 入口与 WireGuard 回滚路径。
- r2 示例明确使用 `tcp+udp://127.0.0.1:5336`：仅写 `127.0.0.1:5336` 时 dae v2.1.1 **只监听 UDP**。已经从 r1 示例复制出的 `/etc/dae/config.dae` 不属于 APK 管理，升级包不会修改它；切换客户端 DNS 前须由管理员单独改为 TCP+UDP、重新校验并确认 TCP 查询可用。
- OpenWrt 的通用安装钩子可能注册 `/etc/rc.d` 服务链接并调用 `start`；但 UCI 默认 `enabled=0`，init 脚本会在打开 procd 实例之前退出。实际启用还要求 root 所有、0600 的 `/etc/dae/config.dae`、有效的持久 BTF 与两份 Geo 数据，并先运行 `dae validate`。
- 产物来自用户 fork 的 Actions，不是 OpenWrt 官方签名软件源。安装 APK 和任何路由器写操作由使用者执行；核对 Actions 产物 `SHA256SUMS`，不要用自动安装脚本绕过签名检查或自动拉取不匹配运行内核的 kmod。

### 更新说明
* 2026/08/07
    *  增加 NanoPi-R28S 支持
    *  修正 RTL8125 相关问题 [#130](https://github.com/friendlyarm/Actions-FriendlyWrt/issues/130)
* 2026/07/22
    *  更新RTL8125驱动, 提升2.5G网卡性能，降低待机功耗
* 2026/07/08
    *  更新到新版本 openwrt-25.12.5
* 2026/06/25
    *  新增对 NanoPC-T4 和 NanoPi-M4v2 板载 WiFi 的支持
* 2026/06/09
    *  RK33xx内核更新至6.6.134, 优化内核配置，修复重启后 USB 设备偶发无法工作的问题
    *  增加 NanoPi-M6V2 支持
* 2026/06/05
    *  更新到新版本 openwrt-25.12.4
* 2026/04/29
    *  更新到新版本 openwrt-25.12.2
    *  更新了"eMMC 刷机助手"，加强稳定性，支持更多格式
    *  内核启用内置fq_codel队列调度以改善网络延迟
* 2026/03/06
    *  增加 NanoPi-NEO3-Plus 支持
* 2025/12/31
    *  更新到新版本 openwrt-24.10.4
    *  RK35xx内核更新至6.1.141
* 2025/08/04
    *  RK35xx内核更新至6.1.118
* 2025/07/09
    *  增加 NanoPi-R76S 支持
    *  修复 PWM 风扇控制问题 (使用pwm-fan驱动模块)
* 2025/06/30
    *  更新到新版本 openwrt-24.10.2
    *  更新了内核网络部分的配置
* 2025/06/25
    *  增加 NanoPi-R3S-LTS 支持
* 2025/06/06
    *  增加 NanoPi-M5 支持
    *  增加 RTL8851BU 无线网卡的支持
* 2025/03/24
    *  修正opt分区inode过小的问题
    *  从eMMC启动时，为内存超1G设备重新启用eMMC刷机助手
* 2025/02/28
    *  更新到新版本 openwrt-24.10.0
    *  RK33xx内核更新至6.6.78+
    *  调整分区：固定根分区大小，增加独立分区以提升 Docker 存储性能，恢复出厂设置后该分区数据仍会得到保留
* 2025/02/11
    *  RK35xx内核更新至6.1.99
* 2024/12/09
    *  修正luci-app-diskman插件的显示问题 (thanks [helmx](https://github.com/helmx))
* 2024/10/16
    *  更新到新版本 openwrt-23.05.5
    *  增加 NanoPi-Zero2 支持
* 2024/09/14 增加NanoPi-R3S支持
* 2024/08/30
    *  更新到新版本 openwrt-23.05.4
    *  增加 NanoPi-M6 支持
* 2024/07/03
    *  修复因固件丢失而导致的WIFI问题
* 2024/06/06
    *  RK35xx内核更新至6.1.57
* 2024/03/29
    *  更新到新版本 openwrt-23.05.3
* 2024/02/02
    *  为模块rtl8822ce增加无线中继模式的支持,[设置方法](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_R5C/zh#.E6.97.A0.E7.BA.BF.E4.B8.AD.E7.BB.A7.E6.A8.A1.E5.BC.8F)
* 2023/12/22
    *  更新到新版本 openwrt-23.05.2
    *  修正eMMC刷机工具对大容量eMMC的兼容性问题
* 2023/10/31
    *  更新到新版本 openwrt-23.05.0
    *  内核更新至6.1
* 2023/07/04
    *  内核更新至5.10.160 (rk3568/rk3588)
* 2023/06/10
    *  增加 MediaTek MT7921 无线网卡的支持
* 2023/05/31
    *  增加 NanoPC-T6 支持
    *  更新 v22.03 到新版本 openwrt-22.03.5
    *  更新 v21.02 到新版本 openwrt-21.02.7
* 2023/04/26
    *  增加 R5C-2GB 支持
    *  更新 v22.03 到新版本 openwrt-22.03.4
    *  更新 v21.02 到新版本 openwrt-21.02.6
* 2023/03/15
    *  增加R6C支持
    *  更新initramfs,[可禁用OverlayFS或者创建额外的分区](https://wiki.friendlyelec.com/wiki/index.php/How_to_use_overlayfs_on_Linux/zh)
* 2023/03/01
    *  更新到新版本 openwrt-22.03.3
    *  为rk3568/rk3588的5.10内核增加ntfs3驱动
    *  更新内核小版本
    *  更新网卡驱动
* 2022/12/04
    *  增加R5C支持
    *  修正存储空间某些情况下无法扩展的问题
    *  加强eMMC刷机工具的刷机稳定性
* 2022/11/24
    *  修正R6S 1G网口不可用问题  
    *  eMMC刷机工具现可以在eMMC启动时使用  
* 2022/11/01 增加R6S支持
* 2022/10/09 首次发布
### Thanks / 致谢
- [luci-app-diskman](https://github.com/lisaac/luci-app-diskman)
- [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
- [P3TERX](https://github.com/P3TERX/Actions-OpenWrt)
- [NanoPi-R1S-Build-By-Actions](https://github.com/skytotwo/NanoPi-R1S-Build-By-Actions)
- [QiuSimons](https://github.com/QiuSimons/YAOF)
