const counterValue = document.querySelector("#counter-value");
let count = 0;
document.querySelector("#counter-button").addEventListener("click", () => {
  count += 1;
  counterValue.textContent = String(count);
});

const greetingOutput = document.querySelector("#greeting-output");
document.querySelector("#greeting-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const name = document.querySelector("#greeting-input").value.trim();
  greetingOutput.textContent = name
    ? `こんにちは、${name} さん！`
    : "お名前が空です";
});

const asyncStatus = document.querySelector("#async-status");
const asyncItems = document.querySelector("#async-items");
// dev サーバが静的アセットを配信できていることも同時に確認するため、
// 遅延させたうえで public/items.json を fetch する
const load = async () => {
  await new Promise((resolve) => setTimeout(resolve, 1200));
  const response = await fetch("/items.json");
  const { items } = await response.json();
  for (const item of items) {
    const li = document.createElement("li");
    li.textContent = item;
    asyncItems.append(li);
  }
  asyncStatus.textContent = `読み込み完了（${items.length} 件）`;
};
load().catch((error) => {
  asyncStatus.textContent = `読み込み失敗: ${error.message}`;
});

const elapsedSeconds = document.querySelector("#elapsed-seconds");
const startedAt = Date.now();
setInterval(() => {
  elapsedSeconds.textContent = String(Math.floor((Date.now() - startedAt) / 1000));
}, 1000);
