import { defineConfig } from "vite";

// ポートは runner/start-dev-server.sh が PORT で渡す（session.yml の port input が SSOT）。
// ずれたポートで listen すると ready 判定が通らないため strictPort で失敗させる。
export default defineConfig({
  server: {
    host: "127.0.0.1",
    port: Number(process.env.PORT) || 5173,
    strictPort: true,
  },
});
