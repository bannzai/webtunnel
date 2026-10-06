# 引数なしの make で動作確認 (verify) を実行する
.DEFAULT_GOAL := verify

.PHONY: verify
verify:
	set -e; for test in local/test/test-*.sh skills/test/test-*.sh skills/webtunnel/scripts/test/test-*.sh; do case "$$test" in */test-godot-web.sh) continue;; esac; bash "$$test"; done
	bash skills/webtunnel/scripts/test/test-godot-web.sh
