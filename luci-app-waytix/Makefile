include $(TOPDIR)/rules.mk

LUCI_TITLE:=Waytix VPN Manager
LUCI_DEPENDS:=+xray +luci-lib-ipkg +luci-lib-nixio +luci-compat +luci-mod-admin-full +curl +jq +luci-lib-jsonc +luci-lib-httpclient
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-waytix
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Waytix Team <support@waytix.org>
PKG_LICENSE:=GPL-3.0
PKG_LICENSE_FILES:=LICENSE

include $(TOPDIR)/feeds/luci/luci.mk

# Указываем зависимости времени выполнения
define Package/$(PKG_NAME)/conffiles
/etc/config/waytix
endef

# Добавляем скрипты в пакет
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/waytix $(1)/etc/init.d/
	
	$(INSTALL_DIR) $(1)/etc/waytix
	$(INSTALL_BIN) ./root/etc/waytix/*.sh $(1)/etc/waytix/
	
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/waytix $(1)/etc/config/
	
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./root/usr/sbin/waytixd $(1)/usr/sbin/
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/waytix.lua $(1)/usr/lib/lua/luci/controller/
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/waytix
	$(INSTALL_DATA) ./luasrc/model/cbi/waytix/waytix.lua $(1)/usr/lib/lua/luci/model/cbi/waytix/
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/waytix
	$(INSTALL_DATA) ./luasrc/view/waytix/*.htm $(1)/usr/lib/lua/luci/view/waytix/
	
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/*.json $(1)/usr/share/rpcd/acl.d/
endef

# Добавляем скрипт postinst
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# Устанавливаем права на выполнение
	chmod +x /etc/init.d/waytix
	chmod +x /etc/waytix/*.sh
	chmod +x /usr/sbin/waytixd
	
	# Включаем автозапуск
	/etc/init.d/waytix enable
	echo "\n========================================"
	echo "Waytix VPN успешно установлен!"
	echo "Откройте веб-интерфейс LuCI и перейдите в раздел:"
	echo "Сервисы -> Шарманка 3000"
	echo "========================================\n"
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
