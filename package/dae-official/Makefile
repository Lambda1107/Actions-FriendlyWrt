# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=dae-official
PKG_VERSION:=2.1.1
PKG_RELEASE:=2

PKG_SOURCE:=dae-linux-arm64.tar.xz
PKG_SOURCE_URL:=https://github.com/daeuniverse/dae/releases/download/v$(PKG_VERSION)
PKG_HASH:=bd84b6770cb335b8a45d8b1e16a95f68cf940b3edaaeeb449c187ce4b1058d0b
PKG_LICENSE:=AGPL-3.0-only
PKG_URL:=https://github.com/daeuniverse/dae

include $(INCLUDE_DIR)/package.mk
# Preserve the pinned upstream binary byte-for-byte in the resulting APK.
RSTRIP:=:

define Package/dae-official
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Official prebuilt dae transparent proxy
  URL:=$(PKG_URL)
  PKGARCH:=aarch64_generic
  DEPENDS:=+v2ray-geoip +v2ray-geosite
endef

define Package/dae-official/description
  Official dae v2.1.1 ARM64 binary. External BTF matching the running kernel
  must be installed separately; no kernel modules or geodata are bundled.
endef

define Package/dae-official/conffiles
/etc/config/dae
endef

# The upstream archive has ./usr/bin/dae at its root, not a versioned top-level
# directory. OpenWrt's default unpacker extracts next to PKG_BUILD_DIR instead.
define Build/Prepare
	[ "$(ARCH_PACKAGES)" = "aarch64_generic" ] || { echo "dae-official requires aarch64_generic" >&2; exit 1; }
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -C $(PKG_BUILD_DIR) -xJf $(DL_DIR)/$(PKG_SOURCE)
	printf '%s  %s\n' '3fc8198a1cdd7323992fc2b31cdd8742df98014fb9a6dfa8581bb8a2ec5fad50' '$(PKG_BUILD_DIR)/usr/bin/dae' | sha256sum -c -
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/dae-official/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d $(1)/etc/config $(1)/etc/dae
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/dae $(1)/usr/bin/dae
	$(INSTALL_BIN) $(CURDIR)/files/dae.init $(1)/etc/init.d/dae
	$(INSTALL_CONF) $(CURDIR)/files/dae.config $(1)/etc/config/dae
	$(INSTALL_CONF) $(CURDIR)/files/example.dae $(1)/etc/dae/example.dae
endef

$(eval $(call BuildPackage,dae-official))
