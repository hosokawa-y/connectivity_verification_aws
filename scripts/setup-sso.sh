#!/usr/bin/env bash
# IAM Identity Center の SSO プロファイルを ~/.aws/config に設定する。
#
# aws login (コンソールセッション連携) は同時に 1 アカウントしか保持できないため、
# 2 アカウントを同時に使うには SSO プロファイルへ移行する必要がある。
# SSO は 1 回のログインで、許可された全アカウント分の認証情報を同時に発行できる。
#
# 使い方:
#   cp env.local.example env.local     # 実値を設定する
#   ./scripts/setup-sso.sh
#
# 実値 (アカウント ID / start URL 等) は env.local から読む。
# env.local は .gitignore 済みなので、コミットされるファイルに実値は入らない。
#
# 実行後:
#   aws sso login --sso-session "$SSO_SESSION_NAME"
#   ./scripts/deploy.sh all
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f env.local ]]; then
  echo "エラー: env.local がありません。" >&2
  echo "       cp env.local.example env.local を実行し、実値を設定してください。" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a
source ./env.local
set +a

SSO_SESSION_NAME=${SSO_SESSION_NAME:-verify-sso}
AWS_RESOURCE_REGION=${AWS_RESOURCE_REGION:-ap-northeast-1}

for v in ACCOUNT_A_ID ACCOUNT_B_ID PROFILE_A PROFILE_B SSO_START_URL SSO_REGION SSO_PERMISSION_SET; do
  if [[ -z "${!v:-}" ]]; then
    echo "エラー: env.local に $v が設定されていません。" >&2
    exit 1
  fi
done

if [[ ! "$SSO_START_URL" =~ ^https:// ]]; then
  echo "エラー: SSO_START_URL は https:// で始まる URL を指定してください。" >&2
  exit 1
fi

if [[ "$ACCOUNT_A_ID" == "$ACCOUNT_B_ID" ]]; then
  echo "エラー: ACCOUNT_A_ID と ACCOUNT_B_ID が同一です。クロスアカウント検証になりません。" >&2
  exit 1
fi

CONFIG=~/.aws/config
BACKUP="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"

cp "$CONFIG" "$BACKUP"
echo "既存の設定をバックアップしました: $BACKUP"

# 既存の同名プロファイル / sso-session ブロックを取り除いてから書き直す。
# (aws login が書いた login_session 付きの定義と混ざらないようにする)
python3 - "$CONFIG" "$SSO_SESSION_NAME" "$PROFILE_A" "$PROFILE_B" <<'PY'
import re
import sys

path, session, *profiles = sys.argv[1:]
text = open(path, encoding="utf-8").read()

targets = [f"sso-session {session}"] + [f"profile {p}" for p in profiles]
blocks = re.split(r"(?m)^(?=\[)", text)
kept = [b for b in blocks if not any(b.startswith(f"[{t}]") for t in targets)]

open(path, "w", encoding="utf-8").write("".join(kept).rstrip() + "\n")
print(f"  既存ブロックを削除: {', '.join(targets)}")
PY

cat >> "$CONFIG" <<CFG

[sso-session $SSO_SESSION_NAME]
sso_start_url = $SSO_START_URL
sso_region = $SSO_REGION
sso_registration_scopes = sso:account:access

[profile $PROFILE_A]
sso_session = $SSO_SESSION_NAME
sso_account_id = $ACCOUNT_A_ID
sso_role_name = $SSO_PERMISSION_SET
region = $AWS_RESOURCE_REGION
output = json

[profile $PROFILE_B]
sso_session = $SSO_SESSION_NAME
sso_account_id = $ACCOUNT_B_ID
sso_role_name = $SSO_PERMISSION_SET
region = $AWS_RESOURCE_REGION
output = json
CFG

echo "設定しました:"
echo "  [sso-session $SSO_SESSION_NAME]"
echo "  [profile $PROFILE_A]  -> アカウント A"
echo "  [profile $PROFILE_B]  -> アカウント B"
echo
echo "次の手順:"
echo "  1. aws sso login --sso-session $SSO_SESSION_NAME"
echo "  2. 両アカウントが別々に見えることを確認:"
echo "     for p in $PROFILE_A $PROFILE_B; do aws sts get-caller-identity --profile \$p --query '[Account,Arn]' --output text; done"
echo "  3. ./scripts/deploy.sh all"
echo
echo "sso_role_name (許可セット名) が違う場合は env.local の SSO_PERMISSION_SET を直して再実行してください。"
echo "許可セット名は AWS アクセスポータルに表示されるロール名と同じです。"
echo
echo "元に戻す場合: cp $BACKUP $CONFIG"
