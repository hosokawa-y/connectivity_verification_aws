#!/usr/bin/env bash
# doc/sts-experiments.md の実験で使う変数を用意する。
#
# 使い方 (実行ではなく source する):
#   source ./scripts/exp-env.sh
#
# シェル変数はコマンドごとに別シェルだと引き継がれないため、
# 1 コマンドずつ実行する場合は各コマンドの先頭でこれを source する:
#   source ./scripts/exp-env.sh && aws sts get-caller-identity --profile "$PROFILE_A"

if [[ ! -f env.local ]]; then
  echo "エラー: env.local がありません。cp env.local.example env.local を実行してください。" >&2
  return 1 2>/dev/null || exit 1
fi

set -a
# shellcheck disable=SC1091
source ./env.local
set +a

AWS_RESOURCE_REGION=${AWS_RESOURCE_REGION:-ap-northeast-1}

FUNC=$(terraform -chdir=terraform/account-a output -raw lambda_function_name 2>/dev/null)
# ${...} で囲まないと zsh が :role を修飾子として解釈して ARN が壊れる
ROLE_ARN="arn:aws:iam::${ACCOUNT_B_ID}:role/xacct-verify-${OWNER}-b-invoke-api-role"

mkdir -p out

if [[ -z "$FUNC" ]]; then
  echo "警告: Lambda 関数名を取得できません。terraform/account-a の apply が未完了かもしれません。" >&2
fi
