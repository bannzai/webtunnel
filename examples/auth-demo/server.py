#!/usr/bin/env python3
"""ログインしないと中身が見えないページを runner の localhost で提供する検証用サーバ。

webtunnel の「ログイン済み状態でセッションを開始する」経路を、外部サービスの
アカウントを使わずに end-to-end で検証するためだけに存在する。
資格情報は環境変数 WEBTUNNEL_DEMO_USERNAME / WEBTUNNEL_DEMO_PASSWORD で受け取る。
"""
import http.server
import os
import secrets
import sys
import urllib.parse

PORT = int(os.environ.get("WEBTUNNEL_DEMO_PORT", "8123"))
USERNAME = os.environ.get("WEBTUNNEL_DEMO_USERNAME", "")
PASSWORD = os.environ.get("WEBTUNNEL_DEMO_PASSWORD", "")
COOKIE_NAME = "webtunnel_demo_session"
# パスワードそのものを cookie に載せないよう、起動ごとのランダム値をセッション鍵にする
SESSION_TOKEN = secrets.token_urlsafe(16)

LOGIN_PAGE = """<!doctype html><html lang="ja"><head><meta charset="utf-8">
<title>webtunnel demo - ログイン</title>
<style>body{{font-family:sans-serif;margin:64px;font-size:20px}}
input{{font-size:20px;padding:6px;margin:4px 0;display:block}}
button{{font-size:20px;padding:8px 24px;margin-top:12px}}</style></head>
<body><h1 id="login-page">ログインが必要です</h1>
<form method="post" action="/login">
<label>ユーザー名<input id="username" name="username" autocomplete="off"></label>
<label>パスワード<input id="password" name="password" type="password"></label>
<button id="submit" type="submit">ログイン</button>
</form>{error}</body></html>"""

PROTECTED_PAGE = """<!doctype html><html lang="ja"><head><meta charset="utf-8">
<title>webtunnel demo - ログイン済み</title>
<style>body{{font-family:sans-serif;margin:64px;font-size:28px}}</style></head>
<body><h1 id="authenticated">ログイン済みページ</h1>
<p>ようこそ、{username} さん。このページは cookie が無いと表示されません。</p>
</body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, message_format, *args):
        # リクエストラインだけを stderr に出す（POST の本文は記録しない）
        sys.stderr.write("%s - %s\n" % (self.address_string(), message_format % args))

    def _send(self, status, body, headers=()):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def _authenticated(self):
        cookie = self.headers.get("Cookie", "")
        return f"{COOKIE_NAME}={SESSION_TOKEN}" in cookie

    def do_GET(self):
        if self.path.startswith("/login"):
            self._send(200, LOGIN_PAGE.format(error=""))
        elif self._authenticated():
            self._send(200, PROTECTED_PAGE.format(username=USERNAME))
        else:
            self._send(302, "", headers=[("Location", "/login")])

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"))
        ok = (
            form.get("username", [""])[0] == USERNAME
            and form.get("password", [""])[0] == PASSWORD
        )
        if not ok:
            self._send(401, LOGIN_PAGE.format(error='<p id="login-error">ログインに失敗しました</p>'))
            return
        self._send(
            302,
            "",
            headers=[
                ("Location", "/"),
                ("Set-Cookie", f"{COOKIE_NAME}={SESSION_TOKEN}; Path=/; HttpOnly"),
            ],
        )


if __name__ == "__main__":
    if not USERNAME or not PASSWORD:
        sys.exit("WEBTUNNEL_DEMO_USERNAME / WEBTUNNEL_DEMO_PASSWORD が未設定")
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
