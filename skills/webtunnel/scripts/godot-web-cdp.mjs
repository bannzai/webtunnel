#!/usr/bin/env node
// godot-web.sh の実体。Chrome DevTools Protocol (CDP) に直接 WebSocket 接続して Godot の Web エクスポートを操作する。
// agent-browser を経由しないのは、(1) keydown → keyup の間隔をプロセス起動と往復時間に左右されず ms 単位で
// 制御するため (keyDown の応答を待たずに送信時刻から数える。godotpractice farmsim の実測: 応答待ちで数えると
// 通信時間が押下時間へ加算され歩数がずれる)、(2) PNG 転送が詰まった時に JPEG へ倒す撮影のタイムアウトを持つため
// (5 ゲームが直接 CDP の WebSocket で JPEG 撮影に切り替えた)。agent-browser は同じ CDP に並行して接続してよい。
//
// 依存: Node 22 以上 (global WebSocket / fetch)。npm パッケージは使わない。
// Usage は godot-web.sh のヘッダーコメントを SSOT とする。本ファイルは直接呼ばず godot-web.sh から呼ぶ。
//
// 共通オプション (サブコマンドの前に置く):
//   --cdp <url>          CDP の URL (http://<tailscale IP>:9222)。必須
//   --game-size <WxH>    ゲームの表示解像度 (既定 1280x720。環境変数 GODOT_WEB_GAME_SIZE でも指定可)
//   --target <substr>    操作対象のページを URL の部分一致で選ぶ (既定: 最初の page ターゲット)
//   --timeout <ms>       CDP の各コマンドの応答タイムアウト (既定 30000)
//   --canvas <selector>  canvas のセレクタ (既定 #canvas。Godot 既定シェルの id)
//
// 出力: 結果を JSON 1 行で stdout に出す。エラーは stderr に出して exit 1。引数不正は exit 2。

import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

// ---------------------------------------------------------------------------
// キー表: DOM KeyboardEvent の key / code / keyCode。Godot の Web 版は event.code を physical_keycode、
// event.key を keycode として読む (platform/web/js/libs/library_godot_input.js)。code を省くと Chromium が
// keyCode から補うため、ArrowRight が physical KeyA として届く事故 (godotpractice platformer) になる。
// ---------------------------------------------------------------------------
const KEY_TABLE = {
  ArrowLeft: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
  ArrowUp: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
  ArrowRight: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
  ArrowDown: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
  Space: { key: " ", code: "Space", keyCode: 32, text: " " },
  Enter: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
  Escape: { key: "Escape", code: "Escape", keyCode: 27 },
  Tab: { key: "Tab", code: "Tab", keyCode: 9 },
  Backspace: { key: "Backspace", code: "Backspace", keyCode: 8 },
  Delete: { key: "Delete", code: "Delete", keyCode: 46 },
  Shift: { key: "Shift", code: "ShiftLeft", keyCode: 16 },
  Control: { key: "Control", code: "ControlLeft", keyCode: 17 },
  Alt: { key: "Alt", code: "AltLeft", keyCode: 18 },
  Meta: { key: "Meta", code: "MetaLeft", keyCode: 91 },
  Home: { key: "Home", code: "Home", keyCode: 36 },
  End: { key: "End", code: "End", keyCode: 35 },
  PageUp: { key: "PageUp", code: "PageUp", keyCode: 33 },
  PageDown: { key: "PageDown", code: "PageDown", keyCode: 34 },
};
for (let i = 1; i <= 12; i += 1) {
  KEY_TABLE[`F${i}`] = { key: `F${i}`, code: `F${i}`, keyCode: 111 + i };
}

function resolveKey(name) {
  if (KEY_TABLE[name]) return KEY_TABLE[name];
  // 1 文字: 英字は KeyX (key は小文字)、数字は DigitN
  if (/^[a-zA-Z]$/.test(name)) {
    const upper = name.toUpperCase();
    return { key: name, code: `Key${upper}`, keyCode: upper.charCodeAt(0), text: name };
  }
  if (/^[0-9]$/.test(name)) {
    return { key: name, code: `Digit${name}`, keyCode: name.charCodeAt(0), text: name };
  }
  // code 名での指定 (KeyA / Digit1) も受ける
  const m = /^Key([A-Z])$/.exec(name) || /^Digit([0-9])$/.exec(name);
  if (m) return resolveKey(m[1].toLowerCase());
  throw new UsageError(`未対応のキー名: ${name} (対応: ${Object.keys(KEY_TABLE).join(", ")}, 英数字 1 文字, KeyA / Digit1 形式)`);
}

class UsageError extends Error {}

// ---------------------------------------------------------------------------
// CDP クライアント
// ---------------------------------------------------------------------------
class Cdp {
  constructor(opts) {
    this.opts = opts;
    this.nextId = 1;
    this.pending = new Map();
    this.console = []; // Runtime.consoleAPICalled の蓄積 (接続中のみ)
    this.events = new Map();
  }

  async connect() {
    const base = this.opts.cdp.replace(/\/$/, "");
    let targets;
    try {
      const res = await fetch(`${base}/json/list`, { signal: AbortSignal.timeout(this.opts.timeout) });
      targets = await res.json();
    } catch (e) {
      throw new Error(`CDP に到達できない: ${base}/json/list (${e.message})`);
    }
    const pages = targets.filter((t) => t.type === "page");
    let target = pages[0];
    if (this.opts.targetId) {
      // 再接続 (JPEG フォールバック等) は URL ではなくターゲット ID で同じページを掴む (open で URL が変わっても追える)
      target = pages.find((t) => t.id === this.opts.targetId);
      if (!target) throw new Error(`ターゲット ID ${this.opts.targetId} の page が無い (閉じられた): ${pages.map((p) => p.url).join(", ")}`);
    } else if (this.opts.target) {
      target = pages.find((t) => (t.url || "").includes(this.opts.target));
      if (!target) throw new Error(`--target ${this.opts.target} に一致する page が無い: ${pages.map((p) => p.url).join(", ")}`);
    }
    if (!target) throw new Error("page ターゲットが無い");
    this.targetUrl = target.url;
    this.targetId = target.id;
    await new Promise((resolve, reject) => {
      const ws = new WebSocket(target.webSocketDebuggerUrl);
      const timer = setTimeout(() => reject(new Error(`WebSocket 接続がタイムアウト: ${target.webSocketDebuggerUrl}`)), this.opts.timeout);
      ws.addEventListener("open", () => {
        clearTimeout(timer);
        resolve();
      });
      ws.addEventListener("error", (ev) => {
        clearTimeout(timer);
        reject(new Error(`WebSocket 接続に失敗: ${target.webSocketDebuggerUrl} (${ev.message || "error"})`));
      });
      ws.addEventListener("message", (ev) => this.onMessage(String(ev.data)));
      this.ws = ws;
    });
    await this.send("Runtime.enable");
    await this.send("Page.enable");
  }

  onMessage(raw) {
    const msg = JSON.parse(raw);
    if (msg.id !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
      else p.resolve(msg.result);
      return;
    }
    if (msg.method === "Runtime.consoleAPICalled") {
      const text = (msg.params.args || []).map((a) => (a.value !== undefined ? String(a.value) : a.description || a.type)).join(" ");
      this.console.push({ type: msg.params.type, text, t: Date.now() });
    }
    const handlers = this.events.get(msg.method);
    if (handlers) for (const h of handlers) h(msg.params);
  }

  once(method) {
    return new Promise((resolve) => {
      const h = (params) => {
        this.events.set(method, (this.events.get(method) || []).filter((x) => x !== h));
        resolve(params);
      };
      this.events.set(method, [...(this.events.get(method) || []), h]);
    });
  }

  // 応答を待たずに送るだけ (keyDown の直後から押下時間を数える用途)。応答の Promise を返す
  sendNoWait(method, params = {}, timeout = this.opts.timeout) {
    const id = this.nextId++;
    const p = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`${method} の応答が ${timeout} ms 以内に無い`));
        }
      }, timeout);
      this.pending.set(id, {
        method,
        resolve: (r) => {
          clearTimeout(timer);
          resolve(r);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
    });
    this.ws.send(JSON.stringify({ id, method, params }));
    return p;
  }

  send(method, params = {}, timeout) {
    return this.sendNoWait(method, params, timeout);
  }

  async evaluate(expression, { awaitPromise = true } = {}) {
    const r = await this.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise });
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      throw new Error(`eval 例外: ${d.exception?.description || d.text}`);
    }
    return r.result.value;
  }

  close() {
    if (this.ws) this.ws.close();
  }
}

// ---------------------------------------------------------------------------
// Godot 操作
// ---------------------------------------------------------------------------
const STATUS_JS = (canvasSel) => `(() => {
  const c = document.querySelector(${JSON.stringify(canvasSel)});
  const r = c ? c.getBoundingClientRect() : null;
  // 判定結果はページ単位でキャッシュし、初回に作った診断用コンテキストは即座に解放する
  // (status はクリックや起動待ちのたびに呼ばれる。毎回コンテキストを作って放置すると Chromium の同時
  // コンテキスト数の上限で最も古いゲーム本体のコンテキストが失われる)
  if (window.__godotWebWebgl2 === undefined) {
    let webgl2 = false;
    try {
      const gl = document.createElement("canvas").getContext("webgl2");
      webgl2 = !!gl;
      if (gl) { const ext = gl.getExtension("WEBGL_lose_context"); if (ext) ext.loseContext(); }
    } catch (e) { webgl2 = false; }
    window.__godotWebWebgl2 = webgl2;
  }
  const webgl2 = window.__godotWebWebgl2;
  return {
    href: location.href,
    started: document.getElementById("status") === null,
    notice: (document.getElementById("status-notice") || { textContent: "" }).textContent,
    webgl2,
    viewport: { width: window.innerWidth, height: window.innerHeight },
    canvas: r ? { left: r.left, top: r.top, width: r.width, height: r.height } : null,
  };
})()`;

async function getStatus(cdp) {
  return cdp.evaluate(STATUS_JS(cdp.opts.canvas));
}

// ゲーム座標 → ブラウザ座標。canvas の実寸と余白 (レターボックス) から縮尺とオフセットを求める。
// stretch の aspect が keep (縮尺は min、中央寄せ) の前提。references/godot-web-export.md と同じ式
function mapPoint(status, gameSize, gx, gy) {
  const c = status.canvas;
  if (!c) throw new Error(`canvas が無い (selector: ${status.canvasSelector || "#canvas"})`);
  const s = Math.min(c.width / gameSize.w, c.height / gameSize.h);
  const ox = c.left + (c.width - gameSize.w * s) / 2;
  const oy = c.top + (c.height - gameSize.h * s) / 2;
  return { x: Math.round(ox + gx * s), y: Math.round(oy + gy * s), scale: s, offset: { x: ox, y: oy } };
}

// 押下 (down) を送った直後から待ち、指定時間後に必ず解放 (up) を送ってから両方の応答を見る。
// down の応答を待たないため、その拒否 (エラー・タイムアウト) は先にハンドラを付けて捕まえておく
// (付けないと待機中の拒否で Node が未処理の Promise 拒否として終了し、up が送られず押しっぱなしになる)
async function holdAndRelease(sendDown, hold, sendUp) {
  const downErr = sendDown().then(() => null, (e) => e);
  if (hold > 0) await sleep(hold);
  const upErr = sendUp().then(() => null, (e) => e);
  const [d, u] = await Promise.all([downErr, upErr]);
  if (d) throw d;
  if (u) throw u;
}

function mouseParams(type, x, y, button) {
  const p = { type, x, y, button, modifiers: modifiersMask() };
  if (type !== "mouseMoved") p.clickCount = 1;
  return p;
}

async function clickAt(cdp, x, y, { button = "left", hold = 0 } = {}) {
  await cdp.send("Input.dispatchMouseEvent", mouseParams("mouseMoved", x, y, "none"));
  await holdAndRelease(
    () => cdp.sendNoWait("Input.dispatchMouseEvent", mouseParams("mousePressed", x, y, button)),
    hold,
    () => cdp.sendNoWait("Input.dispatchMouseEvent", mouseParams("mouseReleased", x, y, button)),
  );
}

// 押下中の修飾キー (CDP の modifiers ビットマスク: Alt=1, Ctrl=2, Meta=4, Shift=8)。keydown / keyup で更新し、
// 以降のキー・マウスイベントに載せる (Shift を押したまま ArrowRight を送ると shiftKey が true になる)。
// 1 プロセス内 (seq や 1 回の呼び出し) でだけ追跡する。別々の呼び出しをまたぐ同時押しは追跡できない
const MODIFIER_BITS = { Alt: 1, Control: 2, Meta: 4, Shift: 8 };
const heldModifiers = new Set();
function modifiersMask() {
  let m = 0;
  for (const k of heldModifiers) m |= MODIFIER_BITS[k];
  return m;
}
function trackModifier(type, k) {
  if (!(k.key in MODIFIER_BITS)) return;
  if (type === "keyDown") heldModifiers.add(k.key);
  else heldModifiers.delete(k.key);
}

// 押下中の全キー (修飾キー以外も)。seq が途中で失敗した時に、接続を閉じる前に解放するために追跡する
// (閉じてもゲーム側には押下状態が残り、移動が止まらないため)
const heldKeys = new Map();
function trackHeld(type, k) {
  if (type === "keyUp") heldKeys.delete(k.code);
  else heldKeys.set(k.code, k);
}
async function releaseHeldKeys(cdp) {
  const released = [];
  for (const k of [...heldKeys.values()]) {
    try {
      await cdp.send("Input.dispatchKeyEvent", keyParams("keyUp", k), 3000);
      released.push(k.code);
    } catch (e) {
      process.stderr.write(`押下中のキー ${k.code} を解放できない: ${e.message}\n`);
    }
  }
  return released;
}

function keyParams(type, k) {
  trackModifier(type, k);
  trackHeld(type, k);
  const p = {
    type,
    key: k.key,
    code: k.code,
    windowsVirtualKeyCode: k.keyCode,
    nativeVirtualKeyCode: k.keyCode,
    modifiers: modifiersMask(),
  };
  if (type === "keyDown" && k.text !== undefined) p.text = k.text;
  else if (type === "keyDown") p.type = "rawKeyDown";
  return p;
}

// keyDown を送った時刻から数えて hold ms 後に必ず keyUp を送る。keyDown の応答は待たない
async function pressKey(cdp, name, { hold = 0 } = {}) {
  const k = resolveKey(name);
  const t0 = performance.now();
  await holdAndRelease(
    () => cdp.sendNoWait("Input.dispatchKeyEvent", keyParams("keyDown", k)),
    hold,
    () => cdp.sendNoWait("Input.dispatchKeyEvent", keyParams("keyUp", k)),
  );
  return { key: k.key, code: k.code, hold, modifiers: modifiersMask(), elapsedMs: Math.round(performance.now() - t0) };
}

async function keyDownOnly(cdp, name) {
  const k = resolveKey(name);
  await cdp.send("Input.dispatchKeyEvent", keyParams("keyDown", k));
  return { key: k.key, code: k.code, modifiers: modifiersMask() };
}

async function keyUpOnly(cdp, name) {
  const k = resolveKey(name);
  await cdp.send("Input.dispatchKeyEvent", keyParams("keyUp", k));
  return { key: k.key, code: k.code, modifiers: modifiersMask() };
}

// Godot 側の診断 autoload (references/godot_web_diag.gd) と window オブジェクト経由でやり取りする。
// JavaScriptBridge のコールバックは戻り値を返せないため、request を置いて response をポーリングする
async function nodeRect(cdp, name, timeout) {
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  await cdp.evaluate(`(() => {
    window.__godotWebDiag = window.__godotWebDiag || { request: null, response: null };
    window.__godotWebDiag.response = null;
    window.__godotWebDiag.request = ${JSON.stringify({ id, name })};
    return true;
  })()`);
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const res = await cdp.evaluate(`(() => { const d = window.__godotWebDiag; return d && d.response && d.response.id === ${JSON.stringify(id)} ? d.response : null; })()`);
    if (res) {
      if (!res.found) throw new Error(`Control が見つからない: ${name} (Godot 側の診断 autoload が返した: ${JSON.stringify(res)})`);
      return res;
    }
    await sleep(50);
  }
  throw new Error(`click-node の応答が ${timeout} ms 以内に無い。Godot 側に references/godot_web_diag.gd を autoload として追加しているか確認する`);
}

async function screenshot(cdp, path, { jpeg = false, quality = 80, timeout } = {}) {
  const capture = async (format) => {
    const params = { format };
    if (format === "jpeg") params.quality = quality;
    const r = await cdp.send("Page.captureScreenshot", params, timeout);
    return Buffer.from(r.data, "base64");
  };
  if (jpeg) {
    const buf = await capture("jpeg");
    const out = path.replace(/\.png$/i, ".jpg");
    writeFileSync(out, buf);
    return { path: out, format: "jpeg", bytes: buf.length };
  }
  try {
    const buf = await capture("png");
    writeFileSync(path, buf);
    return { path, format: "png", bytes: buf.length };
  } catch (e) {
    // PNG の転送が詰まった (タイムアウト) 時だけ JPEG に倒す。他のエラーはそのまま。
    // 詰まった PNG の応答は同じ WebSocket 上で流れ続けるため、JPEG は別の接続で撮る (同じ接続では
    // PNG のデータの後ろで待たされて復旧できない)
    if (!/ms 以内に無い/.test(e.message)) throw e;
    process.stderr.write(`PNG の撮影が ${timeout} ms 以内に終わらないため別の接続で JPEG に切り替える\n`);
    const alt = new Cdp({ ...cdp.opts, targetId: cdp.targetId });
    await alt.connect();
    try {
      const params = { format: "jpeg", quality };
      const r = await alt.send("Page.captureScreenshot", params, timeout);
      const buf = Buffer.from(r.data, "base64");
      const out = path.replace(/\.png$/i, "") + ".jpg";
      writeFileSync(out, buf);
      return { path: out, format: "jpeg", bytes: buf.length, fallback: true };
    } finally {
      alt.close();
    }
  }
}

// ページを開いて load を待つ。メインドキュメントの HTTP ステータスも返す (404 のページでも load は完了するため、
// 到達できたかと配信物があるかを分けて判定できるようにする)
async function openUrl(cdp, url, timeout) {
  await cdp.send("Network.enable");
  let status = null;
  let frameId = null;
  const onResponse = (p) => {
    if (p.type === "Document" && (frameId === null || p.frameId === frameId) && status === null) status = p.response.status;
  };
  cdp.events.set("Network.responseReceived", [...(cdp.events.get("Network.responseReceived") || []), onResponse]);
  const loaded = cdp.once("Page.loadEventFired");
  const r = await cdp.send("Page.navigate", { url });
  frameId = r.frameId;
  if (r.errorText) throw new Error(`open に失敗: ${url} (${r.errorText})`);
  // loaderId が無いのは同一ドキュメント内の遷移 (フラグメントだけ違う URL 等)。load は発生しないので待たない
  if (!r.loaderId) return { url, status: null, frameId, sameDocument: true };
  await Promise.race([loaded, sleep(timeout).then(() => { throw new Error(`open の load が ${timeout} ms 以内に終わらない: ${url}`); })]);
  return { url, status, frameId };
}

// 現在のページから同一オリジンの URL を fetch して HTTP ステータスを返す (ページ遷移しない)
async function fetchStatus(cdp, url) {
  const v = await cdp.evaluate(`fetch(${JSON.stringify(url)}, {method: "GET", cache: "no-store"}).then(r => r.status).catch(e => "error: " + e.message)`);
  return { url, status: v };
}

async function waitStarted(cdp, timeout) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    last = await getStatus(cdp);
    if (last.notice) throw new Error(`Godot の起動に失敗: ${last.notice}`);
    // 404 や別ページでは #status が最初から無いため、canvas の存在も起動の条件にする
    if (last.started && last.canvas) return last;
    if (last.started && !last.canvas) throw new Error(`ページに canvas (${cdp.opts.canvas}) が無い。Godot のシェルではないページ (404 等) を開いている: ${last.href}`);
    await sleep(500);
  }
  throw new Error(`#status が ${timeout} ms 以内に消えない (Godot が起動していない): ${JSON.stringify(last)}`);
}

// ページに keydown の捕捉リスナを置いてキーを 1 回送り、ページ側で受信できたかを返す (doctor の実入力段階)
async function probeInput(cdp, name, timeout) {
  const k = resolveKey(name);
  await cdp.evaluate(`(() => {
    window.__godotWebProbe = null;
    window.addEventListener("keydown", function h(e) {
      window.__godotWebProbe = { key: e.key, code: e.code, t: performance.now() };
      window.removeEventListener("keydown", h, true);
    }, true);
    return true;
  })()`);
  await pressKey(cdp, name, { hold: 30 });
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const got = await cdp.evaluate("window.__godotWebProbe");
    if (got) return { received: true, sent: { key: k.key, code: k.code }, got };
    await sleep(50);
  }
  return { received: false, sent: { key: k.key, code: k.code } };
}

// ---------------------------------------------------------------------------
// seq: 1 行 1 操作のシナリオ
// ---------------------------------------------------------------------------
function tokenize(line) {
  // 空白区切り。"..." で囲んだ引数は空白を含められる
  const out = [];
  const re = /"((?:[^"\\]|\\.)*)"|(\S+)/g;
  let m;
  while ((m = re.exec(line)) !== null) out.push(m[1] !== undefined ? m[1].replace(/\\(.)/g, "$1") : m[2]);
  return out;
}

function parseHold(args) {
  const i = args.indexOf("--hold");
  if (i < 0) return { hold: 0, rest: args };
  const hold = Number(args[i + 1]);
  if (!Number.isFinite(hold) || hold < 0) throw new UsageError(`--hold は 0 以上の ms: ${args[i + 1]}`);
  return { hold, rest: [...args.slice(0, i), ...args.slice(i + 2)] };
}

async function runSeq(cdp, file, gameSize, opts) {
  const lines = readFileSync(file, "utf8").split(/\r?\n/);
  const t0 = performance.now();
  const elapsed = () => Math.round(performance.now() - t0);
  const log = (msg) => process.stderr.write(`[${String(elapsed()).padStart(6)} ms] ${msg}\n`);
  const results = [];
  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i].trim();
    if (!raw || raw.startsWith("#")) continue;
    let args = tokenize(raw);
    // 先頭の @<ms> はシナリオ開始からの絶対時刻。その時刻まで待ってから実行する
    if (/^@\d+$/.test(args[0])) {
      const at = Number(args[0].slice(1));
      const wait = at - elapsed();
      if (wait > 0) await sleep(wait);
      args = args.slice(1);
    }
    const [op, ...rest] = args;
    const lineNo = i + 1;
    try {
      let r;
      switch (op) {
        case "open": r = await openUrl(cdp, rest[0], opts.timeout); break;
        case "wait": r = await sleep(Number(rest[0])).then(() => ({ waited: Number(rest[0]) })); break;
        case "wait-started": r = await waitStarted(cdp, Number(rest[0] || 30000)); break;
        case "click": {
          const { hold, rest: a } = parseHold(rest);
          const st = await getStatus(cdp);
          const p = mapPoint(st, gameSize, Number(a[0]), Number(a[1]));
          await clickAt(cdp, p.x, p.y, { hold });
          r = { game: { x: Number(a[0]), y: Number(a[1]) }, browser: { x: p.x, y: p.y } };
          break;
        }
        case "click-node": {
          const rect = await nodeRect(cdp, rest[0], Number(rest[1] || 5000));
          const st = await getStatus(cdp);
          const p = mapPoint(st, gameSize, rect.x + rect.w / 2, rect.y + rect.h / 2);
          await clickAt(cdp, p.x, p.y);
          r = { node: rest[0], rect, browser: { x: p.x, y: p.y } };
          break;
        }
        case "mouse-move": {
          const st = await getStatus(cdp);
          const p = mapPoint(st, gameSize, Number(rest[0]), Number(rest[1]));
          await cdp.send("Input.dispatchMouseEvent", mouseParams("mouseMoved", p.x, p.y, "none"));
          r = { browser: { x: p.x, y: p.y } };
          break;
        }
        case "key": {
          const { hold, rest: a } = parseHold(rest);
          r = await pressKey(cdp, a[0], { hold });
          break;
        }
        case "keydown": r = await keyDownOnly(cdp, rest[0]); break;
        case "keyup": r = await keyUpOnly(cdp, rest[0]); break;
        case "shot": {
          const jpeg = rest.includes("--jpeg");
          r = await screenshot(cdp, rest[0], { jpeg, timeout: opts.timeout });
          break;
        }
        case "console-clear": cdp.console.length = 0; r = { cleared: true }; break;
        case "console-expect": {
          // 蓄積した console にその文字列を含む行が出るまで待つ (既定 5000 ms)
          const needle = rest[0];
          const timeout = Number(rest[1] || 5000);
          const end = Date.now() + timeout;
          let hit = null;
          while (!hit && Date.now() < end) {
            hit = cdp.console.find((c) => c.text.includes(needle));
            if (!hit) await sleep(50);
          }
          if (!hit) throw new Error(`console に "${needle}" が ${timeout} ms 以内に出ない (蓄積: ${cdp.console.length} 行: ${cdp.console.slice(-5).map((c) => c.text).join(" | ")})`);
          r = { matched: hit.text };
          break;
        }
        case "eval": r = { value: await cdp.evaluate(rest.join(" ")) }; break;
        case "echo": r = { echo: rest.join(" ") }; break;
        default: throw new UsageError(`未知の操作: ${op} (open / wait / wait-started / click / click-node / mouse-move / key / keydown / keyup / shot / console-clear / console-expect / eval / echo)`);
      }
      log(`${raw} -> ${JSON.stringify(r)}`);
      results.push({ line: lineNo, op, result: r });
    } catch (e) {
      log(`${raw} -> ERROR ${e.message}`);
      throw new Error(`seq ${file}:${lineNo} (${raw}) で失敗: ${e.message}`);
    }
  }
  return { file, steps: results.length, elapsedMs: elapsed(), results };
}

// ---------------------------------------------------------------------------
// 引数解析と main
// ---------------------------------------------------------------------------
function parseGameSize(s) {
  const m = /^(\d+)x(\d+)$/.exec(s || "");
  if (!m) throw new UsageError(`--game-size は WxH 形式: ${s}`);
  return { w: Number(m[1]), h: Number(m[2]) };
}

function parseArgs(argv) {
  const opts = {
    cdp: process.env.GODOT_WEB_CDP || "",
    gameSize: process.env.GODOT_WEB_GAME_SIZE || "1280x720",
    target: "",
    timeout: 30000,
    canvas: "#canvas",
  };
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (rest.length === 0 && a.startsWith("--")) {
      const v = argv[i + 1];
      switch (a) {
        case "--cdp": opts.cdp = v; i += 1; break;
        case "--game-size": opts.gameSize = v; i += 1; break;
        case "--target": opts.target = v; i += 1; break;
        case "--timeout": opts.timeout = Number(v); i += 1; break;
        case "--canvas": opts.canvas = v; i += 1; break;
        default: throw new UsageError(`未知の共通オプション: ${a}`);
      }
    } else {
      rest.push(a);
    }
  }
  if (!opts.cdp) throw new UsageError("--cdp <url> が必要 (webtunnel-cli.sh cdp <session> が出力する URL)");
  if (!Number.isFinite(opts.timeout) || opts.timeout <= 0) throw new UsageError(`--timeout は正の ms: ${opts.timeout}`);
  return { opts, args: rest };
}

function optValue(args, flag, fallback) {
  const i = args.indexOf(flag);
  if (i < 0) return { value: fallback, rest: args };
  return { value: args[i + 1], rest: [...args.slice(0, i), ...args.slice(i + 2)] };
}

function requireNumber(v, what) {
  const n = Number(v);
  if (!Number.isFinite(n)) throw new UsageError(`${what} は数値: ${v}`);
  return n;
}

async function main() {
  const { opts, args } = parseArgs(process.argv.slice(2));
  const gameSize = parseGameSize(opts.gameSize);
  const [cmd, ...rest] = args;
  if (!cmd) throw new UsageError("サブコマンドが無い");

  const cdp = new Cdp(opts);
  await cdp.connect();
  try {
    let out;
    switch (cmd) {
      case "open": {
        if (!rest[0]) throw new UsageError("open <url>");
        out = await openUrl(cdp, rest[0], opts.timeout);
        break;
      }
      case "status": out = await getStatus(cdp); break;
      case "fetch-status": {
        if (!rest[0]) throw new UsageError("fetch-status <url>");
        out = await fetchStatus(cdp, rest[0]);
        break;
      }
      case "wait-started": {
        const { value } = optValue(rest, "--timeout", "30000");
        out = await waitStarted(cdp, requireNumber(value, "--timeout"));
        break;
      }
      case "eval": {
        if (!rest.length) throw new UsageError("eval <js>");
        out = { value: await cdp.evaluate(rest.join(" ")) };
        break;
      }
      case "map": {
        if (rest.length < 2) throw new UsageError("map <game_x> <game_y>");
        const st = await getStatus(cdp);
        out = mapPoint(st, gameSize, requireNumber(rest[0], "game_x"), requireNumber(rest[1], "game_y"));
        break;
      }
      case "click": {
        const { hold, rest: a } = parseHold(rest);
        if (a.length < 2) throw new UsageError("click <game_x> <game_y> [--hold <ms>]");
        const gx = requireNumber(a[0], "game_x");
        const gy = requireNumber(a[1], "game_y");
        const st = await getStatus(cdp);
        const p = mapPoint(st, gameSize, gx, gy);
        await clickAt(cdp, p.x, p.y, { hold });
        out = { game: { x: gx, y: gy }, browser: { x: p.x, y: p.y }, scale: p.scale, hold };
        break;
      }
      case "mouse-move": {
        if (rest.length < 2) throw new UsageError("mouse-move <game_x> <game_y>");
        const st = await getStatus(cdp);
        const p = mapPoint(st, gameSize, requireNumber(rest[0], "game_x"), requireNumber(rest[1], "game_y"));
        await cdp.send("Input.dispatchMouseEvent", mouseParams("mouseMoved", p.x, p.y, "none"));
        out = { browser: { x: p.x, y: p.y } };
        break;
      }
      case "node-rect":
      case "click-node": {
        const { value, rest: a } = optValue(rest, "--timeout", "5000");
        if (!a[0]) throw new UsageError(`${cmd} <Control 名> [--timeout <ms>]`);
        const rect = await nodeRect(cdp, a[0], requireNumber(value, "--timeout"));
        const st = await getStatus(cdp);
        const p = mapPoint(st, gameSize, rect.x + rect.w / 2, rect.y + rect.h / 2);
        if (cmd === "click-node") await clickAt(cdp, p.x, p.y);
        out = { node: a[0], rect, browser: { x: p.x, y: p.y }, clicked: cmd === "click-node" };
        break;
      }
      case "key": {
        const { hold, rest: a } = parseHold(rest);
        if (!a[0]) throw new UsageError("key <Key> [--hold <ms>]");
        out = await pressKey(cdp, a[0], { hold });
        break;
      }
      case "keydown": {
        if (!rest[0]) throw new UsageError("keydown <Key>");
        out = await keyDownOnly(cdp, rest[0]);
        break;
      }
      case "keyup": {
        if (!rest[0]) throw new UsageError("keyup <Key>");
        out = await keyUpOnly(cdp, rest[0]);
        break;
      }
      case "shot": {
        const jpeg = rest.includes("--jpeg");
        let a = rest.filter((x) => x !== "--jpeg");
        const t = optValue(a, "--timeout", String(opts.timeout));
        a = t.rest;
        const q = optValue(a, "--quality", "80");
        a = q.rest;
        if (!a[0]) throw new UsageError("shot <path> [--jpeg] [--quality <1-100>] [--timeout <ms>]");
        out = await screenshot(cdp, a[0], { jpeg, quality: requireNumber(q.value, "--quality"), timeout: requireNumber(t.value, "--timeout") });
        break;
      }
      case "probe-input": {
        const { value, rest: a } = optValue(rest, "--timeout", "3000");
        out = await probeInput(cdp, a[0] || "Shift", requireNumber(value, "--timeout"));
        if (!out.received) throw new Error(`ページが keydown を受信しない: ${JSON.stringify(out)}`);
        break;
      }
      case "console": {
        // 指定 ms の間だけ console を聞いて出す (接続中しか拾えないため)
        const { value } = optValue(rest, "--wait", "1000");
        await sleep(requireNumber(value, "--wait"));
        out = { lines: cdp.console };
        break;
      }
      case "seq": {
        if (!rest[0]) throw new UsageError("seq <シナリオファイル>");
        out = await runSeq(cdp, rest[0], gameSize, opts);
        break;
      }
      default:
        throw new UsageError(`未知のサブコマンド: ${cmd}`);
    }
    process.stdout.write(`${JSON.stringify(out)}\n`);
  } catch (e) {
    // 途中で失敗して押しっぱなしのキーが残っていれば、接続を閉じる前に解放する
    // (正常終了では解放しない。単独の keydown は意図的に押したままにする用途のため)
    const released = await releaseHeldKeys(cdp);
    if (released.length) process.stderr.write(`失敗したため押下中のキーを解放した: ${released.join(", ")}\n`);
    throw e;
  } finally {
    cdp.close();
  }
}

// process.exit() は stdout への非同期書き込み (パイプ先が遅い時の大きな JSON) を待たずに終了して結果が
// 途中で切れるため、exitCode を設定してイベントループの完了 (WebSocket は close 済み) で終わらせる
main().then(
  () => { process.exitCode = 0; },
  (e) => {
    process.stderr.write(`${e.message}\n`);
    process.exitCode = e instanceof UsageError ? 2 : 1;
  },
);
