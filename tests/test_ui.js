const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const template = fs.readFileSync(path.join(__dirname, '../files/luci/view/xlnetacc/captcha.htm'), 'utf8');
const script = template.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1]
    .replace(/<%:([^%]*)%>/g, (_, text) => text)
    .replace(/<%=[\s\S]*?%>/g, 'test-route');
const elements = {};
const requests = [];
const context = {
    document: { getElementById(id) {
        return elements[id] || (elements[id] = {
            style: {}, value: '', disabled: false,
            removeAttribute(name) { delete this[name]; }
        });
    } },
    window: {}, Date, encodeURIComponent, setTimeout, clearTimeout,
    XHR: function() { this.post = (url, data, cb) => {
        requests.push({ url, data }); cb({ status: 200 }, { ok: true, message: 'queued' });
    }; }
};
vm.runInNewContext(script, context);
const update = context.window.xlnetaccCaptchaUpdate;
for (const stage of ['ready', 'recognizing', 'submitting']) {
    update({ captcha: { stage, generation: 'image.1' } });
    assert.equal(elements['xlnetacc-captcha-preview'].style.display, '', stage + ' must show the image');
    assert.equal(elements['xlnetacc-captcha-input'].style.display, 'none');
    assert.equal(elements['xlnetacc-captcha-submit'].disabled, true);
}
update({ captcha: { stage: 'manual', generation: 'image.1' } });
assert.equal(elements['xlnetacc-captcha-preview'].style.display, '');
assert.equal(elements['xlnetacc-captcha-input'].style.display, '');
elements['xlnetacc-captcha-code'].value = 'aB12';
elements['xlnetacc-captcha-submit'].onclick();
assert.equal(requests[0].data.code, 'aB12');
assert.equal(requests[0].data.generation, 'image.1');
assert.equal(requests[0].data.token, 'test-route');
update({ captcha: { stage: 'manual', generation: 'image.2' } });
assert.equal(elements['xlnetacc-captcha-code'].value, '');
assert(elements['xlnetacc-captcha-image'].src.endsWith('generation=image.2'));
update({ captcha: { stage: 'recognizing', generation: 'image.2' } });
assert.equal(elements['xlnetacc-captcha-input'].style.display, 'none');
assert.equal(elements['xlnetacc-captcha-submit'].disabled, true);
update({ captcha: { stage: 'expired', generation: '' } });
assert.equal(elements['xlnetacc-captcha-preview'].style.display, 'none');
assert.equal(elements['xlnetacc-captcha-image'].src, undefined);
assert.equal(elements['xlnetacc-captcha-refresh'].style.display, '');
update({ captcha: { stage: 'idle', generation: '' }, api_test: 'success\npassed\n1\n' });
elements['xlnetacc-api-test'].onclick();
assert.equal(elements['xlnetacc-api-test'].disabled, true);
update({ captcha: {}, api_test: 'success\npassed\n1\n' });
assert.equal(elements['xlnetacc-api-test'].disabled, true, 'old result must not finish new test');
update({ captcha: {}, api_test: 'running\ntesting\n' + Math.floor(Date.now() / 1000) + '\n' });
update({ captcha: {}, api_test: 'success\npassed\n3\n' });
assert.equal(elements['xlnetacc-api-test'].disabled, false);
assert.equal(elements['xlnetacc-api-result'].textContent, 'passed');
update({ captcha: {}, api_test: 'running\ntesting\n1\n' });
assert.equal(elements['xlnetacc-api-test'].disabled, false, 'stale test must be retryable after a page reload');
console.log('LuCI UI state and submission checks passed');
