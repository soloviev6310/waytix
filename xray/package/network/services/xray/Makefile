include $(TOPDIR)/rules.mk

PKG_NAME:=xray
PKG_VERSION:=1.8.4
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/XTLS/Xray-core/releases/download/v$(PKG_VERSION)/
PKG_HASH:=skip

PKG_MAINTAINER:=Waytix Team <support@waytix.org>
PKG_LICENSE:=MPL-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0

GO_PKG:=github.com/xtls/xray-core
GO_PKG_BUILD_PKG:=$(GO_PKG)/main
GO_PKG_LDFLAGS:=-s -w

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/xray
  TITLE:=Xray, Penetrates Everything.
  URL:=https://github.com/xtls/xray-core
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=+ca-bundle +libpthread +libpcre2
endef

define Package/xray/description
  Xray, Penetrates Everything. Also the best V2Ray-core, with XTLS support. 
  XTLS implements TLS & XTLS in-proxy protocol, optimized for FULL CONNECT.
endef

define Package/xray/install
	$(call GoPackage/Package/Install/Bin,$(1))
	$(INSTALL_DIR) $(1)/etc/xray
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/release/config/*.json $(1)/etc/xray/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/xray $(1)/usr/bin/
endef

$(eval $(call GoBinPackage,xray))
$(eval $(call BuildPackage,xray))
