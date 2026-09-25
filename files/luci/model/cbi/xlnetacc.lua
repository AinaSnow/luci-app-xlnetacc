local m, s, o
local uci = luci.model.uci.cursor()

m = Map("xlnetacc", "%s - %s" %{translate("XLNetAcc"), translate("Settings")}, translate("XLNetAcc is a Thunder joint broadband operators launched a commitment to help users solve the low broadband, slow Internet access, poor Internet experience of professional-grade broadband upgrade software."))
m:append(Template("xlnetacc/status"))

s = m:section(NamedSection, "general", "general", translate("General Settings"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("Enabled"))
o.rmempty = false

o = s:option(Flag, "down_acc", translate("Enable DownLink Upgrade"))

o = s:option(Flag, "up_acc", translate("Enable UpLink Upgrade"))

o = s:option(Flag, "logging", translate("Enable Logging"))
o.default = "1"

o = s:option(Flag, "verbose", translate("Enable verbose logging"))
o:depends("logging", "1")

o = s:option(ListValue, "network", translate("Upgrade interface"))
uci:foreach("network", "interface", function(section)
	if section[".name"] ~= "loopback" then
		o:value(section[".name"])
	end
end)

o = s:option(Value, "keepalive", translate("Keepalive interval"), "5-60 " .. translate("minutes"))
for _, v in ipairs({5, 10, 20, 30, 60}) do
	o:value(v, v .. " " .. translate("minutes"))
end
o.datatype = "range(5, 60)"
o.default = 10

o = s:option(Value, "relogin", translate("Account relogin"), "1-48 " .. translate("hours"))
o:value(0, translate("Not enabled"))
for _, v in ipairs({3, 12, 18, 24, 30}) do
	o:value(v, v .. " " .. translate("hours"))
end
o.datatype = "max(48)"
o.default = 0

o = s:option(Value, "account", translate("XLNetAcc account"))

o = s:option(Value, "password", translate("XLNetAcc password"))
o.password = true

o = s:option(Value, "base_url", translate("Captcha AI Base URL"), translate("Include the API prefix, for example https://api.example.com/v1. System routing is used."))
o.placeholder = "https://openrouter.ai/api/v1"
function o.validate(self, value)
	if value and (value:match("^https?://[^%s]+$")) then return value end
	return nil, translate("Enter a valid HTTP or HTTPS URL.")
end

o = s:option(Value, "api_key", translate("Captcha AI API Key"), translate("Leave empty to switch back to manual captcha input."))
o.password = true

o = s:option(Value, "model", translate("Captcha AI Model"), translate("Model name for captcha recognition."))
o.placeholder = ""

o = s:option(Value, "ai_timeout", translate("Recognition timeout"), translate("Total request timeout in seconds, including connection time."))
o.datatype = "range(15,180)"
o.default = "90"
o.rmempty = false

o = s:option(Value, "ai_max_tokens", translate("Model output limit"), translate("Increase this if a reasoning model returns no visible text. A fast vision model is recommended."))
o.datatype = "range(64,8192)"
o.default = "1024"
o.rmempty = false

o = s:option(ListValue, "captcha_length", translate("Captcha length"), translate("Only ASCII letters and digits are accepted. Select an exact length after checking your captcha."))
o:value("0", translate("4 to 8 characters"))
for _, v in ipairs({4, 5, 6, 7, 8}) do o:value(tostring(v)) end
o.default = "0"
o.rmempty = false

return m
