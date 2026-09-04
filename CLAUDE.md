# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

ユーザーへの回答・説明・コミットメッセージなど、出力は全て日本語で行うこと。
コード内の識別子や既存ファイルの記述はこの限りではない。

## Rules

- **`git push` は禁止。** Claude はこのリポジトリで push を実行しないこと。
  リモートへの反映は必ずユーザーが手動で行う。ユーザーから明示的に依頼された場合も、
  コマンドを提示するだけにとどめ、自分では実行しない。
  `.claude/settings.json` の `permissions.deny` でもブロックしている。
- ローカルのコミット作成は、ユーザーから依頼された場合のみ行う。
- `terraform apply` / `destroy` は実アカウントに課金対象リソースを作るため、
  実行前に必ずユーザーの確認を取る。`plan` / `validate` / `fmt` は確認不要。

## このリポジトリの目的

アカウント A の Lambda → アカウント B の IAM ロールを AssumeRole → SigV4 署名付きで
アカウント B の API Gateway（IAM 認可）を呼び出す経路を実 AWS 上で検証する。

`doc/cross_acount_test.html` は前任者が 2026-09-03 に手作業検証した記録。
**このリポジトリはその記録の構成を Terraform で再現したもの**なので、構成を変える前に
必ず記録側の「解消したエラーの経緯」と「運用へ移す前の確認事項」を読むこと。
経路図・検証項目・記録の 5 エラーとの対応表は `README.md` にある。

この記録とスクリーンショットは実アカウント ID と外部共有 URL を含む社内限定資料なので
`.gitignore` 済み（ローカルにのみ存在）。リポジトリは将来公開される可能性があるため、
**実アカウント ID・SSO の URL・個人名をコミット対象のファイルに書かないこと。**
実値は `env.local`（.gitignore 済み）と `terraform/*/terraform.tfvars`（同）に置く。

`doc/learning-notes.md` は学習記録。ユーザーは GCP 経験者で AWS は今回が初めてなので、
AWS 固有の概念（ロールとポリシーの区別、AssumeRole、SigV4、ExternalId 等）を説明するときは
このファイルの内容と用語を揃える。新しく判明した AWS の挙動やつまずきは README ではなく
このファイルに追記する（ユーザーの明示的な指示）。

| | アカウント | プロファイル |
|---|---|---|
| A（呼び出す側） | account-a-profile | `account-a-profile` |
| B（呼び出される側） | account-b-profile | `account-b-profile` |

アカウント ID は A = 111111111111 / B = 222222222222。リージョンは `ap-northeast-1`。

**認証は `aws login`（コンソールセッション連携）で、同時に 1 アカウントしか保持できない。**
別アカウントにログインすると前のセッションが
`ValidationException: The provided authorization grant is invalid, expired, revoked, or malformed`
で失効し、`~/.aws/config` の全プロファイルの `login_session` が最新セッションを指す。
つまり **プロファイル名ではアカウントを区別できない**ので、判定は必ず
`aws sts get-caller-identity` の実アカウント ID で行う。

このため apply / destroy はアカウントごとに段階分割してある（`./scripts/deploy.sh b|a|all`）。
`aws login` はブラウザ認証を伴う対話コマンドなので Claude 側では実行できない。
セッション切れやアカウント切り替えが必要になったら、ユーザーに
`aws login --profile <name>` の実行を依頼する。

## コマンド

```bash
# 構文チェック（AWS 認証不要）
terraform fmt -recursive terraform/
terraform -chdir=terraform/account-b init -backend=false && terraform -chdir=terraform/account-b validate
terraform -chdir=terraform/account-a init -backend=false && terraform -chdir=terraform/account-a validate

# デプロイ（B -> A の順。要 AWS 認証）
# aws login は 1 アカウントしか保持できないので、間でログインし直す
./scripts/deploy.sh check           # apply せず認証とアカウント対応のみ確認
./scripts/deploy.sh b               # アカウント B にログイン中に実行
./scripts/deploy.sh a               # アカウント A にログイン中に実行
./scripts/deploy.sh all             # 両方の認証が同時に有効な場合のみ
./scripts/deploy.sh b -auto-approve # 確認なし

# 検証（Lambda を invoke して正常系 200 / 異常系 403 を判定）
./scripts/verify.sh

# 個別に invoke する場合
aws lambda invoke --profile account-a-profile \
  --function-name "$(terraform -chdir=terraform/account-a output -raw lambda_function_name)" \
  --cli-binary-format raw-in-base64-out --payload '{}' out/signed.json

# ログ
aws logs tail "$(terraform -chdir=terraform/account-a output -raw log_group_name)" \
  --profile account-a-profile --since 10m

# 後片付け（A -> B の順）
./scripts/destroy.sh a
./scripts/destroy.sh b
```

## 構成上の制約（変更時に壊しやすい点）

記録で実際に踏まれたエラーの再発防止が構成に埋め込まれている。以下は動かすと壊れる。

- **apply 順序は B → A で固定。** B の信頼ポリシーは principal をアカウント A の
  `root` にし、`aws:PrincipalArn` 条件で A の Lambda 実行ロールに限定している。
  信頼ポリシーに存在しないロール ARN を principal として直接書くと IAM が
  `Invalid principal` で拒否する（記録のエラー 1）。この形なら A 未作成でも B を
  apply できる。A の Lambda は B の API URL / ロール ARN / ExternalId を環境変数に
  必要とするので逆順にはできない。
- **`aws:PrincipalArn` 条件は 2 パターン許可。** ロール ARN 形式と assumed-role
  セッション ARN 形式の両方を `ArnLike` で許可（`terraform/account-b/main.tf` の
  `local.caller_principal_patterns`）。片方に絞ると環境によって通らなくなる。
- **ロール名の一致が必須。** `account-a` の `var.lambda_role_name` と `account-b` の
  `var.caller_role_name`（既定値はどちらも `xacct-verify-caller-role`）。
  片方だけ変えると AssumeRole が `AccessDenied` になる。
- **署名リージョン `var.api_region` は関数自身のリージョンと別変数。** 呼び出し先 API の
  リージョンを使う。統合すると記録のエラー 3（`403 Credential should be scoped to a
  valid region`）を再発させる。記録では 2 度躓いた箇所。
- **A のロールに API 呼び出し権限は付けない。** `execute-api:Invoke` は B 側のロールが
  持つ。A 側は対象ロール 1 つへの `sts:AssumeRole` のみ。信頼と権限は別物
  （記録のエラー 4）。
- **ハンドラ設定とコードの関数名を対応させる。** `handler = "<file>.handler"` /
  `def handler`（記録のエラー 2）。
- **ExternalId は B 側で `random_uuid` 生成 → `account_a_tfvars` 出力経由で A に渡す。**
  両側に別々に書くとずれて `AccessDenied` になる。
- **署名は Lambda ランタイム同梱の botocore（`SigV4Auth`）で行う。** 外部依存を
  追加すると zip のバンドルが必要になり、`archive_file` 1 つで済む今の構成が崩れる。
- **`terraform/account-a/terraform.tfvars` は `scripts/deploy.sh` が自動生成する**
  （B の `account_a_tfvars` 出力から）。手で編集しても次回 deploy で上書きされる。
  ExternalId を含むので中身をログや標準出力に出さない。

## 検証の観測ポイント

`scripts/verify.sh` → `scripts/assert_result.py` が記録の「検証結果」と同じ項目を
突き合わせる（10 項目、詳細は README の表）。Lambda
（`terraform/account-a/lambda/caller_handler.py`）は 1 レスポンスに以下を詰めて返すので、
どの段で失敗したか切り分けられる。

- `callerIdentityBeforeAssume` … A の Lambda 実行ロール
- `assumedRoleUser` / `callerIdentityAfterAssume` … B の assumed-role に切り替わったか
- `signedHeaderNames` … `authorization` / `x-amz-date` / `x-amz-security-token`
- `apiResponse.statusCode` … 200 なら経路成立
- `apiResponse.body.caller` … B 側が観測した呼び出し元（`userArn` / `accountId` /
  `caller`（AROA 始まり）/ `sessionName` / `authenticated`）
- `apiResponse.body.request.receivedBody` … 送信本文が届いたか（ペイロードハッシュ検証）
- `config.regionInUrl` と `config.signingRegion` の不一致時は `warning` を返す

invoke 時のイベントで挙動を変えられる。

- `{"skip_signing": true}` … 署名なしで呼び、403 を確認
- `{"role_session_name": "..."}` … B 側に現れるセッション名を変える
- `{"payload": {...}}` … 送信する JSON 本文を変える

ステータスコードによる切り分け（記録より）。

| 症状 | 意味 |
|---|---|
| 403 `Credential should be scoped to a valid region` | 署名リージョンが呼び出し先と不一致 |
| 403 `no identity-based policy allows the execute-api:Invoke action` | B 側ロールに権限ポリシーがない |
| 403 `Missing Authentication Token` | 署名なし / メソッド・パス不一致 |
| 502 `Internal server error` | 認可は通過済み。B 側 Lambda の実装かハンドラ設定 |
