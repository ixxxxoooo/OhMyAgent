// @author ixxxxoooo
// 内置浏览器注入页面的脚本:控制台/网络钩子、可访问性快照、点击、输入、滚动。
// 参数一律经 `callAsyncJavaScript` 的 arguments 传入,不拼接进脚本,避免注入。

import Foundation

enum BrowserScripts {
    /// 文档开始时注入:转发 console、未捕获错误、fetch/XHR 到原生(消息名 `oma`)。
    static let hook = """
    (function(){
      if (window.__omaHooked) return; window.__omaHooked = true;
      const post = (k, p) => { try { window.webkit.messageHandlers.oma.postMessage(Object.assign({k: k}, p)); } catch (e) {} };
      const fmt = (x) => { try { return typeof x === 'string' ? x : JSON.stringify(x); } catch (e) { return String(x); } };
      ['log','info','warn','error','debug'].forEach(function(level){
        const orig = console[level];
        console[level] = function(){ post('console', {level: level, text: Array.prototype.map.call(arguments, fmt).join(' ').slice(0, 2000)}); return orig.apply(this, arguments); };
      });
      window.addEventListener('error', function(e){ post('console', {level: 'error', text: 'Uncaught ' + e.message + ' (' + (e.filename || '') + ':' + e.lineno + ')'}); });
      window.addEventListener('unhandledrejection', function(e){ post('console', {level: 'error', text: 'Unhandled rejection: ' + String(e.reason)}); });
      const textual = function(ct){ return /json|text|xml|javascript|html|x-www-form-urlencoded/i.test(ct || ''); };
      const bodyText = function(b){ if (b == null) return undefined; if (typeof b === 'string') return b.slice(0, 4000); if (b instanceof URLSearchParams) return b.toString().slice(0, 4000); return undefined; };
      const of = window.fetch;
      if (of) window.fetch = function(input, init){
        const t = Date.now(); const u = typeof input === 'string' ? input : ((input && input.url) || String(input)); const m = (init && init.method) || (input && input.method) || 'GET';
        const req = bodyText(init && init.body);
        return of.apply(this, arguments).then(function(r){
          const ct = r.headers.get('content-type') || '';
          const base = {method: m, url: u, status: r.status, ms: Date.now() - t, ct: ct.split(';')[0], req: req};
          if (textual(ct)) { r.clone().text().then(function(s){ post('net', Object.assign(base, {res: s.slice(0, 4000)})); }, function(){ post('net', base); }); }
          else { post('net', base); }
          return r; },
          function(err){ post('net', {method: m, url: u, status: 0, ms: Date.now() - t, error: String(err), req: req}); throw err; });
      };
      const oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__m = m; this.__u = String(u); return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(body){ const t = Date.now(); const self = this; const req = bodyText(body);
        this.addEventListener('loadend', function(){
          const ct = (self.getResponseHeader && self.getResponseHeader('content-type')) || '';
          let res; try { if (textual(ct) && (self.responseType === '' || self.responseType === 'text')) res = String(self.responseText).slice(0, 4000); } catch (e) {}
          post('net', {method: self.__m, url: self.__u, status: self.status, ms: Date.now() - t, ct: ct.split(';')[0], req: req, res: res}); });
        return os.apply(this, arguments); };
    })();
    """

    /// 可访问性快照:给可交互元素打 `data-oma-ref`,返回文本树。
    static let snapshot = """
    const MAX_NODES = 600, MAX_CHARS = 30000;
    document.querySelectorAll('[data-oma-ref]').forEach(function(e){ e.removeAttribute('data-oma-ref'); });
    let counter = 0, nodes = 0, chars = 0;
    const out = [];
    const skip = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','HEAD','META','LINK','SVG','PATH']);
    const visible = function(el){ const r = el.getBoundingClientRect(); if (r.width <= 0 || r.height <= 0) return false; const s = getComputedStyle(el); return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0'; };
    const clean = function(t, n){ t = (t || '').replace(/\\s+/g, ' ').trim(); return t.length > n ? t.slice(0, n) + '…' : t; };
    const roleOf = function(el){
      const explicit = el.getAttribute('role'); const tag = el.tagName;
      if (tag === 'A' && el.hasAttribute('href')) return 'link';
      if (tag === 'BUTTON' || explicit === 'button') return 'button';
      if (tag === 'SELECT') return 'combobox';
      if (tag === 'TEXTAREA' || el.isContentEditable) return 'textbox';
      if (tag === 'INPUT') { const t = (el.type || 'text').toLowerCase(); if (t === 'checkbox' || t === 'radio') return t; if (t === 'submit' || t === 'button' || t === 'reset' || t === 'image') return 'button'; if (t === 'hidden') return null; return 'textbox'; }
      if (tag === 'SUMMARY') return 'button';
      if (explicit && ['link','checkbox','radio','tab','menuitem','switch','textbox','combobox','option','searchbox'].indexOf(explicit) >= 0) return explicit;
      if (el.hasAttribute('onclick') || (el.tabIndex >= 0 && el.getAttribute('tabindex') !== null)) return 'clickable';
      return null;
    };
    const labelOf = function(el){
      return clean(el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || el.value || el.name || '', 80);
    };
    const walk = function(el, depth){
      if (nodes >= MAX_NODES || chars >= MAX_CHARS) return;
      if (el.nodeType !== 1 || skip.has(el.tagName.toUpperCase()) || !visible(el)) return;
      const indent = '  '.repeat(Math.min(depth, 6));
      const role = roleOf(el);
      if (role) {
        counter += 1; const ref = 'e' + counter; el.setAttribute('data-oma-ref', ref);
        let line = indent + '- ' + role + ' "' + labelOf(el) + '" [ref=' + ref + ']';
        if (el.tagName === 'A') line += ' href=' + clean(el.getAttribute('href'), 120);
        if (role === 'textbox' || role === 'combobox') line += ' value="' + clean(el.value || el.textContent, 60) + '"';
        if (role === 'checkbox' || role === 'radio') line += el.checked ? ' [checked]' : ' [unchecked]';
        if (el.disabled) line += ' [disabled]';
        out.push(line); nodes += 1; chars += line.length; return;
      }
      if (/^H[1-6]$/.test(el.tagName)) {
        const line = indent + '- heading(' + el.tagName[1] + ') "' + clean(el.innerText, 120) + '"'; out.push(line); nodes += 1; chars += line.length; return;
      }
      if (el.tagName === 'IMG') { const alt = clean(el.getAttribute('alt'), 80); if (alt) { out.push(indent + '- img "' + alt + '"'); nodes += 1; } return; }
      let own = '';
      el.childNodes.forEach(function(n){ if (n.nodeType === 3) own += n.textContent + ' '; });
      own = clean(own, 160);
      let emitted = false;
      if (own.length > 1) { const line = indent + '- text "' + own + '"'; out.push(line); nodes += 1; chars += line.length; emitted = true; }
      el.childNodes.forEach(function(n){ walk(n, emitted ? depth + 1 : depth); });
    };
    walk(document.body || document.documentElement, 0);
    const header = 'URL: ' + location.href + '\\nTitle: ' + document.title + '\\nScroll: ' + Math.round(window.scrollY) + '/' + Math.max(0, Math.round(document.documentElement.scrollHeight - window.innerHeight)) + ' px\\n';
    return header + (out.length ? out.join('\\n') : '(page has no visible content yet)') + ((nodes >= MAX_NODES || chars >= MAX_CHARS) ? '\\n… (truncated)' : '');
    """

    /// 点击:`ref` 来自最近一次快照。
    static let click = """
    const el = document.querySelector('[data-oma-ref="' + ref + '"]');
    if (!el) throw new Error('Element ' + ref + ' not found. Take a new browser_snapshot.');
    el.scrollIntoView({block: 'center', inline: 'center'});
    if (typeof el.focus === 'function') el.focus({preventScroll: true});
    const r = el.getBoundingClientRect();
    const opts = function(b, detail){ return {bubbles: true, cancelable: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: b, buttons: b === 2 ? 2 : 1, detail: detail}; };
    const label = (el.getAttribute('aria-label') || el.innerText || el.value || '').replace(/\\s+/g, ' ').trim().slice(0, 60);
    if (button === 'right') {
      ['mousedown', 'mouseup', 'contextmenu'].forEach(function(t){ el.dispatchEvent(new MouseEvent(t, opts(2, 1))); });
      return 'Right-clicked ' + el.tagName.toLowerCase() + ' "' + label + '"';
    }
    if (double) {
      el.click(); el.click();
      el.dispatchEvent(new MouseEvent('dblclick', opts(0, 2)));
      return 'Double-clicked ' + el.tagName.toLowerCase() + ' "' + label + '"';
    }
    el.click();
    return 'Clicked ' + el.tagName.toLowerCase() + ' "' + label + '"';
    """

    /// 悬停:依次派发 pointer/mouse 的 over/enter/move 事件,触发 hover 菜单与 tooltip(CSS :hover 由 WebKit 按真实指针决定,脚本无法伪造)。
    static let hover = """
    const el = document.querySelector('[data-oma-ref="' + ref + '"]');
    if (!el) throw new Error('Element ' + ref + ' not found. Take a new browser_snapshot.');
    el.scrollIntoView({block: 'center', inline: 'center'});
    const r = el.getBoundingClientRect();
    const o = {bubbles: true, cancelable: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2};
    ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove'].forEach(function(t){
      const ev = t.indexOf('pointer') === 0 ? new PointerEvent(t, Object.assign({pointerId: 1, pointerType: 'mouse'}, o)) : new MouseEvent(t, o);
      el.dispatchEvent(ev);
    });
    return 'Hovered ' + el.tagName.toLowerCase() + ' "' + (el.getAttribute('aria-label') || el.innerText || el.value || '').replace(/\\s+/g, ' ').trim().slice(0, 60) + '"';
    """

    /// 输入:替换输入框的值并触发 input/change;`submit` 时再模拟回车并提交所在表单。
    static let type = """
    const el = document.querySelector('[data-oma-ref="' + ref + '"]');
    if (!el) throw new Error('Element ' + ref + ' not found. Take a new browser_snapshot.');
    el.scrollIntoView({block: 'center'});
    el.focus({preventScroll: true});
    if (el.isContentEditable) { el.textContent = text; }
    else if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      const proto = el.tagName === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set; setter.call(el, text);
    } else if (el.tagName === 'SELECT') { el.value = text; }
    else { throw new Error('Element ' + ref + ' is not a text field.'); }
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    if (submit) {
      ['keydown','keypress','keyup'].forEach(function(t){ el.dispatchEvent(new KeyboardEvent(t, {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true})); });
      if (el.form && typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
    }
    return 'Typed ' + text.length + ' character(s)' + (submit ? ' and pressed Enter' : '');
    """

    /// 滚动:`direction` 为 up/down/top/bottom;`ref` 非空时滚到元素。
    static let scroll = """
    if (ref) {
      const el = document.querySelector('[data-oma-ref="' + ref + '"]');
      if (!el) throw new Error('Element ' + ref + ' not found. Take a new browser_snapshot.');
      el.scrollIntoView({block: 'center'});
    } else if (direction === 'top') { window.scrollTo(0, 0); }
    else if (direction === 'bottom') { window.scrollTo(0, document.documentElement.scrollHeight); }
    else if (direction === 'up') { window.scrollBy(0, -window.innerHeight * 0.8); }
    else { window.scrollBy(0, window.innerHeight * 0.8); }
    return 'Scroll position ' + Math.round(window.scrollY) + '/' + Math.max(0, Math.round(document.documentElement.scrollHeight - window.innerHeight)) + ' px';
    """
}
