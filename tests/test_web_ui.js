const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname, '../files/luci/view/xlnetacc/web.htm'), 'utf8');
const script = source.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1].replace(/<%=[\s\S]*?%>/g, 'test-route');
const elements = {}, requests = [];
const context = {
    document: { getElementById(id) { return elements[id] || (elements[id] = {
        style: {}, disabled: false, removeAttribute(name) { delete this[name]; }
    }); } },
    window: {}, URL, Date, setTimeout, clearTimeout,
    XHR: function() { this.post = (url, data, callback) => {
        requests.push({url, data}); callback({status: 200}, {ok: true, message: 'queued'});
    }; }
};
vm.runInNewContext(script, context);
const update = context.window.xlnetaccWebUpdate;
const el = name => elements['xlnetacc-web-' + name];
update({protocol: 'web', run_state: true, web: {stage: 'auth_required'}});
assert.equal(el('panel').style.display, '');
assert.equal(el('authorize').disabled, false);
assert.equal(el('open').disabled, true);
el('authorize').onclick();
assert.deepEqual(requests[0].data, {token: 'test-route', action: 'authorize'});
const authorization = {stage: 'authorizing', expires_at: Date.now()/1000 + 120,
    authorization_url: 'https://i.xunlei.com/center/account/personal/oauth/?state=test', user_code: 'test'};
update({protocol: 'web', run_state: true, web: authorization});
assert.equal(el('authorization').style.display, '');
assert.equal(el('authorize').disabled, true);
assert.equal(el('cancel').disabled, false);
assert.equal(el('check').disabled, true);
el('return-url').value = 'https://evil.example/?code=bad&state=bad';
el('submit').onclick();
assert.equal(requests.length, 1);
el('return-url').value = 'https://vip.xunlei.com/pages/2023/broadband-speed/m/?code=one-time-code&state=test';
el('submit').onclick();
assert.deepEqual(requests[1].data, {token: 'test-route', code: 'one-time-code', state: 'test'});
assert.equal(el('return-url').value, '');
update({protocol: 'web', run_state: true, web: {...authorization, authorization_url: 'https://evil.example/'}});
assert.equal(el('authorization').style.display, 'none');
assert.equal(el('link').href, undefined);
update({protocol: 'web', run_state: true, web: {...authorization, expires_at: 1}});
assert.equal(el('authorization').style.display, 'none');
update({protocol: 'web', run_state: true, web: {stage: 'active', authenticated: true, message: '<img onerror=bad>'}});
assert.equal(el('message').textContent, '<img onerror=bad>');
assert.equal(el('close').disabled, false);
update({protocol: 'web', run_state: true, web: {stage: 'active', authenticated: true,
    can_reauthorize: true, login_expires_at: Date.now()/1000 + 7200}});
assert(el('expiry').textContent.includes('到期前自动续登'));
assert(!el('expiry').textContent.includes('官方未提供'));
el('close').onclick();
assert.equal(requests[2].data.action, 'close');
update({protocol: 'web', run_state: false, web: {}});
assert.equal(el('authorize').disabled, true);
update({protocol: 'android', run_state: true, web: {}});
assert.equal(el('panel').style.display, 'none');
console.log('Web authorization UI checks passed');
