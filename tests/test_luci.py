"""Exercise the real Lua controller with in-memory LuCI/nixio substitutes."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = r'''
files = { ["/var/run/xlnetacc/state"] = "manual\nimage.current\n" }
params = { generation = "image.current", action = "submit", code = "aB12", token = "valid" }
method = "POST"
running = true
status_code = 200
commands = {}
luci = {
    sys = { call = function(command)
        if command:match("^pidof") then return running and 0 or 1 end
        table.insert(commands, command); return 0
    end },
    dispatcher = { test_post_security = function()
        if method ~= "POST" then status_code = 405; return false end
        if params.token ~= "valid" then status_code = 403; return false end
        return true
    end },
    http = {
        formvalue = function(key) return params[key] end,
        status = function(code) status_code = code end,
        prepare_content = function(mime) content_type = mime end,
        write_json = function(data) response = data end,
        write = function(data) body = data end,
        header = function() end
    }
}
nixio = {
    getpid = function() return 123 end,
    open_flags = function() return 0 end,
    open = function(path)
        if files[path] then return nil end
        return {
            write = function(self, data) files[path] = data; return #data end,
            close = function() end
        }
    end,
    fs = {
        readfile = function(path) return files[path] end,
        remove = function(path) files[path] = nil; return true end,
        rename = function(src, dst) files[dst] = files[src]; files[src] = nil; return true end,
        access = function() return true end,
        stat = function() return nil end,
        rmdir = function() return true end
    }
}
package.preload['luci.model.uci'] = function()
    return { cursor = function() return { get = function() return '4' end } end }
end
'''

class LuciTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE)
        self.lua.execute((ROOT/'files/luci/controller/xlnetacc.lua').read_text(encoding='utf-8'))
        self.controller = self.lua.eval("package.loaded['luci.controller.xlnetacc']")
        self.globals = self.lua.globals()

    def test_lua_model_syntax(self):
        source = (ROOT/'files/luci/model/cbi/xlnetacc.lua').read_text(encoding='utf-8')
        self.lua.execute('assert(loadstring(...))', source)

    def test_valid_submission_queues_generation_and_code(self):
        self.controller.action_captcha()
        self.assertEqual(self.globals.status_code, 200)
        self.assertEqual(self.globals.files['/var/run/xlnetacc/request'], 'image.current\nsubmit\naB12\n')

    def test_stale_generation_rejected(self):
        self.globals.params.generation = 'old'
        self.controller.action_captcha()
        self.assertEqual(self.globals.status_code, 409)
        self.assertIsNone(self.globals.files['/var/run/xlnetacc/request'])

    def test_get_cannot_submit(self):
        self.globals.method = 'GET'
        self.controller.action_captcha()
        self.assertEqual(self.globals.status_code, 405)

    def test_csrf_cannot_submit_or_test_api(self):
        self.globals.params.token = 'invalid'
        self.controller.action_captcha()
        self.assertEqual(self.globals.status_code, 403)
        self.controller.action_test_api()
        self.assertEqual(len(self.globals.commands), 0)

    def test_invalid_text_rejected_without_shell_execution(self):
        self.globals.params.code = '$(reboot)'
        self.controller.action_captcha()
        self.assertEqual(self.globals.status_code, 400)
        self.assertEqual(len(self.globals.commands), 0)

    def test_service_must_be_running(self):
        self.globals.running = False
        self.controller.action_captcha()
        self.assertEqual(self.globals.status_code, 409)

    def test_image_generation_checked(self):
        self.globals.files['/var/run/xlnetacc/image'] = 'image-bytes'
        self.globals.params.generation = 'old'
        self.controller.action_captcha_image()
        self.assertEqual(self.globals.status_code, 409)
        self.assertIsNone(self.globals.body)

    def test_image_uses_detected_type(self):
        self.globals.files['/var/run/xlnetacc/image'] = 'image-bytes'
        self.globals.files['/var/run/xlnetacc/mime'] = 'image/png'
        self.controller.action_captcha_image()
        self.assertEqual(self.globals.content_type, 'image/png')
        self.assertEqual(self.globals.body, 'image-bytes')

    def test_expired_challenge_can_be_refreshed(self):
        self.globals.files['/var/run/xlnetacc/state'] = 'expired\n\n'
        self.globals.params.generation = ''
        self.globals.params.action = 'refresh'
        self.controller.action_captcha()
        self.assertEqual(self.globals.status_code, 200)

    def test_test_api_launches_fixed_helper(self):
        self.controller.action_test_api()
        self.assertEqual(self.globals.status_code, 200)
        self.assertEqual(self.globals.commands[1], '/usr/bin/xlnetacc-test >/dev/null 2>&1 &')

if __name__ == '__main__': unittest.main()
