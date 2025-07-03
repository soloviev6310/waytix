include $(TOPDIR)/rules.mk

LUCI_TITLE:=Waytix VPN Manager
LUCI_DEPENDS:=+xray +luci-lib-ipkg +luci-lib-nixio +luci-compat +luci-mod-admin-full +curl +jq
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-waytix
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Waytix Team <support@waytix.org>
PKG_LICENSE:=GPL-3.0
PKG_LICENSE_FILES:=LICENSE

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
