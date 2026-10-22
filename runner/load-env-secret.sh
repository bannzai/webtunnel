#!/bin/bash
# base64 の KEY=VALUE 列を運ぶ secret（WEBTUNNEL_AUTH_ENV / WEBTUNNEL_SETUP_ENV）を復号して環境変数にする関数群。
# run-auth-setup.sh と start-dev-server.sh が source する。呼び出し側で warn <メッセージ> を定義しておく。

# workflow コマンド（`::add-mask::` 等）のデータ部は runner 側で `%25` / `%0D` / `%0A` が
# 元の文字へ復元される。エスケープせずに渡すと、`%25` を含む値では登録されるマスクが実値とずれ、
# 実値がログに出た時に伏字にならない。`%` を先に置換する順序も必須。
# 参照: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands
escape_workflow_command_data() {
  local data=$1
  data="${data//'%'/%25}"
  data="${data//$'\r'/%0D}"
  data="${data//$'\n'/%0A}"
  printf '%s' "$data"
}

# 復号した値を add-mask に登録し、環境変数として export する。
# add-mask はジョブ全体に効くため、以降の step（keepalive の chrome.log 出力等）でも伏字になる。
# add-mask の行は step の標準出力に出す必要があるため、呼び出し側は標準出力をファイルへ向けずに呼ぶ。
# 副作用: export した変数名を LOADED_ENV_NAMES に入れる
load_env_secret() {
  local secret_name=$1 encoded=$2
  local decoded line key value
  LOADED_ENV_NAMES=()
  if ! decoded="$(printf '%s' "$encoded" | base64 -d 2>/dev/null)"; then
    warn "secret \`${secret_name}\` を base64 として復号できなかった。値を環境変数に渡さずに続行する。"
    return 0
  fi

  local -a names=()
  while IFS= read -r line || [ -n "$line" ]; do
    # Windows で作った KEY=VALUE 列は行末に CR が残り、値の一部として export されてしまう
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    # `=` が無い行では ${line%%=*} も ${line#*=} も行全体を返し、KEY=KEY として通ってしまう
    case "$line" in *=*) ;; *)
      warn "secret \`${secret_name}\` に \`=\` を含まない行がある。その行を無視する。"
      continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      warn "secret \`${secret_name}\` に \`KEY=VALUE\` 形式でない行がある。その行を無視する。"
      continue
    fi
    # GITHUB_ENV / PATH 等の制御用変数を secret の値で上書きされると、このスクリプトや
    # 後続コマンドの挙動（GitHub の永続化ファイルの行き先・コマンド解決）を乗っ取れてしまう
    case "$key" in
      GITHUB_*|RUNNER_*|ACTIONS_*|CI|PATH|HOME|SHELL|BASH_ENV|ENV|LD_*)
        warn "secret \`${secret_name}\` の \`${key}\` は GitHub Actions・シェルの制御用変数名のため無視する。"
        continue ;;
    esac
    # 最初の `=` 以降は引用符も含めて生の値として扱う（引用符・エスケープの構文は提供しない。
    # 「気を利かせて」剥がすと、引用符で始まり引用符で終わる正規のパスワードを壊す）
    # 空値の add-mask は runner が警告を出すだけなので登録しない（export はする）
    if [ -n "$value" ]; then
      echo "::add-mask::$(escape_workflow_command_data "$value")"
    fi
    # UID 等シェルの readonly 変数名への代入は if 条件の中でもシェルごと中断させる致命エラーになる。
    # サブシェルで代入可否を先に確かめ、不可なら警告して続行する（step ごと死なせない）
    if ( export "$key=$value" ) 2>/dev/null; then
      export "$key=$value"
      names+=("$key")
    else
      warn "secret \`${secret_name}\` の \`${key}\` は export できない変数名（シェルの readonly 等）のため無視する。"
    fi
  done < <(printf '%s\n' "$decoded")

  if [ ${#names[@]} -gt 0 ]; then
    echo "secret \`${secret_name}\` の値を環境変数として渡す: ${names[*]}"
  fi
  LOADED_ENV_NAMES=(${names[@]+"${names[@]}"})
}
