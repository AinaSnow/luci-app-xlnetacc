module("luci.controller.xlnetacc", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/xlnetacc") then
		return
	end

	entry({"admin", "services", "xlnetacc"},
		firstchild(), _("XLNetAcc")).dependent = false

	entry({"admin", "services", "xlnetacc", "general"},
		cbi("xlnetacc"), _("Settings"), 1)

	entry({"admin", "services", "xlnetacc", "log"},
		template("xlnetacc/logview"), _("Log"), 2)

	entry({"admin", "services", "xlnetacc", "status"}, call("action_status"))
	entry({"admin", "services", "xlnetacc", "logdata"}, call("action_log"))
	entry({"admin", "services", "xlnetacc", "captcha_image"}, call("action_captcha_image"))
	entry({"admin", "services", "xlnetacc", "captcha"}, post("action_captcha"))
	entry({"admin", "services", "xlnetacc", "test_api"}, post("action_test_api"))
end

local function is_running(name)
	return luci.sys.call(string.format("pidof %s >/dev/null", name)) == 0
end

local runtime = "/var/run/xlnetacc"

local function captcha_state()
	local data = nixio.fs.readfile(runtime .. "/state") or ""
	local stage, generation = data:match("^([^\n]*)\n([^\n]*)\n$")
	if not is_running("xlnetacc.sh") then stage, generation = "stopped", "" end
	return { stage = stage or "idle", generation = generation or "" }
end

local function reply(code, message)
	luci.http.status(code)
	luci.http.prepare_content("application/json")
	luci.http.write_json({ ok = code == 200, message = message })
end

function action_status()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		run_state = is_running("xlnetacc.sh"),
		down_state = nixio.fs.readfile("/var/state/xlnetacc_down_state") or "",
		up_state = nixio.fs.readfile("/var/state/xlnetacc_up_state") or "",
		captcha = captcha_state(),
		api_test = nixio.fs.readfile(runtime .. "/test.status") or ""
	})
end

function action_captcha_image()
	local state = captcha_state()
	if state.generation == "" or luci.http.formvalue("generation") ~= state.generation then
		return reply(409, "验证码已刷新，请等待页面更新")
	end
	local data = nixio.fs.readfile(runtime .. "/image")
	local mime = nixio.fs.readfile(runtime .. "/mime") or "image/jpeg"
	if not data or #data > 1048576 or captcha_state().generation ~= state.generation then
		return reply(409, "验证码图片暂不可用")
	end
	luci.http.header("Cache-Control", "no-store")
	luci.http.prepare_content(mime)
	luci.http.write(data)
end

function action_captcha()
	if not luci.dispatcher.test_post_security() then return end
	local state = captcha_state()
	local generation = luci.http.formvalue("generation") or ""
	local action = luci.http.formvalue("action")
	local code = luci.http.formvalue("code") or ""
	if generation ~= state.generation then return reply(409, "验证码已刷新，请重新输入") end
	local can_refresh = state.stage == "manual" or state.stage == "expired" or state.stage == "download_error"
	if action == "submit" then
		if state.stage ~= "manual" then return reply(409, "当前不在等待输入状态") end
		local uci = require("luci.model.uci").cursor()
		local length = tonumber(uci:get("xlnetacc", "general", "captcha_length")) or 0
		if #code < 4 or #code > 8 or code:find("[^a-zA-Z0-9]") or
			(length >= 1 and length <= 8 and #code ~= length) then
			return reply(400, "请输入符合配置长度的英文字母或数字验证码")
		end
	elseif action ~= "refresh" or not can_refresh then
		return reply(409, "当前无法刷新验证码")
	end
	local path = runtime .. "/request." .. nixio.getpid()
	local fd = nixio.open(path, nixio.open_flags("wronly", "creat", "excl"), 384)
	if not fd then return reply(503, "无法写入请求，请稍后重试") end
	local data = generation .. "\n" .. action .. "\n" .. code .. "\n"
	local written = fd:write(data)
	fd:close()
	local current = captcha_state()
	if written ~= #data or current.generation ~= generation or current.stage ~= state.stage then
		nixio.fs.remove(path)
		return reply(409, "验证码状态已改变，请稍后重试")
	end
	if not nixio.fs.rename(path, runtime .. "/request") then
		nixio.fs.remove(path)
		return reply(503, "提交失败，请稍后重试")
	end
	reply(200, action == "submit" and "已提交，正在验证" or "正在获取新验证码")
end

function action_test_api()
	if not luci.dispatcher.test_post_security() then return end
	if not nixio.fs.access("/usr/bin/xlnetacc-test") then return reply(503, "测试组件未安装") end
	local lock = nixio.fs.stat(runtime .. "/test.lock")
	if lock and os.time() - lock.mtime <= 210 then return reply(409, "识别服务测试正在进行") end
	if lock then nixio.fs.rmdir(runtime .. "/test.lock") end
	-- Fixed command: API credentials are read from UCI by the helper, never from argv.
	if luci.sys.call("/usr/bin/xlnetacc-test >/dev/null 2>&1 &") ~= 0 then
		return reply(503, "无法启动测试")
	end
	reply(200, "测试已启动，使用已保存的配置")
end

function action_log()
	local uci = require "luci.model.uci".cursor()
	local util = require "luci.util"
	local log_data = { }

	log_data.syslog = util.trim(util.exec("logread | grep xlnetacc"))
	if uci:get("xlnetacc", "general", "logging") ~= "0" then
		log_data.client = nixio.fs.readfile("/var/log/xlnetacc.log") or ""
	end
	uci:unload("xlnetacc")

	luci.http.prepare_content("application/json")
	luci.http.write_json(log_data)
end
