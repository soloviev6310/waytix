local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local http = require "luci.http"

m = Map("waytix", translate("Шарманка 3000"), 
    translate("Управление VPN-подключениями"))

-- Секция конфигурации
s = m:section(NamedSection, "config", "waytix", 
    translate("Настройки подключения"))

-- Поле для ввода ссылки на подписку
o = s:option(Value, "sub_link", 
    translate("Ссылка на подписку"),
    translate("Введите URL подписки в формате https://..."))
o.rmempty = false

-- Кнопка обновления списка серверов
update_btn = s:option(Button, "_update", translate("Загрузить список серверов"))
update_btn.inputstyle = "apply"
function update_btn.write()
    luci.http.redirect(luci.dispatcher.build_url("admin/services/waytix/update"))
end

-- Выпадающий список серверов
servers = uci:get_all("waytix", "servers")
local server_list = {}
if servers then
    for k, v in pairs(servers) do
        if k ~= ".name" and k ~= ".anonymous" and k ~= ".type" then
            server_list[k] = v.name or k
        end
    end
end

o = s:option(ListValue, "selected_server", 
    translate("Выберите сервер"))
for k, v in pairs(server_list) do
    o:value(k, v)
end
if #o:get_titles() == 0 then
    o:value("", "-- Нет доступных серверов --")
end

-- Кнопки управления подключением
control = s:option(SimpleSection)
control.template = "waytix/control"

-- Статус подключения
status = s:option(DummyValue, "_status", translate("Статус подключения"))
status.template = "waytix/status"

-- Обработка сохранения формы
function m.on_commit(self)
    if m:formvalue("cbi.apply") then
        os.execute("/etc/init.d/waytix restart >/dev/null 2>&1 &")
    end
end

return m
