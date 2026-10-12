"""Test the production web protocol/state machine with deterministic API fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_captcha import BASH, ROOT, JSON_SHIM, shell_path


class WebTests(unittest.TestCase):
    def run_shell(self, code):
        with tempfile.TemporaryDirectory(prefix='.captcha-test-', dir=ROOT) as directory:
            env = os.environ.copy()
            env.update(TEST_TMP=shell_path(directory), LIB=shell_path(ROOT/'files/root/usr/lib/xlnetacc/web.sh'),
                       JSON_HELPER=shell_path(ROOT/'tests/json_helper.py'), JSON_STATE=str(Path(directory)/'jshn.json'))
            env['PATH'] = str(Path(os.sys.executable).parent) + os.pathsep + env['PATH']
            prefix = JSON_SHIM + r'''
. "$LIB"
web_dir="$TEST_TMP/runtime"; web_private="$TEST_TMP/private"
web_prepare || exit 90
sleep() { :; }
fixture_auth() {
    web_response='{"access_token":"access-secret","refresh_token":"refresh-secret","sub":"123","expires_in":3600}'
    web_save_auth login || exit 91
}
fixture_status() {
    web_response='{"ret":0,"data":{"is_speedup":false,"user_id":"123","speed_data":{"basic_rate_down":100,"target_rate_down":500}}}'
}
fixture_binding() {
    web_response='{"ret":0,"data":{"bound_lan":"line-a","current_lan":"line-a","is_vip":true}}'
}
assert_stage() {
    json_load "$(cat "$web_dir/status.json")"
    json_get_var actual stage
    [ "$actual" = "$1" ] || { echo "expected $1, got $actual"; exit 92; }
}
'''
            result = subprocess.run([BASH, '-c', prefix + code], env=env, capture_output=True,
                                    text=True, encoding='utf-8', timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, '')

    def test_device_persists_and_status_never_contains_tokens(self):
        self.run_shell(r'''
original=$web_device
web_prepare || exit 1
[ "$web_device" = "$original" ] || exit 2
fixture_auth
web_state active test
if grep -E 'access-secret|refresh-secret' "$web_dir/status.json"; then exit 3; fi
web_load_auth && [ "$web_sub" = 123 ]
''')

    def test_pkce_authorization_exchanges_code_and_clears_pending(self):
        self.run_shell(r'''
sleep() {
    IFS= read -r expected < "$web_dir/oauth.pending"
    printf '%s\ntest-code\n' "$expected" > "$web_dir/oauth.callback"
}
web_http_request() {
    [ "$2" = v1/auth/token ] || exit 10
    json_get_var grant grant_type; [ "$grant" = authorization_code ] || exit 11
    json_get_var redirect redirect_uri
    [ "$redirect" = https://vip.xunlei.com/pages/2023/broadband-speed/m/ ] || exit 12
    json_get_var verifier code_verifier; [ "${#verifier}" -eq 64 ] || exit 13
    derived=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    case "$web_url" in *"code_challenge=$derived&code_challenge_method=S256") ;; *) exit 14;; esac
    json_get_var code code; [ "$code" = test-code ] || exit 15
    web_http=200
    web_response='{"access_token":"access-secret","refresh_token":"refresh-secret","sub":"123","expires_in":3600}'
}
web_authorize || exit 1
[ -z "$web_url" ] && web_load_auth || exit 2
[ ! -f "$web_dir/oauth.pending" ] && [ ! -f "$web_dir/oauth.callback" ] || exit 3
assert_stage idle
''')

    def test_wrong_state_is_ignored_and_cancel_cleans_up(self):
        self.run_shell(r'''
turn=0
sleep() {
    turn=$((turn+1))
    if [ "$turn" -eq 1 ]; then printf 'wrong-state\ncode\n' > "$web_dir/oauth.callback"
    else printf 'cancel\n' > "$web_dir/request"; fi
}
web_http_request() { exit 10; }
if web_authorize; then exit 1; fi
[ "$turn" -eq 2 ] || exit 2
assert_stage idle
[ ! -f "$web_private/auth.json" ] && [ ! -f "$web_dir/oauth.pending" ] && [ -z "$web_url" ]
''')

    def test_access_only_login_cannot_reauthorize_after_expiry(self):
        self.run_shell(r'''
web_response='{"access_token":"access-only","sub":"123","expires_in":3600}'
web_save_auth login || exit 1
web_load_auth || exit 2
web_http_request() { exit 10; }
web_refresh_auth || exit 3
[ -z "$web_refresh_token" ] || exit 4
web_state idle test
json_load "$(cat "$web_dir/status.json")"; json_get_var flag can_refresh
[ "$flag" = 0 ] || exit 5
json_get_var flag can_reauthorize; [ "$flag" = 1 ] || exit 8
expired=$((web_expires+1))
date() { printf '%s\n' "$expired"; }
if web_refresh_auth 1; then exit 6; fi
assert_stage auth_required
[ ! -f "$web_private/auth.json" ] || exit 7
''')

    def test_access_only_renews_early_using_same_client_pkce_and_verified_account(self):
        self.run_shell(r'''
web_response='{"access_token":"original-secret","sub":"123","expires_in":600}'
web_save_auth login || exit 1
calls=0
web_http_request() {
    calls=$((calls+1)); web_http=200
    case "$2" in
        v1/user/authorize)
            [ "$web_access" = 'Bearer original-secret' ] || exit 10
            [ "$3" = POST ] && [ "$4" = token ] || exit 11
            json_get_var client client_id; [ "$client" = "$web_client" ] || exit 12
            json_get_var scope scope; [ "$scope" = 'profile user sso' ] || exit 13
            json_get_var sent_state state; [ "${#sent_state}" -eq 64 ] || exit 14
            json_get_var sent_challenge code_challenge
            json_get_var method code_challenge_method; [ "$method" = S256 ] || exit 15
            json_get_var redirect redirect_uri
            [ "$redirect" = https://vip.xunlei.com/pages/2023/broadband-speed/m/ ] || exit 16
            web_response="{\"code\":\"one-time\",\"state\":\"$sent_state\"}";;
        v1/auth/token)
            [ "$4" = none ] || exit 17
            json_get_var verifier code_verifier
            derived=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
            [ "$derived" = "$sent_challenge" ] || exit 18
            json_get_var grant grant_type; [ "$grant" = authorization_code ] || exit 19
            web_response='{"access_token":"new-secret","sub":"123","expires_in":7200}' ;;
        v1/user/me)
            [ "$web_access" = 'Bearer new-secret' ] || exit 20
            # The original credential must still be on disk until verified.
            grep -q original-secret "$web_private/auth.json" || exit 21
            web_response='{"sub":"123"}';;
        *) exit 22;;
    esac
}
web_refresh_auth || exit 2
[ "$calls" -eq 3 ] || exit 3
web_load_auth || exit 4
[ "$web_access" = new-secret ] && [ -z "$web_refresh_token" ] || exit 5
[ "$web_expires" -gt $(( $(date +%s) + 7000 )) ] || exit 6
web_state active renewed
if grep -E 'original-secret|new-secret|one-time' "$web_dir/status.json"; then exit 7; fi
''')

    def test_reauthorize_network_and_wrong_state_preserve_current_credential(self):
        self.run_shell(r'''
web_response='{"access_token":"original-secret","sub":"123","expires_in":600}'
web_save_auth login || exit 1
cp "$web_private/auth.json" "$TEST_TMP/original"
web_http_request() { web_error=offline; return 1; }
if web_refresh_auth; then exit 2; fi
cmp "$web_private/auth.json" "$TEST_TMP/original" || exit 3
[ "$web_access" = original-secret ] || exit 4
assert_stage network_error
web_http_request() {
    [ "$2" = v1/user/authorize ] || exit 10
    web_http=200; web_response='{"code":"unused","state":"wrong-state"}'
}
if web_refresh_auth; then exit 5; fi
cmp "$web_private/auth.json" "$TEST_TMP/original" || exit 6
assert_stage auth_error
''')

    def test_reauthorize_rejects_wrong_account_before_replacing_credentials(self):
        for failure in ('token_subject', 'profile_subject', 'profile_http', 'exchange_http'):
            with self.subTest(failure=failure):
                self.run_shell('failure=' + failure + '\n' + r'''
web_response='{"access_token":"original-secret","sub":"123","expires_in":600}'
web_save_auth login || exit 1
cp "$web_private/auth.json" "$TEST_TMP/original"
web_http_request() {
    web_http=200
    case "$2" in
        v1/user/authorize)
            json_get_var sent_state state
            web_response="{\"code\":\"one-time\",\"state\":\"$sent_state\"}";;
        v1/auth/token)
            web_response='{"access_token":"candidate-secret","sub":"123","expires_in":7200}'
            [ "$failure" != token_subject ] || web_response='{"access_token":"candidate-secret","sub":"999","expires_in":7200}'
            [ "$failure" != exchange_http ] || web_http=400;;
        v1/user/me)
            web_response='{"sub":"999"}'
            [ "$failure" != profile_http ] || web_http=401;;
        *) exit 10;;
    esac
    return 0
}
if web_refresh_auth; then exit 2; fi
cmp "$web_private/auth.json" "$TEST_TMP/original" || exit 3
[ "$web_access" = original-secret ] || exit 4
assert_stage auth_error
''')

    def test_reauthorize_rejected_old_credential_requires_login(self):
        self.run_shell(r'''
web_response='{"access_token":"original-secret","sub":"123","expires_in":600}'
web_save_auth login || exit 1
web_http_request() { web_http=401; web_response='{"error":"unauthenticated"}'; }
if web_refresh_auth; then exit 2; fi
assert_stage auth_required
[ ! -f "$web_private/auth.json" ]
''')

    def test_refresh_rotation_preserves_subject_and_omitted_refresh(self):
        self.run_shell(r'''
fixture_auth
web_http_request() { web_http=200; web_response='{"access_token":"rotated","expires_in":3600}'; }
web_refresh_auth 1 || exit 1
web_load_auth || exit 2
[ "$web_access" = rotated ] && [ "$web_refresh_token" = refresh-secret ] && [ "$web_sub" = 123 ]
''')

    def test_refresh_network_failure_keeps_auth_invalid_grant_forgets(self):
        self.run_shell(r'''
fixture_auth
web_http_request() { web_error=offline; return 1; }
if web_refresh_auth 1; then exit 1; fi
[ -f "$web_private/auth.json" ] || exit 2
assert_stage network_error
web_http_request() { web_http=400; web_response='{"error":"invalid_grant"}'; }
if web_refresh_auth 1; then exit 3; fi
[ ! -f "$web_private/auth.json" ] || exit 4
assert_stage auth_required
''')

    def test_open_waits_for_confirmed_status(self):
        self.run_shell(r'''
fixture_auth
opens=0; checks=0
web_http_request() {
    web_http=200
    case "$2" in
        v2/check_status*)
            checks=$((checks+1)); fixture_status
            if [ "$checks" -ge 3 ]; then web_response='{"ret":0,"data":{"is_speedup":true,"user_id":"123"}}'; fi;;
        v1/user_query*) fixture_binding;;
        v1/open*) [ "$3" = POST ] || exit 10; opens=$((opens+1)); web_response='{"ret":0}';;
        *) exit 11;;
    esac
}
web_open || exit 1
[ "$opens" -eq 1 ] && [ "$checks" -eq 3 ] || exit 2
assert_stage active
''')

    def test_wrong_binding_never_opens_or_changes_binding(self):
        self.run_shell(r'''
fixture_auth
web_http_request() {
    web_http=200
    case "$2" in
        v2/check_status*) fixture_status;;
        v1/user_query*) web_response='{"ret":0,"data":{"bound_lan":"other-line","current_lan":"line-a","is_vip":true}}';;
        *) exit 10;;
    esac
}
if web_open; then exit 1; fi
assert_stage binding_required
''')

    def test_official_equal_line_flag_is_respected_without_changing_binding(self):
        self.run_shell(r'''
fixture_auth
web_http_request() {
    web_http=200
    case "$2" in
        v2/check_status*) fixture_status;;
        v1/user_query*) web_response='{"ret":0,"data":{"bound_lan":"line-a","current_lan":"alias-a","is_current_lan_equal_to_bound_lan":true,"is_vip":true}}';;
        *) exit 10;;
    esac
}
web_check || exit 1
[ "$web_can_open" -eq 1 ] || exit 2
assert_stage paused
''')

    def test_812_is_not_success_on_new_api(self):
        self.run_shell(r'''
fixture_auth
web_http_request() { web_http=200; web_response='{"ret":812,"msg":"already speed up"}'; }
if web_api v1/open POST; then exit 1; fi
assert_stage api_error
''')

    def test_401_refreshes_once_and_retries(self):
        self.run_shell(r'''
fixture_auth
api_calls=0; refreshes=0
web_http_request() {
    if [ "$2" = v1/auth/token ]; then
        refreshes=$((refreshes+1)); web_http=200; web_response='{"access_token":"rotated","expires_in":3600}'
    else
        api_calls=$((api_calls+1)); web_http=401; web_response='{}'
        if [ "$api_calls" -eq 2 ]; then web_http=200; web_response='{"ret":0}'; fi
    fi
}
web_api v1/user_query || exit 1
[ "$api_calls" -eq 2 ] && [ "$refreshes" -eq 1 ]
''')

    def test_transport_keeps_credentials_out_of_argv(self):
        self.run_shell(r'''
fixture_auth
curl() {
    local output headers arg
    for arg in "$@"; do case "$arg" in *access-secret*|*refresh-secret*) exit 10;; esac; done
    while [ "$#" -gt 0 ]; do
        case "$1" in --output) shift; output=$1;; --header) shift; headers=${1#@};; esac
        shift
    done
    grep -q '^Authorization: access-secret$' "$headers" || exit 11
    grep -q '^Platform: pc_kn$' "$headers" || exit 12
    printf '{"ret":0}' > "$output"; printf 200
}
web_api v1/user_query || exit 1
test -z "$(find "$web_dir" -name 'http.*' -print)"
''')

    def test_pausing_is_persistent(self):
        self.run_shell(r'''
fixture_auth
web_http_request() {
    web_http=200
    case "$2" in
        v2/check_status*) fixture_status;;
        v1/user_query*) fixture_binding;;
        v1/close*) web_response='{"ret":0}';;
        *) exit 10;;
    esac
}
web_close || exit 1
[ -f "$web_private/paused" ] || exit 2
assert_stage paused
''')

if __name__ == '__main__': unittest.main()
