// cdp.mjs: chạy JavaScript trong tab đang mở của trình duyệt Hermes qua Chrome DevTools Protocol (cổng
// --remote-debugging-port chỉ nghe trên 127.0.0.1). Dùng thay cho sleep: chờ trang tải xong, chờ phần tử hiện ra.
//
//   node cdp.mjs PORT eval JS          in giá trị của biểu thức JS (chuỗi in thẳng, còn lại in JSON)
//   node cdp.mjs PORT wait JS SECS     chờ tới khi JS trả giá trị truthy (tối đa SECS giây), in giá trị; hết giờ: mã 1
//   node cdp.mjs PORT nav URL SECS     mở URL trong tab đang mở, chờ trang mới dựng xong DOM (không chờ ảnh, video), in
//                                      tiêu đề; phần tử cần dùng thì người gọi tự chờ bằng "wait"/"tap"
//   node cdp.mjs PORT tap JS SECS      chờ JS trả về một phần tử hiển thị rồi bấm chuột vào giữa nó (sự kiện chuột thật
//                                      của trang qua Input.dispatchMouseEvent: TikTok bỏ qua el.click(); không đụng
//                                      chuột của user), in tên phần tử; hết giờ: mã 1
//
// Trong JS có sẵn các hàm (PRELUDE): vis(e), nm(e) (tên như accessibility: aria-label hoặc chữ hiển thị),
// find(prefix, sel) (phần tử hiển thị đầu tiên có tên bắt đầu bằng prefix), click(prefix, sel).
const PRELUDE = `
const vis = e => { if (!e) return false; const r = e.getBoundingClientRect();
  return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== 'hidden'; };
const nm = e => (e.getAttribute('aria-label') || e.innerText || e.textContent || '').trim().replace(/\\s+/g, ' ');
const CLICKABLE = 'button, a, [role=button], [role=tab], [role=menuitem], [role=option], li[tabindex], div[tabindex]';
const find = (prefix, sel = CLICKABLE) => [...document.querySelectorAll(sel)].find(e => vis(e) && nm(e).startsWith(prefix)) || null;
const click = (prefix, sel) => { const e = find(prefix, sel); if (!e) return false; e.scrollIntoView({block: 'center'}); e.click(); return true; };
`;

const [port, cmd, arg, secsArg] = process.argv.slice(2);
const secs = Number(secsArg ?? 15);
const deadline = Date.now() + secs * 1000;
// Chốt chặn cuối: dù kết nối treo ở đâu, quá hạn 5 giây thì thoát lỗi.
setTimeout(() => { console.error(`cdp: quá ${secs} giây`); process.exit(1); }, secs * 1000 + 5000).unref();
const base = `http://127.0.0.1:${port}`;

async function target() {
  const list = await (await fetch(`${base}/json/list`)).json();
  const pages = list.filter(t => t.type === 'page' && /^https?:/.test(t.url));
  const t = pages[0] ?? list.find(t => t.type === 'page');
  if (!t) throw new Error('không có tab nào');
  return t;
}

function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let id = 0;
    const pending = new Map();
    ws.onmessage = m => {
      const d = JSON.parse(m.data);
      if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
    };
    ws.onerror = () => reject(new Error('không nối được DevTools'));
    ws.onopen = () => resolve({
      // Trang TikTok đang tải có thể chặn luồng chính vài chục giây (chờ mạng), lệnh nào cũng phải đợi: cho mỗi lệnh
      // chờ tới hết thời hạn của cả lệnh cdp.mjs (ít nhất 2 giây).
      send: (method, params = {}) => new Promise(r => {
        const n = ++id;
        const ms = Math.max(2000, deadline - Date.now());
        const timer = setTimeout(() => { pending.delete(n); r({ error: { message: `${method} không trả lời sau ${secs} giây` } }); }, ms);
        pending.set(n, d => { clearTimeout(timer); r(d); });
        ws.send(JSON.stringify({ id: n, method, params }));
      }),
      close: () => ws.close(),
    });
  });
}

async function evaluate(c, js) {
  const d = await c.send('Runtime.evaluate', {
    // Phần tử DOM không trả về được theo giá trị: đổi thành tên của nó (hoặc true).
    expression: `(async () => { ${PRELUDE}\nconst v = await (${js}); return v instanceof Node ? (nm(v) || true) : v; })()`,
    returnByValue: true, awaitPromise: true,
  });
  if (d.error || d.result?.exceptionDetails) return { error: d.error?.message ?? d.result.exceptionDetails.exception?.description ?? 'lỗi JS' };
  return { value: d.result?.result?.value };
}

const out = v => console.log(typeof v === 'string' ? v : JSON.stringify(v));
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitFor(c, js, deadline) {
  let last;
  while (Date.now() < deadline) {
    try { last = await evaluate(c, js); } catch { last = { error: 'mất kết nối' }; }
    if (!last.error && last.value) return last.value;
    await sleep(200);
  }
  if (last?.error) console.error(`cdp: ${last.error}`);
  return null;
}

try {
  const t = await target();
  const c = await connect(t.webSocketDebuggerUrl);
  // Không bật Runtime thì sau Page.navigate, Runtime.evaluate có thể chờ mãi context của trang mới.
  await c.send('Runtime.enable');
  let code = 0;
  if (cmd === 'eval') {
    const r = await evaluate(c, arg);
    if (r.error) { console.error(`cdp: ${r.error}`); code = 1; } else out(r.value ?? '');
  } else if (cmd === 'wait') {
    const v = await waitFor(c, arg, deadline);
    if (v === null) code = 1; else out(v);
  } else if (cmd === 'tap') {
    const pt = await waitFor(c, `(e => { if (!vis(e)) return null; e.scrollIntoView({block: 'center'});
      const r = e.getBoundingClientRect(); return {x: r.x + r.width / 2, y: r.y + r.height / 2, name: nm(e)}; })(${arg})`, deadline);
    if (pt === null) code = 1;
    else {
      for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased'])
        await c.send('Input.dispatchMouseEvent', { type, x: pt.x, y: pt.y, button: 'left', clickCount: 1 });
      out(pt.name);
    }
  } else if (cmd === 'nav') {
    const before = (await evaluate(c, 'performance.timeOrigin')).value;
    await c.send('Page.navigate', { url: arg });
    // Trang mới có timeOrigin khác trang cũ; chờ nó dựng xong DOM.
    const v = await waitFor(c, `performance.timeOrigin !== ${before} && document.readyState !== 'loading' && (document.title || '-')`, deadline);
    if (v === null) code = 1; else out(v);
  } else {
    console.error('cdp: lệnh không hợp lệ'); code = 2;
  }
  c.close();
  process.exit(code);
} catch (e) {
  console.error(`cdp: ${e.message}`);
  process.exit(1);
}
