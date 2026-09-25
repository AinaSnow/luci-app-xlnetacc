#!/bin/sh
# Shared by the daemon and the standalone API check. Requires jshn.sh.
captcha_dir=/var/run/xlnetacc
captcha_generation=
captcha_code=
captcha_key=

ai_load_config() {
	chatgpt_base_url=$(uci -q get xlnetacc.general.base_url)
	chatgpt_api_key=$(uci -q get xlnetacc.general.api_key)
	chatgpt_model=$(uci -q get xlnetacc.general.model)
	ai_timeout=$(uci -q get xlnetacc.general.ai_timeout)
	ai_max_tokens=$(uci -q get xlnetacc.general.ai_max_tokens)
	captcha_length=$(uci -q get xlnetacc.general.captcha_length)
	case "$ai_timeout" in ''|*[!0-9]*) ai_timeout=90;; esac
	[ "$ai_timeout" -ge 15 ] && [ "$ai_timeout" -le 180 ] || ai_timeout=90
	case "$ai_max_tokens" in ''|*[!0-9]*) ai_max_tokens=1024;; esac
	[ "$ai_max_tokens" -ge 64 ] && [ "$ai_max_tokens" -le 8192 ] || ai_max_tokens=1024
	case "$captcha_length" in ''|*[!0-9]*) captcha_length=0;; esac
	[ "$captcha_length" -le 8 ] || captcha_length=0
}

captcha_prepare() {
	umask 077
	mkdir -p "$captcha_dir" && chmod 700 "$captcha_dir"
}

# State is an atomic two-line snapshot. The public generation is not VERIFY_KEY.
captcha_set_state() {
	printf '%s\n%s\n' "$1" "$captcha_generation" > "$captcha_dir/state.tmp"
	mv -f "$captcha_dir/state.tmp" "$captcha_dir/state"
}

captcha_clear() {
	captcha_generation=; captcha_code=; captcha_key=
	captcha_set_state "${1:-idle}"
	rm -f "$captcha_dir/image" "$captcha_dir/mime" "$captcha_dir/key" "$captcha_dir/request" \
		"$captcha_dir/request.ready"
}

# Do not strip explanations into a plausible answer. Only trim outside whitespace.
captcha_validate() {
	local code=$1
	case "$code" in ''|*[!a-zA-Z0-9]*) return 1;; esac
	[ "${#code}" -ge 4 ] && [ "${#code}" -le 8 ] || return 1
	[ "${captcha_length:-0}" -eq 0 ] || [ "${#code}" -eq "$captcha_length" ]
}

ai_request() {
	local image=$1 prompt=$2 mime=${3:-image/jpeg}
	local endpoint=$chatgpt_base_url tmp metrics ret http elapsed detail cr
	ai_content=; ai_diagnostic=; ai_retryable=0
	if [ -z "$chatgpt_api_key" ] || [ -z "$chatgpt_model" ] || [ -z "$endpoint" ]; then
		ai_diagnostic='请配置 Base URL、API Key 和支持图片的模型'; return 2
	fi
	# Reject line breaks before creating the authorization header file.
	cr=$(printf '\r')
	case "$chatgpt_api_key" in *'
'*|*"$cr"*) ai_diagnostic='API Key 格式错误'; return 2;; esac
	while [ "${endpoint%/}" != "$endpoint" ]; do endpoint=${endpoint%/}; done
	case "$endpoint" in http://*|https://*) ;; *) ai_diagnostic='Base URL 必须使用 http 或 https'; return 2;; esac
	case "$endpoint" in */chat/completions) ;; *) endpoint="$endpoint/chat/completions";; esac
	[ -s "$image" ] || { ai_diagnostic='图片不存在或为空'; return 2; }
	command -v curl >/dev/null || { ai_diagnostic='缺少 curl，请重新安装插件依赖'; return 2; }
	tmp=$(mktemp -d "$captcha_dir/ai.XXXXXX") || return 2
	local encoded
	encoded=$(base64 "$image" | tr -d '\r\n')
	json_init
	json_add_string model "$chatgpt_model"
	json_add_boolean stream 0
	json_add_int max_tokens "$ai_max_tokens"
	json_add_array messages
	json_add_object ''
	json_add_string role user
	json_add_array content
	json_add_object ''
	json_add_string type text
	json_add_string text "$prompt"
	json_close_object
	json_add_object ''
	json_add_string type image_url
	json_add_object image_url
	json_add_string url "data:$mime;base64,$encoded"
	json_close_object
	json_close_object
	json_close_array
	json_close_object
	json_close_array
	json_dump > "$tmp/payload"
	printf 'Content-Type: application/json\nAuthorization: Bearer %s\n' "$chatgpt_api_key" > "$tmp/headers"
	# No WAN bind, redirects, curlrc, implicit retries or disabled TLS verification.
	# Secrets stay out of argv and diagnostics; the private directory is removed below.
	metrics=$(curl -q -sS --connect-timeout 5 --max-time "$ai_timeout" \
		--proto '=http,https' --max-filesize 1048576 \
		--header "@$tmp/headers" --data-binary "@$tmp/payload" \
		--output "$tmp/body" --write-out '%{http_code} %{time_total}' \
		"$endpoint" 2> "$tmp/stderr")
	ret=$?
	http=${metrics%% *}; elapsed=${metrics#* }
	detail="HTTP ${http:-000}，curl $ret，耗时 ${elapsed:-0} 秒"
	if [ "$ret" -ne 0 ]; then
		case "$ret" in
			28) ai_diagnostic="等待响应超时（$detail）"; ai_retryable=1;;
			5|6|7|18|52|55|56) ai_diagnostic="网络通信失败（$detail）"; ai_retryable=1;;
			*) ai_diagnostic="请求失败，请检查 TLS 或客户端配置（$detail）";;
		esac
	elif [ "$http" != 200 ]; then
		case "$http" in
			401|403) ai_diagnostic="鉴权失败，请检查 API Key 和模型权限（$detail）";;
			400|404|422) ai_diagnostic="请检查接口路径、模型名和图片支持（$detail）";;
			429) ai_diagnostic="服务限流或额度不足，请稍后重试（$detail）";;
			408|499|500|502|503|504) ai_diagnostic="服务暂时不可用（$detail）"; ai_retryable=1;;
			*) ai_diagnostic="接口返回异常状态（$detail）";;
		esac
	else
		if json_load "$(cat "$tmp/body")" >/dev/null 2>&1 &&
			json_select choices >/dev/null 2>&1 && json_select 1 >/dev/null 2>&1 &&
			json_select message >/dev/null 2>&1; then
			local content_type
			json_get_type content_type content
			[ "$content_type" = string ] && json_get_var ai_content content
		fi
		ai_content=$(printf '%s' "$ai_content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		if [ -n "$ai_content" ]; then
			ai_diagnostic="服务响应成功（$detail）"
			rm -rf "$tmp"
			return 0
		fi
		ai_diagnostic="响应没有有效文本，请检查模型和输出额度（$detail）"
	fi
	# Raw errors may echo credentials or image data. Only report categorized errors.
	rm -rf "$tmp"
	return 1
}

swjsq_get_verify_code() {
	local verify_type=${1:-MEA} tmp key mime
	case "$verify_type" in *[!a-zA-Z0-9_-]*) verify_type=MEA;; esac
	captcha_clear downloading
	tmp=$(mktemp -d "$captcha_dir/image.XXXXXX") || return 1
	if ! $_http_cmd -S -O "$tmp/image" "http://verify2.xunlei.com/image?t=$verify_type" \
		>/dev/null 2> "$tmp/headers"; then
		rm -rf "$tmp"; captcha_set_state download_error
		_log '下载验证码失败'; return 1
	fi
	key=$(sed -n 's/.*VERIFY_KEY=\([^;[:space:]]*\).*/\1/p' "$tmp/headers" | tail -n 1)
	case "$key" in ''|*[!a-zA-Z0-9_-]*) key=;; esac
	mime=$(od -An -tx1 -N8 "$tmp/image" | tr -d ' \n')
	case "$mime" in
		ffd8ff*) mime=image/jpeg;;
		89504e470d0a1a0a) mime=image/png;;
		474946383761*|474946383961*) mime=image/gif;;
		*) mime=;;
	esac
	if [ -z "$key" ] || [ -z "$mime" ] || [ "$(wc -c < "$tmp/image")" -gt 1048576 ]; then
		rm -rf "$tmp"; captcha_set_state download_error
		_log '验证码响应缺少有效图片或 KEY'; return 1
	fi
	printf '%s' "$key" > "$tmp/key"
	mv -f "$tmp/image" "$captcha_dir/image"
	mv -f "$tmp/key" "$captcha_dir/key"
	printf '%s' "$mime" > "$captcha_dir/mime"
	captcha_generation=${tmp##*/}
	rm -rf "$tmp"
	captcha_set_state ready
	_log '已获取新的验证码'
}

# At most one transport retry, with the same image/key pair.
swjsq_ai_recognize() {
	local attempt=0 ret
	while [ "$attempt" -lt 2 ]; do
		attempt=$((attempt + 1))
		captcha_set_state recognizing
		_log "验证码识别开始：请求 $attempt/2，超时 $ai_timeout 秒"
		ai_request "$captcha_dir/image" '识别图片中的验证码，仅返回验证码字符，勿添加其他内容。' "$(cat "$captcha_dir/mime")"
		ret=$?
		_log "$ai_diagnostic"
		if [ "$ret" -eq 0 ]; then
			if captcha_validate "$ai_content"; then captcha_code=$ai_content; return 0; fi
			_log '识别结果不符合验证码格式，切换为手动输入'
			return 1
		fi
		[ "$ai_retryable" -eq 1 ] && [ "$attempt" -lt 2 ] || return 1
		sleep 3
	done
	return 1
}

# Only the daemon consumes UI requests and modifies the active challenge.
captcha_wait_manual() {
	local verify_type=$1 deadline=$(( $(date +%s) + 180 )) generation action code
	captcha_set_state manual
	_log '请在 LuCI 页面输入验证码（180 秒内）'
	while [ "$(date +%s)" -lt "$deadline" ]; do
		if mv "$captcha_dir/request" "$captcha_dir/request.ready" 2>/dev/null; then
			{
				IFS= read -r generation
				IFS= read -r action
				IFS= read -r code
			} < "$captcha_dir/request.ready"
			rm -f "$captcha_dir/request.ready"
			if [ "$generation" = "$captcha_generation" ]; then
				case "$action" in
					refresh)
						swjsq_get_verify_code "$verify_type" || return 1
						captcha_set_state manual;;
					submit)
						if captcha_validate "$code"; then
							captcha_code=$code; captcha_set_state submitting; return 0
						fi;;
				esac
			fi
		fi
		sleep 1
	done
	captcha_clear expired
	_log '等待验证码超时，请在页面点击重新获取'
	return 1
}

# Login itself performs one request. This wrapper owns the bounded captcha loop.
swjsq_login() {
	local submissions=0 automatic=1 verify_type
	captcha_clear
	swjsq_login_once && return 0
	while [ "$lasterr" = 6 ]; do
		verify_type=${captcha_verify_type:-MEA}
		swjsq_get_verify_code "$verify_type" || return 1
		if [ -n "$chatgpt_api_key" ] && [ "$automatic" -eq 1 ] && [ "$submissions" -lt 3 ]; then
			if swjsq_ai_recognize; then
				submissions=$((submissions + 1))
			else
				automatic=0
			fi
		else
			automatic=0
		fi
		if [ "$automatic" -eq 0 ]; then
			captcha_wait_manual "$verify_type" || return 1
		fi
		captcha_key=$(cat "$captcha_dir/key")
		captcha_set_state submitting
		swjsq_login_once && { captcha_clear; return 0; }
		captcha_code=; captcha_key=
		# Only an explicit captcha rejection may fetch a new challenge.
		[ "$lasterr" = 6 ] || { captcha_clear login_error; return 1; }
		_log '验证码未通过，重新获取验证码'
	done
	return 1
}

# Replace the uninterruptible 130-minute sleep with a UI-wakeable cooldown.
captcha_cooldown() {
	local remaining=7800 action generation state_generation
	while [ "$remaining" -gt 0 ]; do
		if [ -s "$captcha_dir/request" ]; then
			generation=$(sed -n '1p' "$captcha_dir/request")
			action=$(sed -n '2p' "$captcha_dir/request")
			state_generation=$(sed -n '2p' "$captcha_dir/state")
			rm -f "$captcha_dir/request"
			[ "$action" = refresh ] && [ "$generation" = "$state_generation" ] && return 0
		fi
		sleep 2
		remaining=$((remaining - 2))
	done
}
