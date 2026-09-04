#!/usr/bin/env bash
# アカウント A の Lambda を invoke して経路を検証する。
#
#   ケース1 (正常系): AssumeRole + ExternalId -> SigV4 署名 -> B の API  => 200
#   ケース2 (異常系): 署名なしで B の API を呼ぶ                        => 403
#
# 最後に doc/cross_acount_test.html の「検証結果」と同じ観測項目を突き合わせる。
# 全項目 OK なら終了コード 0。
#
# 事前条件: scripts/deploy.sh が完了していること
set -euo pipefail

cd "$(dirname "$0")/.."

A_DIR=terraform/account-a
B_DIR=terraform/account-b
OUT_DIR=out
mkdir -p "$OUT_DIR"

# プロファイル / リージョン / 関数名は terraform の出力から取る
PROFILE=${PROFILE_A:-$(terraform -chdir="$A_DIR" output -raw profile)}
REGION=$(terraform -chdir="$A_DIR" output -raw region)
FUNCTION=$(terraform -chdir="$A_DIR" output -raw lambda_function_name)

# 期待値の突き合わせに使う B 側の情報
EXPECTED_ACCOUNT_B=$(terraform -chdir="$B_DIR" output -raw account_b_id)
EXPECTED_ROLE_NAME=$(terraform -chdir="$B_DIR" output -raw target_role_name)
EXPECTED_SESSION_NAME=$(terraform -chdir="$A_DIR" output -raw role_session_name)
EXPECTED_LAMBDA_ROLE=$(terraform -chdir="$A_DIR" output -raw lambda_role_name)

invoke() {
  local label=$1 payload=$2 outfile=$3

  echo "================================================================"
  echo "$label"
  echo "  function : $FUNCTION"
  echo "  payload  : $payload"
  echo "================================================================"

  aws lambda invoke \
    --profile "$PROFILE" \
    --region "$REGION" \
    --function-name "$FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    "$outfile" >/dev/null

  python3 -m json.tool "$outfile"
  echo
}

invoke "ケース1: AssumeRole + SigV4 署名あり (期待: 200)" '{}' "$OUT_DIR/signed.json"
invoke "ケース2: 署名なし (期待: 403)" '{"skip_signing":true}' "$OUT_DIR/unsigned.json"

echo "================================================================"
echo "判定"
echo "================================================================"
python3 scripts/assert_result.py \
  --signed "$OUT_DIR/signed.json" \
  --unsigned "$OUT_DIR/unsigned.json" \
  --account-b "$EXPECTED_ACCOUNT_B" \
  --role-name "$EXPECTED_ROLE_NAME" \
  --session-name "$EXPECTED_SESSION_NAME" \
  --lambda-role-name "$EXPECTED_LAMBDA_ROLE"
