#!/usr/bin/env python3
"""Xvfb の画面を MJPEG で配信する preview サーバ（セッション中の画面をリアルタイムに見るため）。

`/` が閲覧ページ、`/stream.mjpeg` が MJPEG ストリーム。ストリームは接続ごとに
ffmpeg (x11grab) を起動し、クエリ（fps / width / quality）で帯域と滑らかさを
その場で調整できる。DERP relay 越しの帯域は細いため、既定値は実測に基づく
控えめな値にしてある（PROJECT.md「preview の実測」参照）。

無認証のため bind は 127.0.0.1 のままにし、tailnet への公開は bridge.sh が行う。
env: DISPLAY / WEBTUNNEL_WINDOW_SIZE / PREVIEW_PORT
"""
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DISPLAY = os.environ.get("DISPLAY", ":99")
CAPTURE_SIZE = os.environ.get("WEBTUNNEL_WINDOW_SIZE", "1280x800")
PORT = int(os.environ.get("PREVIEW_PORT", "9100"))

# クエリで指定できるストリーム設定: 既定値と許容範囲
PARAMS = {
    "fps": {"default": 2, "min": 1, "max": 15},
    "width": {"default": 640, "min": 320, "max": 1920},
    "quality": {"default": 8, "min": 2, "max": 31},  # ffmpeg -q:v（小さいほど高画質）
}
# 1 接続ごとに ffmpeg を 1 本使うため、runner の CPU を食い潰さないよう同時視聴数を絞る
MAX_STREAMS = 2

stream_slots = threading.BoundedSemaphore(MAX_STREAMS)

PAGE = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>webtunnel preview</title>
<style>
  body {{ margin: 0; background: #1b1b1f; color: #e6e6e6; font: 14px system-ui, sans-serif; }}
  header, form {{ display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }}
  header {{ padding: 10px 14px; }}
  label {{ display: flex; gap: 4px; align-items: center; }}
  input {{ width: 5em; }}
  img {{ display: block; width: 100%; max-width: {width}px; margin: 0 auto; background: #000; }}
  .note {{ padding: 0 14px 10px; color: #9a9aa2; }}
</style>
<header>
  <form>
    <label>fps <input type="number" name="fps" value="{fps}" min="{fps_min}" max="{fps_max}"></label>
    <label>width <input type="number" name="width" value="{width}" min="{width_min}" max="{width_max}" step="2"></label>
    <label>quality <input type="number" name="quality" value="{quality}" min="{quality_min}" max="{quality_max}"></label>
    <button type="submit">適用</button>
  </form>
  <span>capture {capture} / display {display}</span>
</header>
<img src="/stream.mjpeg?fps={fps}&width={width}&quality={quality}" alt="session preview">
<p class="note">quality は ffmpeg の -q:v（小さいほど高画質・高帯域）。同時視聴は {max_streams} まで。操作は CDP（agent-browser --cdp）で行う。</p>
"""


def stream_settings(query):
    """クエリ文字列から ffmpeg のストリーム設定を作る（不正値・範囲外は既定値に丸める）"""
    parsed = parse_qs(query)
    settings = {}
    for name, spec in PARAMS.items():
        try:
            value = int(parsed.get(name, [spec["default"]])[0])
        except ValueError:
            value = spec["default"]
        settings[name] = max(spec["min"], min(spec["max"], value))
    # yuvj420p は幅も偶数である必要がある（scale の -2 が揃えるのは高さだけ）
    settings["width"] -= settings["width"] % 2
    return settings


class PreviewHandler(BaseHTTPRequestHandler):
    server_version = "webtunnel-preview"
    # ストリームは Content-Length を持たないため、keep-alive しない HTTP/1.0 で返す
    protocol_version = "HTTP/1.0"

    def do_GET(self):
        url = urlparse(self.path)
        settings = stream_settings(url.query)
        if url.path == "/":
            self.send_page(settings)
        elif url.path == "/stream.mjpeg":
            self.send_stream(settings)
        else:
            self.send_error(404)

    def send_page(self, settings):
        fields = {"capture": CAPTURE_SIZE, "display": DISPLAY, "max_streams": MAX_STREAMS}
        fields.update(settings)
        for name, spec in PARAMS.items():
            fields[f"{name}_min"] = spec["min"]
            fields[f"{name}_max"] = spec["max"]
        body = PAGE.format(**fields).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_stream(self, settings):
        if not stream_slots.acquire(blocking=False):
            self.send_error(503, "too many preview streams")
            return
        # ffmpeg の mpjpeg muxer は境界文字列 ffmpeg で multipart を書き出す
        command = [
            "ffmpeg", "-loglevel", "error",
            "-f", "x11grab", "-framerate", str(settings["fps"]),
            "-video_size", CAPTURE_SIZE, "-i", DISPLAY,
            "-vf", f"scale={settings['width']}:-2",
            "-c:v", "mjpeg", "-q:v", str(settings["quality"]), "-pix_fmt", "yuvj420p",
            "-f", "mpjpeg", "-",
        ]
        # スロットの解放は取得と対で外側の finally が担う。起動失敗・切断のどの経路でも返す
        try:
            try:
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            except OSError as error:
                # まだ何も応答していないため 500 を返せる
                self.send_error(500, "cannot start ffmpeg")
                print(f"ffmpeg を起動できない: {error}", flush=True)
                return
            try:
                self.send_response(200)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=ffmpeg")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                while True:
                    chunk = process.stdout.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except OSError:
                # 200 送信後の失敗はクライアント切断（BrokenPipe 等）。応答は書き換えず後始末だけ行う
                pass
            finally:
                process.kill()
                process.wait()
        finally:
            stream_slots.release()

    def log_message(self, fmt, *args):
        # BaseHTTPRequestHandler の既定は stderr へ直接書くため、ログ先を揃える
        print(f"{self.address_string()} {fmt % args}", flush=True)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), PreviewHandler)
    server.daemon_threads = True
    print(f"preview: http://127.0.0.1:{PORT} (display {DISPLAY} / {CAPTURE_SIZE})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
