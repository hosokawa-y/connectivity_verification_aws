#!/usr/bin/env bash
# アカウント B -> アカウント A の順に apply する。
#
# 使い方:
#   ./scripts/deploy.sh check アカウントとプロファイルの対応だけを確認 (apply しない)
#   ./scripts/deploy.sh b     アカウント B だけを apply
#   ./scripts/deploy.sh a     B の出力を取り込んでアカウント A だけを apply
#   ./scripts/deploy.sh all   b -> a を続けて実行 (両アカウントの認証が同時に有効な場合のみ)
#
#   terraform に渡す追加引数は stage の後に置く: ./scripts/deploy.sh b -auto-approve
#
# なぜ段階を分けられるようにしているか:
#   `aws login` は同時に 1 つのコンソールセッションしか保持できず、別アカウントへ
#   ログインすると前のセッションが失効する。各 apply は自分のアカウントの認証情報
#   だけで完結するので、B を apply -> A にログインし直して A を apply という
#   逐次運用ができる。`terraform output` はローカル state を読むだけで AWS を
#   呼ばないため、A にログイン中でも B の出力は取得できる。
#
# 事前条件:
#   - terraform/account-b/terraform.tfvars に account_a_id を書いておくこと
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

B_DIR=terraform/account-b
A_DIR=terraform/account-a

STAGE=${1:-all}
shift || true

if [[ ! -f "$B_DIR/terraform.tfvars" ]]; then
  echo "エラー: $B_DIR/terraform.tfvars がありません。" >&2
  echo "       $B_DIR/terraform.tfvars.example をコピーして account_a_id を設定してください。" >&2
  exit 1
fi

ACCOUNT_A_ID=$(sed -n 's/^[[:space:]]*account_a_id[[:space:]]*=[[:space:]]*"\([0-9]\{12\}\)".*/\1/p' \
  "$B_DIR/terraform.tfvars")

if [[ -z "$ACCOUNT_A_ID" ]]; then
  echo "エラー: $B_DIR/terraform.tfvars から account_a_id を読み取れません。" >&2
  exit 1
fi

# 指定プロファイルが現在どのアカウントを指しているかを返す
account_id_of() {
  aws sts get-caller-identity --profile "$1" --query Account --output text 2>/dev/null
}

# stage ごとに「今ログインしているアカウントが正しいか」を確認する。
# aws login はログインし直すとプロファイルの向き先が変わるため、プロファイル名では
# なく実アカウント ID で判定する。
require_account() {
  local profile=$1 expected=$2 label=$3 actual

  if ! actual=$(account_id_of "$profile"); then
    echo "エラー: プロファイル $profile で認証できません。" >&2
    echo "        aws login --profile $profile を実行し、$label のコンソールセッションを選択してください。" >&2
    exit 1
  fi

  echo "    プロファイル $profile の実アカウント: $actual"

  case "$expected" in
    "not:$ACCOUNT_A_ID")
      if [[ "$actual" == "$ACCOUNT_A_ID" ]]; then
        echo "エラー: 現在アカウント A ($ACCOUNT_A_ID) にログインしています。" >&2
        echo "        $label にログインし直してください: aws login --profile $profile" >&2
        exit 1
      fi
      ;;
    *)
      if [[ "$actual" != "$expected" ]]; then
        echo "エラー: $label ($expected) ではなく $actual にログインしています。" >&2
        echo "        aws login --profile $profile でログインし直してください。" >&2
        exit 1
      fi
      ;;
  esac
}

deploy_b() {
  local profile=${PROFILE_B:?env.local に PROFILE_B を設定してください}

  echo "==> [B] アカウント B を apply"
  require_account "$profile" "not:$ACCOUNT_A_ID" "アカウント B"

  terraform -chdir="$B_DIR" init -input=false
  terraform -chdir="$B_DIR" apply -var "profile=$profile" "$@"

  echo "    アカウント B の apply 完了: $(terraform -chdir="$B_DIR" output -raw account_b_id)"
}

deploy_a() {
  local profile=${PROFILE_A:?env.local に PROFILE_A を設定してください}

  echo "==> [A] アカウント A を apply"
  require_account "$profile" "$ACCOUNT_A_ID" "アカウント A"

  if [[ ! -f "$B_DIR/terraform.tfstate" ]]; then
    echo "エラー: アカウント B の state がありません。先に ./scripts/deploy.sh b を実行してください。" >&2
    exit 1
  fi

  # terraform output はローカル state を読むだけなので B の認証情報は不要
  # ExternalId を含むため中身は表示しない (このファイルは .gitignore 済み)
  terraform -chdir="$B_DIR" output -raw account_a_tfvars > "$A_DIR/terraform.tfvars"
  echo "    $A_DIR/terraform.tfvars を生成 ($(grep -c . "$A_DIR/terraform.tfvars") 項目)"

  terraform -chdir="$A_DIR" init -input=false
  terraform -chdir="$A_DIR" apply -var "profile=$profile" "$@"
}

case "$STAGE" in
  check)
    # apply せず、両アカウントの認証とアカウント対応だけを確認する
    echo "==> アカウントとプロファイルの対応を確認 (apply しません)"
    require_account "${PROFILE_B:?env.local に PROFILE_B を設定してください}" \
      "not:$ACCOUNT_A_ID" "アカウント B"
    require_account "${PROFILE_A:?env.local に PROFILE_A を設定してください}" \
      "$ACCOUNT_A_ID" "アカウント A"
    echo "    OK: 両アカウントの認証が有効で、対応も正しいです。"
    ;;
  b) deploy_b "$@" ;;
  a) deploy_a "$@" ;;
  all)
    deploy_b "$@"
    echo
    deploy_a "$@"
    echo
    echo "完了。検証は ./scripts/verify.sh を実行してください (アカウント A の認証が必要)。"
    ;;
  *)
    echo "エラー: stage は check / b / a / all のいずれかを指定してください (指定値: $STAGE)" >&2
    exit 1
    ;;
esac
