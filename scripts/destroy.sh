#!/usr/bin/env bash
# A -> B の順に destroy する (作成と逆順)。
#
# 使い方:
#   ./scripts/destroy.sh a     アカウント A だけを destroy
#   ./scripts/destroy.sh b     アカウント B だけを destroy
#   ./scripts/destroy.sh all   a -> b を続けて実行
#
# aws login は同時に 1 アカウントしか保持できないため、逐次実行する場合は
# A にログイン -> destroy a -> B にログイン -> destroy b の順で行う。
set -euo pipefail

cd "$(dirname "$0")/.."

# プロファイル名は env.local から読む (実値をコミット対象に置かないため)。
# 環境変数で直接指定されていればそれを優先する。
if [[ -f env.local ]]; then
  # shellcheck disable=SC1091
  set -a
  source ./env.local
  set +a
fi

STAGE=${1:-all}
shift || true

destroy_a() {
  local profile=${PROFILE_A:?env.local に PROFILE_A を設定してください}
  echo "==> [A] アカウント A を destroy"
  terraform -chdir=terraform/account-a destroy -var "profile=$profile" "$@"
}

destroy_b() {
  local profile=${PROFILE_B:?env.local に PROFILE_B を設定してください}
  echo "==> [B] アカウント B を destroy"
  terraform -chdir=terraform/account-b destroy -var "profile=$profile" "$@"
}

case "$STAGE" in
  a) destroy_a "$@" ;;
  b) destroy_b "$@" ;;
  all)
    destroy_a "$@"
    destroy_b "$@"
    ;;
  *)
    echo "エラー: stage は a / b / all のいずれかを指定してください (指定値: $STAGE)" >&2
    exit 1
    ;;
esac
