import base64
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'files/root/usr/lib/xlnetacc/captcha.sh'
BASH = os.environ.get('TEST_SHELL') or shutil.which('bash')

def shell_path(path):
    value = str(path).replace('\\', '/')
    if len(value) > 1 and value[1] == ':': value = '/' + value[0].lower() + value[2:]
    return value

JSON_SHIM = r'''
jhelper() { python "$JSON_HELPER" "$@"; }
json_init() { jhelper init; }
json_load() { jhelper load "$1"; }
json_dump() { jhelper dump; }
json_add_string() { jhelper add string "$@"; }
json_add_int() { jhelper add int "$@"; }
json_add_boolean() { jhelper add boolean "$@"; }
json_add_array() { jhelper add array "$@"; }
json_add_object() { jhelper add object "$@"; }
json_close_object() { jhelper close; }
json_close_array() { jhelper close; }
json_select() { jhelper select "$@"; }
json_get_var() { eval "$(jhelper assign "$1" "$2")"; }
json_get_type() { eval "$(jhelper assign_type "$1" "$2")"; }
'''

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        self.server.received.append((self.path, json.loads(data), dict(self.headers)))
        time.sleep(self.server.delay)
        self.send_response(self.server.status)
        self.send_header('Content-Type', 'application/json')
        body = self.server.body
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError): pass

class CaptchaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.daemon_threads = True
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls): cls.server.shutdown(); cls.server.server_close()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='.captcha-test-', dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.server.received = []
        self.server.delay = 0
        self.server.status = 200
        self.server.body = json.dumps({'choices': [{'message': {'content': 'aB12'}}]}).encode()

    def run_shell(self, code, shim=False):
        env = os.environ.copy()
        env.update(JSON_STATE=str(self.dir/'json.json'), JSON_HELPER=shell_path(ROOT/'tests/json_helper.py'),
                   LIB=shell_path(LIB), TEST_TMP=shell_path(self.dir),
                   TEST_IMAGE=shell_path(ROOT/'files/root/usr/share/xlnetacc/test.png'))
        env['PATH'] = str(Path(os.sys.executable).parent) + os.pathsep + env['PATH']
        prefix = '''. "$LIB"
captcha_dir="$TEST_TMP/runtime"
captcha_prepare || exit 99
_log() { printf '%s\\n' "$*" >> "$TEST_TMP/log"; }
chatgpt_api_key=secret-test-key
chatgpt_model='vision"model'
ai_timeout=15
ai_max_tokens=1024
captcha_length=4
'''
        prefix += f"chatgpt_base_url=http://127.0.0.1:{self.server.server_port}/v1\n"
        result = subprocess.run([BASH, '-c', prefix + (JSON_SHIM if shim else '') + code],
                                env=env, capture_output=True, text=True, encoding='utf-8', timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '', result.stderr)
        return result.stdout

    def request(self, setup=''):
        return self.run_shell(setup + '''
ai_request "$TEST_IMAGE" 'Read test text' image/png
printf 'RESULT=%s\nRETRY=%s\nCONTENT=%s\n%s\n' "$?" "$ai_retryable" "$ai_content" "$ai_diagnostic"
test -z "$(find "$captcha_dir" -name 'ai.*' -print)"
''', shim=True)

    def test_slow_response_over_five_seconds_and_payload(self):
        self.server.delay = 8
        out = self.request('_bind_ip=192.0.2.123\n')
        self.assertIn('RESULT=0', out)
        self.assertIn('CONTENT=aB12', out)
        path, data, headers = self.server.received[0]
        self.assertEqual(path, '/v1/chat/completions')
        self.assertEqual(data['model'], 'vision"model')
        self.assertEqual(data['max_tokens'], 1024)
        self.assertFalse(data['stream'])
        self.assertEqual(headers['Authorization'], 'Bearer secret-test-key')
        image = data['messages'][0]['content'][1]['image_url']['url']
        self.assertTrue(image.startswith('data:image/png;base64,'))
        self.assertEqual(base64.b64decode(image.split(',')[1]), (ROOT/'files/root/usr/share/xlnetacc/test.png').read_bytes())

    def test_timeout_is_diagnosed_and_retryable(self):
        self.server.delay = 1
        out = self.request('ai_timeout=0.2\n')
        self.assertIn('RESULT=1', out)
        self.assertIn('curl 28', out)
        self.assertIn('RETRY=1', out)

    def test_auth_failure_is_not_retried_or_logged_raw(self):
        self.server.status = 401
        self.server.body = b'{"error":{"message":"secret-test-key"}}'
        out = self.request()
        self.assertIn('HTTP 401', out)
        self.assertIn('RETRY=0', out)
        self.assertNotIn('secret-test-key', out)
        self.assertEqual(len(self.server.received), 1)

    def test_unavailable_is_retryable(self):
        self.server.status = 503
        self.assertIn('RETRY=1', self.request())

    def test_missing_configuration_never_calls_provider(self):
        self.assertIn('RESULT=2', self.request('chatgpt_model=\n'))
        self.assertEqual(self.server.received, [])

    def test_header_injection_rejected(self):
        self.assertIn('RESULT=2', self.request("chatgpt_api_key=$(printf 'key\\rBad: injected')\n"))
        self.assertEqual(self.server.received, [])

    def test_complete_endpoint_is_not_duplicated(self):
        self.request('chatgpt_base_url="$chatgpt_base_url/chat/completions/"\n')
        self.assertEqual(self.server.received[0][0], '/v1/chat/completions')

    def test_empty_content_is_not_a_success(self):
        self.server.body = b'{"choices":[{"message":{"content":null}}]}'
        self.assertIn('RESULT=1', self.request())

    def test_invalid_results_are_never_submitted(self):
        self.run_shell('''
for code in 'The code is ab12' 'abcd efgh' '<html>' '123' 'abcdefghi'; do
    if captcha_validate "$code"; then exit 1; fi
done
captcha_validate aB12 || exit 1
''')

    def test_transport_retry_keeps_image_and_key(self):
        self.run_shell('''
touch "$captcha_dir/image"
printf image/png > "$captcha_dir/mime"
printf original-key > "$captcha_dir/key"
calls=0
sleep() { :; }
ai_request() {
    calls=$((calls+1)); ai_retryable=1; ai_diagnostic=test
    [ "$calls" -eq 1 ] && return 1
    ai_content=aB12; return 0
}
swjsq_get_verify_code() { exit 10; }
swjsq_ai_recognize || exit 1
[ "$calls" -eq 2 ] && [ "$captcha_code" = aB12 ] && [ "$(cat "$captcha_dir/key")" = original-key ]
''')

    def test_transport_retries_are_bounded(self):
        self.run_shell('''
printf image/png > "$captcha_dir/mime"
calls=0
sleep() { :; }
ai_request() { calls=$((calls+1)); ai_retryable=1; ai_diagnostic=test; return 1; }
if swjsq_ai_recognize; then exit 1; fi
[ "$calls" -eq 2 ]
''')

    def test_three_rejected_submissions_then_manual(self):
        self.run_shell('''
calls=0; recognized=0; manual=0; downloads=0
swjsq_login_once() { calls=$((calls+1)); lasterr=6; return 1; }
swjsq_get_verify_code() { downloads=$((downloads+1)); printf key > "$captcha_dir/key"; }
swjsq_ai_recognize() { recognized=$((recognized+1)); captcha_code=abcd; }
captcha_wait_manual() { manual=$((manual+1)); return 1; }
if swjsq_login; then exit 1; fi
[ "$calls" -eq 4 ] && [ "$recognized" -eq 3 ] && [ "$manual" -eq 1 ] && [ "$downloads" -eq 4 ]
''')

    def test_non_captcha_login_failure_does_not_refresh(self):
        self.run_shell('''
calls=0; downloads=0
swjsq_login_once() { calls=$((calls+1)); if [ "$calls" -eq 1 ]; then lasterr=6; else lasterr=-3; fi; return 1; }
swjsq_get_verify_code() { downloads=$((downloads+1)); printf key > "$captcha_dir/key"; }
swjsq_ai_recognize() { captcha_code=abcd; }
if swjsq_login; then exit 1; fi
[ "$downloads" -eq 1 ] && [ "$(head -n 1 "$captcha_dir/state")" = login_error ]
''')

    def test_stale_manual_submission_is_ignored(self):
        self.run_shell('''
captcha_generation=new
printf 'old\nsubmit\nabcd\n' > "$captcha_dir/request"
sleep() { printf 'new\nsubmit\nAB12\n' > "$captcha_dir/request"; }
captcha_wait_manual MEA || exit 1
[ "$captcha_code" = AB12 ]
''')

    def test_failed_download_invalidates_old_challenge(self):
        self.run_shell('''
captcha_generation=old
printf old > "$captcha_dir/image"
printf old > "$captcha_dir/key"
_http_cmd=false
if swjsq_get_verify_code MEA; then exit 1; fi
[ -z "$captcha_generation" ] && [ ! -f "$captcha_dir/key" ] && [ ! -f "$captcha_dir/image" ]
''')

    def test_login_preserves_wget_network_exit_status(self):
        source = (ROOT/'files/root/usr/bin/xlnetacc.sh').read_text(encoding='utf-8')
        login = source[source.index('swjsq_login_once() {'):source.index('# 帐号注销')]
        self.run_shell(login + '''
swjsq_json() { :; }
json_add_string() { :; }
json_close_object() { :; }
json_dump() { printf '{}'; }
fake_wget() { return 4; }
_http_cmd=fake_wget
if swjsq_login_once; then exit 1; fi
[ "$lasterr" -eq -3 ]
''')

    def test_download_jpeg_without_od_or_hexdump(self):
        self.run_shell(r'''
od() { return 127; }
hexdump() { return 127; }
base64() { return 127; }
fake_wget() {
    local target
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -O ]; then shift; target=$1; fi
        shift
    done
    printf '\377\330\377\333\000\204\000\001' > "$target"
    printf 'HTTP/1.1 200 OK\nContent-Type: text/plain; charset=utf-8\nSet-Cookie: VERIFY_KEY=test-key; Path=/\n' >&2
}
_http_cmd=fake_wget
swjsq_get_verify_code MEA || exit 1
[ "$(cat "$captcha_dir/mime")" = image/jpeg ] && [ "$(cat "$captcha_dir/key")" = test-key ]
''')

    def test_download_png_ignores_incorrect_content_type(self):
        self.run_shell(r'''
od() { return 127; }
base64() { return 127; }
fake_wget() {
    local target
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -O ]; then shift; target=$1; fi
        shift
    done
    cp "$TEST_IMAGE" "$target"
    printf 'Content-Type: text/plain\nSet-Cookie: VERIFY_KEY=test-key; Path=/\n' >&2
}
_http_cmd=fake_wget
swjsq_get_verify_code MEA || exit 1
[ "$(cat "$captcha_dir/mime")" = image/png ]
''')

    def test_html_response_with_cookie_is_not_an_image(self):
        self.run_shell(r'''
fake_wget() {
    local target
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -O ]; then shift; target=$1; fi
        shift
    done
    printf '<html>error</html>' > "$target"
    printf 'Set-Cookie: VERIFY_KEY=test-key; Path=/\n' >&2
}
_http_cmd=fake_wget
if swjsq_get_verify_code MEA; then exit 1; fi
[ ! -f "$captcha_dir/image" ] && [ ! -f "$captcha_dir/key" ]
''')

if __name__ == '__main__': unittest.main()
