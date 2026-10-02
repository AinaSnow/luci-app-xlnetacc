#!/bin/sh
# OAuth authorization code + PKCE and the official web broadband API.
# Requires jshn.sh. One daemon owns credentials, refreshes and queued actions.
web_dir=/var/run/xlnetacc-web
web_private=/etc/xlnetacc-web
web_auth_origin=https://xluser-ssl.xunlei.com
web_speed_origin=https://speedup.xunlei.com
web_client=ZN3CT_2NLl6a5Q7n
web_access=; web_refresh_token=; web_sub=; web_expires=0
web_url=; web_user_code=; web_auth_deadline=0
web_basic=; web_target=; web_speed=0

web_prepare() {
	umask 077
	mkdir -p "$web_dir" "$web_private" || return 1
	chmod 700 "$web_dir" "$web_private" || return 1
	if [ ! -s "$web_private/device" ]; then
		openssl rand -hex 16 > "$web_private/device.tmp" || return 1
		mv -f "$web_private/device.tmp" "$web_private/device" || return 1
	fi
	web_device=$(cat "$web_private/device")
	case "$web_device" in ''|*[!a-f0-9]*) return 1;; esac
	[ "${#web_device}" -eq 32 ]
}

web_state() {
	local stage=$1 message=$2
	json_init
	json_add_string stage "$stage"
	json_add_string message "$message"
	json_add_boolean authenticated "$([ -s "$web_private/auth.json" ] && echo 1 || echo 0)"
	json_add_int login_expires_at "${web_expires:-0}"
	json_add_boolean can_refresh "$([ -n "$web_refresh_token" ] && echo 1 || echo 0)"
	json_add_boolean can_reauthorize "$([ -n "$web_access" ] && [ "${web_expires:-0}" -gt "$(date +%s)" ] && echo 1 || echo 0)"
	json_add_string authorization_url "$web_url"
	json_add_string user_code "$web_user_code"
	json_add_int expires_at "${web_auth_deadline:-0}"
	json_add_boolean is_speedup "${web_speed:-0}"
	json_add_string basic_rate_down "$web_basic"
	json_add_string target_rate_down "$web_target"
	json_add_int updated_at "$(date +%s)"
	json_dump > "$web_dir/status.tmp" && mv -f "$web_dir/status.tmp" "$web_dir/status.json"
}

web_load_auth() {
	web_access=; web_refresh_token=; web_sub=; web_expires=0
	[ -s "$web_private/auth.json" ] || return 1
	json_load "$(cat "$web_private/auth.json")" || return 1
	json_get_var web_access access_token
	json_get_var web_refresh_token refresh_token
	json_get_var web_sub sub
	json_get_var web_expires expires_at
	case "$web_sub" in ''|*[!0-9]*) return 1;; esac
	case "$web_expires" in ''|*[!0-9]*) return 1;; esac
	[ -n "$web_access" ]
}

web_save_auth() {
	local access refresh sub lifetime old_refresh=$web_refresh_token old_sub=$web_sub
	web_credential_error="响应不是有效 JSON"
	json_load "$web_response" || return 1
	json_get_var access access_token
	json_get_var refresh refresh_token
	json_get_var sub sub
	json_get_var lifetime expires_in
	# A refresh may omit unchanged fields; a new login cannot inherit them.
	if [ "$1" = refresh ]; then
		refresh=${refresh:-$old_refresh}; sub=${sub:-$old_sub}
		[ "$sub" = "$old_sub" ] || return 1
	fi
	web_credential_error="sub 缺失或格式不支持"
	case "$sub" in ''|*[!0-9]*) return 1;; esac
	[ "$1" = login ] || [ "$sub" = "$old_sub" ] || return 1
	web_credential_error="expires_in 缺失或格式不支持"
	case "$lifetime" in ''|*[!0-9]*) return 1;; esac
	[ "$lifetime" -ge 60 ] && [ "$lifetime" -le 31536000 ] || return 1
	web_credential_error="access_token 缺失"
	[ -n "$access" ] || return 1
	web_credential_error="token 格式不支持"
	# Tokens become headers: reject control characters rather than sanitizing them.
	case "$access$refresh" in *[![:graph:]]*) return 1;; esac
	web_credential_error="无法保存授权文件"
	web_access=$access; web_refresh_token=$refresh; web_sub=$sub
	web_expires=$(( $(date +%s) + lifetime ))
	json_init
	json_add_string access_token "$web_access"
	json_add_string refresh_token "$web_refresh_token"
	json_add_string sub "$web_sub"
	json_add_int expires_at "$web_expires"
	json_dump > "$web_private/auth.tmp" || return 1
	chmod 600 "$web_private/auth.tmp" && mv -f "$web_private/auth.tmp" "$web_private/auth.json"
}

web_forget() {
	rm -f "$web_private/auth.json" "$web_private/auth.tmp"
	web_access=; web_refresh_token=; web_sub=; web_expires=0
	web_url=; web_user_code=; web_auth_deadline=0
	web_speed=0; web_basic=; web_target=
	web_state auth_required '请点击官方网页登录授权'
}

# No credentials in argv, status JSON or logs. Never redirect authenticated calls.
web_http_request() {
	local origin=$1 path=$2 method=$3 auth=$4 tmp ret
	web_response=; web_http=000; web_error=
	tmp=$(mktemp -d "$web_dir/http.XXXXXX") || return 1
	{
		printf 'Content-Type: application/json\nx-device-id: %s\n' "$web_device"
		if [ "$origin" = "$web_auth_origin" ]; then
			printf 'x-client-id: %s\nx-sdk-version: 7.0.8\nx-protocol-version: 301\n' "$web_client"
		else
			printf 'Platform: pc_kn\nChannel: 100001\n'
		fi
		[ "$auth" = token ] && printf 'Authorization: %s\n' "$web_access"
	} > "$tmp/headers"
	if [ "$method" = POST ]; then json_dump > "$tmp/body"; fi
	set -- -q -sS --ipv4 --noproxy '*' --connect-timeout 8 --max-time 30 \
		--proto '=https' --max-filesize 1048576 --header "@$tmp/headers" \
		--output "$tmp/response" --write-out '%{http_code}'
	[ -n "$web_bind_ip" ] && set -- "$@" --interface "$web_bind_ip"
	[ "$method" = POST ] && set -- "$@" --data-binary "@$tmp/body"
	web_http=$(curl "$@" "$origin/$path" 2> "$tmp/error")
	ret=$?
	[ -f "$tmp/response" ] && web_response=$(cat "$tmp/response")
	rm -rf "$tmp"
	if [ "$ret" -ne 0 ]; then web_error="网络请求失败（curl $ret，HTTP ${web_http:-000}）"; return 1; fi
	case "$web_http" in 2??|4??) return 0;; esac
	web_error="服务暂不可用（HTTP ${web_http:-000}）"
	return 1
}

# The official authorize endpoint accepts the current Bearer credential. This
# obtains another code for the SAME client/scopes, with fresh PKCE, while valid.
# It cannot recover an already expired credential and never uses browser cookies.
web_reauthorize() {
	local saved_access=$web_access saved_sub=$web_sub verifier challenge state code returned
	local result candidate candidate_sub candidate_response error
	verifier=$(openssl rand -hex 32) || return 1
	state=$(openssl rand -hex 32) || return 1
	challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
	[ "${#verifier}" -eq 64 ] && [ "${#state}" -eq 64 ] && [ "${#challenge}" -eq 43 ] || return 1
	json_init
	json_add_string client_id "$web_client"
	json_add_string response_type code
	json_add_string redirect_uri 'https://vip.xunlei.com/pages/2023/broadband-speed/m/'
	json_add_string scope 'profile user sso'
	json_add_string state "$state"
	json_add_string code_challenge "$challenge"
	json_add_string code_challenge_method S256
	web_access="Bearer $saved_access"
	web_http_request "$web_auth_origin" v1/user/authorize POST token
	result=$?
	web_access=$saved_access
	if [ "$result" -ne 0 ]; then web_state network_error "$web_error"; return 1; fi
	if [ "$web_http" = 401 ]; then
		web_forget; web_state auth_required '登录凭据已被拒绝，请重新网页登录'; return 1
	fi
	if [ "$web_http" != 200 ]; then
		web_state auth_error "自动续登暂未成功（授权 HTTP $web_http），保留原凭据，稍后重试"; return 1
	fi
	if ! json_load "$web_response"; then
		web_state auth_error '自动续登响应无效，保留原凭据，稍后重试'; return 1
	fi
	json_get_var code code
	json_get_var returned state
	if [ "$returned" != "$state" ] || [ -z "$code" ] || [ "${#code}" -gt 4096 ]; then
		web_state auth_error '自动续登响应不匹配，保留原凭据'; return 1
	fi
	case "$code" in *[![:graph:]]*) web_state auth_error '自动续登授权码格式无效，保留原凭据'; return 1;; esac
	json_init
	json_add_string client_id "$web_client"
	json_add_string grant_type authorization_code
	json_add_string code "$code"
	json_add_string code_verifier "$verifier"
	json_add_string redirect_uri 'https://vip.xunlei.com/pages/2023/broadband-speed/m/'
	web_http_request "$web_auth_origin" v1/auth/token POST none || {
		web_state network_error "$web_error"; return 1
	}
	if [ "$web_http" != 200 ]; then
		web_state auth_error "自动续登暂未成功（换取凭据 HTTP $web_http），保留原凭据，稍后重试"; return 1
	fi
	candidate_response=$web_response
	json_load "$candidate_response" >/dev/null 2>&1 || return 1
	json_get_var candidate access_token
	json_get_var candidate_sub sub
	if [ "$candidate_sub" != "$saved_sub" ] || [ -z "$candidate" ]; then
		web_state auth_error '自动续登账号不匹配或缺少凭据，保留原凭据'; return 1
	fi
	case "$candidate" in *[![:graph:]]*) web_state auth_error '自动续登凭据格式无效，保留原凭据'; return 1;; esac
	# Check the new credential before atomically replacing the working one.
	web_access="Bearer $candidate"
	web_http_request "$web_auth_origin" v1/user/me GET token
	result=$?
	web_access=$saved_access
	if [ "$result" -ne 0 ]; then web_state network_error "$web_error"; return 1; fi
	candidate_sub=
	if [ "$web_http" = 200 ] && json_load "$web_response"; then json_get_var candidate_sub sub; fi
	if [ "$candidate_sub" != "$saved_sub" ]; then
		web_state auth_error '新凭据尚未通过账号验证，保留原凭据，稍后重试'; return 1
	fi
	web_response=$candidate_response
	if web_save_auth reauthorize; then return 0; fi
	web_load_auth >/dev/null 2>&1
	web_state auth_error '无法保存自动续登凭据，保留原授权，稍后重试'
	return 1
}

web_refresh_auth() {
	local force=${1:-0} error margin=60 now
	web_load_auth || { web_state auth_required '请先完成官方网页登录授权'; return 1; }
	now=$(date +%s)
	# The daemon checks every five minutes: a 15-minute window permits retries.
	[ -n "$web_refresh_token" ] || margin=900
	[ "$force" -eq 0 ] && [ "$web_expires" -gt $(( now + margin )) ] && return 0
	if [ -z "$web_refresh_token" ]; then
		if [ "$web_expires" -gt "$now" ]; then web_reauthorize; return $?; fi
		web_forget; web_state auth_required '登录已过期，未能在到期前续登，请重新网页登录'; return 1
	fi
	json_init
	json_add_string client_id "$web_client"
	json_add_string grant_type refresh_token
	json_add_string refresh_token "$web_refresh_token"
	web_http_request "$web_auth_origin" v1/auth/token POST none || {
		web_state network_error "$web_error"; return 1
	}
	if [ "$web_http" = 200 ] && web_save_auth refresh; then return 0; fi
	json_load "$web_response" >/dev/null 2>&1 && json_get_var error error
	case "$error" in invalid_grant|unauthenticated|unauthorized_client|invalid_token)
		web_forget; web_state auth_required '授权已失效，请重新登录';;
		*) web_state auth_error "刷新授权失败（HTTP $web_http），稍后重试";;
	esac
	return 1
}

web_take_action() {
	web_action=; web_redirect=
	if mv "$web_dir/request" "$web_dir/request.active" 2>/dev/null; then
		{ IFS= read -r web_action; IFS= read -r web_redirect; } < "$web_dir/request.active"
		rm -f "$web_dir/request.active"
	fi
}

web_authorize() {
	local redirect=https://vip.xunlei.com/pages/2023/broadband-speed/m/ state verifier challenge encoded deadline returned code reason=
	state=$(openssl rand -hex 32) && verifier=$(openssl rand -hex 32) || return 1
	challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
	[ "${#challenge}" -eq 43 ] || return 1
	encoded=$(printf '%s' "$redirect" | sed 's/:/%3A/g;s|/|%2F|g')
	deadline=$(( $(date +%s) + 600 ))
	rm -f "$web_dir/oauth.callback"
	printf '%s\n%s\n' "$state" "$deadline" > "$web_dir/oauth.pending.tmp" && mv -f "$web_dir/oauth.pending.tmp" "$web_dir/oauth.pending" || return 1
	web_url="https://i.xunlei.com/center/account/personal/oauth/?client_id=$web_client&response_type=code&scope=profile%20user%20sso&state=$state&redirect_uri=$encoded&code_challenge=$challenge&code_challenge_method=S256"
	web_user_code=; web_auth_deadline=$deadline
	web_state authorizing '打开官方登录页面，完成后把返回地址粘贴到此处（10 分钟内有效）'
	while [ "$(date +%s)" -lt "$deadline" ]; do
		sleep 2
		web_take_action
		case "$web_action" in cancel|forget)
			rm -f "$web_dir/oauth.pending" "$web_dir/oauth.callback"
			web_url=; web_user_code=; web_auth_deadline=0
			[ "$web_action" = forget ] && web_forget || web_state idle '已取消授权'
			return 1;;
		esac
		[ -s "$web_dir/oauth.callback" ] || continue
		{ IFS= read -r returned; IFS= read -r code; } < "$web_dir/oauth.callback"
		rm -f "$web_dir/oauth.callback"
		[ "$returned" = "$state" ] || continue
		rm -f "$web_dir/oauth.pending"
		[ -n "$code" ] || break
		json_init
		json_add_string client_id "$web_client"
		json_add_string grant_type authorization_code
		json_add_string code "$code"
		json_add_string code_verifier "$verifier"
		json_add_string redirect_uri "$redirect"
		web_http_request "$web_auth_origin" v1/auth/token POST none || { reason=$web_error; break; }
		if [ "$web_http" = 200 ] && web_save_auth login; then
			web_url=; web_user_code=; web_auth_deadline=0
			web_state idle '授权成功，正在检查宽带状态'
			return 0
		fi
		if [ "$web_http" = 200 ]; then
			reason="HTTP 200，$web_credential_error"
			break
		fi
		json_load "$web_response" >/dev/null 2>&1 && json_get_var reason error
		case "$reason" in ''|*[!a-zA-Z0-9_-]*) reason="HTTP $web_http";; *) reason="HTTP $web_http，$reason";; esac
		break
	done
	rm -f "$web_dir/oauth.pending" "$web_dir/oauth.callback"
	web_url=; web_user_code=; web_auth_deadline=0
	web_state auth_error "授权未完成、已过期或被拒绝${reason:+（$reason）}，请重新获取登录链接"
	return 1
}

web_api() {
	local path=$1 method=${2:-GET} attempt=0 ret=
	web_refresh_auth || return 1
	while [ "$attempt" -lt 2 ]; do
		json_init
		[ "$method" = POST ] && json_add_string user_id "$web_sub"
		[ "$path" = v1/open ] && json_add_string exp_ver ""
		web_http_request "$web_speed_origin" "$path?user_id=$web_sub" "$method" token || {
			web_state network_error "$web_error"; return 1
		}
		if [ "$web_http" = 401 ] && [ "$attempt" -eq 0 ]; then
			web_refresh_auth 1 || return 1
			attempt=1; continue
		fi
		if [ "$web_http" != 200 ]; then
			web_state api_error "提速服务请求失败（HTTP $web_http）"; return 1
		fi
		json_load "$web_response" && json_get_var ret ret
		if [ "$ret" != 0 ]; then
			case "$ret" in ''|*[!0-9-]*) ret=unknown;; esac
			web_state api_error "提速服务拒绝请求（code $ret）"; return 1
		fi
		return 0
	done
	return 1
}

# Read both the line status and this account's binding before any open request.
web_check() {
	local owner bound current vip equal
	web_can_open=0; web_speed=0; web_basic=; web_target=
	web_api v2/check_status || return 1
	json_select data || { web_state api_error '状态响应缺少数据'; return 1; }
	json_get_var web_speed is_speedup
	json_get_var owner user_id
	case "$web_speed" in 1|true) web_speed=1;; *) web_speed=0;; esac
	if json_select speed_data >/dev/null 2>&1; then
		json_get_var web_basic basic_rate_down
		json_get_var web_target target_rate_down
	fi
	web_api v1/user_query || return 1
	json_select data || { web_state api_error '账号响应缺少数据'; return 1; }
	json_get_var bound bound_lan
	json_get_var current current_lan
	json_get_var vip is_vip
	json_get_var equal is_current_lan_equal_to_bound_lan
	case "$equal" in 1|true) current=$bound;; esac
	if [ -n "$owner" ] && [ "$owner" != "$web_sub" ]; then
		web_state binding_required '当前宽带属于其他账号，请在官方页面核对绑定'; return 0
	fi
	if [ -z "$bound" ] || [ -z "$current" ] || [ "$bound" != "$current" ]; then
		web_state binding_required '请在官方页面确认当前宽带与账号绑定，插件不会自动换绑'; return 0
	fi
	case "$vip" in 1|true) ;; *) web_state unavailable '账号未返回有效快鸟权益，请在官方页面确认'; return 0;; esac
	web_can_open=1
	if [ "$web_speed" -eq 1 ]; then
		web_state active '服务器确认当前宽带已开启提速；实际速率以测速为准'
	else
		web_state paused '当前宽带尚未开启提速'
	fi
	return 0
}

web_open() {
	local attempt=0
	web_check || return 1
	[ "$web_can_open" -eq 1 ] || return 1
	[ "$web_speed" -eq 1 ] && return 0
	web_state opening '正在申请开启提速'
	web_api v1/open POST || return 1
	# A successful mutation response alone does not establish active service.
	while [ "$attempt" -lt 10 ]; do
		sleep 3
		web_check || return 1
		[ "$web_can_open" -eq 1 ] || return 1
		[ "$web_speed" -eq 1 ] && return 0
		attempt=$((attempt + 1))
	done
	web_state pending '请求已受理，但尚未确认提速，稍后检查状态'
	return 1
}

web_close() {
	# Pause survives restarts, so the next monitoring pass cannot reopen it.
	: > "$web_private/paused"
	web_check || return 1
	[ "$web_can_open" -eq 1 ] || return 1
	web_api v1/close POST || return 1
	web_check
}

web_network() {
	local network
	network=$(uci -q get xlnetacc.general.network)
	case "$network" in ''|*[!a-zA-Z0-9_-]*) web_state network_error '请选择有效的提速接口'; return 1;; esac
	web_bind_ip=
	json_load "$(ubus call "network.interface.$network" status 2>/dev/null)" &&
		json_select ipv4-address && json_select 1 && json_get_var web_bind_ip address
	case "$web_bind_ip" in ''|*[!0-9.]*) web_state network_error '提速接口没有可用 IPv4 地址'; return 1;; esac
	return 0
}
