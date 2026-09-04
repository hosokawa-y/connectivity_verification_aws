# アカウント B に作成されたリソース一覧

`terraform/account-b` の apply で作成される 14 リソースの一覧と役割。

- 実機で確認した内容（2026-09-04 / ap-northeast-1 / 14 リソース作成完了）
- 実アカウント ID・API ID・ExternalId は伏せている（下記「実値の確認方法」参照）
- `<owner>` は `env.local` の `OWNER`。プレフィックスは `xacct-verify-<owner>-b-`

## 実値の確認方法

```bash
# 出力値まとめ（API URL、ロール ARN など）
terraform -chdir=terraform/account-b output

# ExternalId（機微。表示には -raw が必要）
terraform -chdir=terraform/account-b output -raw external_id

# 個々のリソースの全属性
terraform -chdir=terraform/account-b state list
terraform -chdir=terraform/account-b state show aws_lambda_function.echo
```

## リソース一覧（14 件）

| # | Terraform アドレス | AWS リソース | 名前 | 役割 |
|---|---|---|---|---|
| 1 | `aws_api_gateway_rest_api.this` | API Gateway REST API | `xacct-verify-<owner>-b-api` | API 本体。REGIONAL エンドポイント |
| 2 | `aws_api_gateway_resource.verify` | リソース（パス） | `/verify` | 検証用のパス |
| 3 | `aws_api_gateway_method.verify` | メソッド | `POST /verify` | **`authorization = AWS_IAM`**。本検証の核心 |
| 4 | `aws_api_gateway_integration.verify` | 統合 | `AWS_PROXY` | メソッドと Lambda を接続 |
| 5 | `aws_api_gateway_deployment.this` | デプロイ | — | 上記構成のスナップショット |
| 6 | `aws_api_gateway_stage.this` | ステージ | `dev` | デプロイを URL に紐付ける |
| 7 | `aws_lambda_function.echo` | Lambda 関数 | `xacct-verify-<owner>-b-echo` | 呼び出し元 ID を記録して返す |
| 8 | `aws_iam_role.echo` | IAM ロール | `xacct-verify-<owner>-b-echo-role` | 上記 Lambda の実行ロール |
| 9 | `aws_iam_role_policy_attachment.echo_basic` | ポリシーのアタッチ | — | `AWSLambdaBasicExecutionRole`（ログ出力権限） |
| 10 | `aws_cloudwatch_log_group.echo` | ロググループ | `/aws/lambda/xacct-verify-<owner>-b-echo` | 保持 7 日 |
| 11 | `aws_lambda_permission.apigw` | Lambda 呼び出し許可 | `AllowAPIGatewayInvoke` | API Gateway からの呼び出しのみ許可 |
| 12 | `aws_iam_role.cross_account` | IAM ロール | `xacct-verify-<owner>-b-invoke-api-role` | **アカウント A が AssumeRole する対象** |
| 13 | `aws_iam_role_policy.invoke_api` | インラインポリシー | `invoke-api` | 上記ロールに `execute-api:Invoke` を付与 |
| 14 | `random_uuid.external_id` | （AWS 外） | — | ExternalId を生成。AWS リソースではなく state 上の値 |

`data.*`（`aws_caller_identity` / `aws_iam_policy_document` / `archive_file`）は
参照のみでリソースを作らないため、この一覧には含めていない。

## リソースの関係

```
                 ① AssumeRole (+ ExternalId)
アカウント A ──────────────────────────> aws_iam_role.cross_account          [12]
                                            信頼ポリシー: A の root + 条件
                                            権限ポリシー: invoke-api         [13]
                                                 └─ execute-api:Invoke
                 ② SigV4 署名付き POST                    │
アカウント A ──────────────────────────>          ┌────────┘
                                                  ▼
                       aws_api_gateway_rest_api.this                         [1]
                         └─ aws_api_gateway_resource.verify  (/verify)       [2]
                              └─ aws_api_gateway_method.verify (POST)        [3]
                                   authorization = AWS_IAM  ← ここで認可
                                   └─ aws_api_gateway_integration.verify     [4]
                                        (AWS_PROXY)
                                            │
                       aws_api_gateway_deployment.this                       [5]
                         └─ aws_api_gateway_stage.this (dev)                 [6]
                              URL: https://<API_ID>.execute-api.<region>.amazonaws.com/dev/verify
                                            │
                                            ▼ ③ (aws_lambda_permission.apigw で許可) [11]
                       aws_lambda_function.echo                              [7]
                         ├─ aws_iam_role.echo                                [8]
                         │    └─ AWSLambdaBasicExecutionRole                 [9]
                         └─ aws_cloudwatch_log_group.echo                    [10]
```

## API Gateway の詳細

| 項目 | 値 |
|---|---|
| エンドポイントタイプ | `REGIONAL` |
| ステージ | `dev` |
| 呼び出し URL | `https://<API_ID>.execute-api.<region>.amazonaws.com/dev/verify` |
| メソッド | `POST` |
| 認可タイプ | `AWS_IAM` |
| API キー | 不要（`api_key_required = false`） |
| 統合タイプ | `AWS_PROXY`（Lambda プロキシ統合） |
| 統合の HTTP メソッド | `POST`（固定。クライアントが使うメソッドとは別物） |

`authorization = AWS_IAM` により、SigV4 署名がないリクエストと
`execute-api:Invoke` を持たない principal からのリクエストは **403** で拒否される。

## Lambda の詳細

| 項目 | 値 |
|---|---|
| 関数名 | `xacct-verify-<owner>-b-echo` |
| ランタイム | `python3.12` |
| ハンドラ | `echo_handler.handler` |
| ソース | `terraform/account-b/lambda/echo_handler.py`（`archive_file` で zip 化） |
| タイムアウト | 10 秒 |
| メモリ | 128 MB |
| 実行ロール | `xacct-verify-<owner>-b-echo-role` |

呼び出し元 principal（`userArn` / `accountId` / `caller` / `sessionName`）を
レスポンス本文と CloudWatch Logs の両方に出力する。

## IAM の詳細

### `xacct-verify-<owner>-b-echo-role`（Lambda 実行用）

- 信頼ポリシー: `lambda.amazonaws.com`
- 権限: `AWSLambdaBasicExecutionRole`（CloudWatch Logs への書き込みのみ）

### `xacct-verify-<owner>-b-invoke-api-role`（A から引き受けられる側）

信頼ポリシー（誰がこのロールになれるか）:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowAccountACallerRole",
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_A_ID>:root" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "ArnLike": {
        "aws:PrincipalArn": [
          "arn:aws:iam::<ACCOUNT_A_ID>:role/xacct-verify-<owner>-caller-role",
          "arn:aws:sts::<ACCOUNT_A_ID>:assumed-role/xacct-verify-<owner>-caller-role/*"
        ]
      },
      "StringEquals": { "sts:ExternalId": "<自動生成された UUID>" }
    }
  }]
}
```

`Principal` をアカウント A の `root` にしているのは、A 側のロールが未作成でも
このロールを作れるようにするため（IAM は信頼ポリシーに書いたロール ARN の実在を
作成時に検証し、無ければ `Invalid principal in policy` で拒否する）。
実際に許可される範囲は `aws:PrincipalArn` 条件で A の 1 ロールだけに絞っている。

権限ポリシー `invoke-api`（このロールが何をできるか）:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "InvokeVerifyEndpoint",
    "Effect": "Allow",
    "Action": "execute-api:Invoke",
    "Resource": "arn:aws:execute-api:<region>:<ACCOUNT_B_ID>:<API_ID>/dev/POST/verify"
  }]
}
```

対象は当該メソッド/パスの 1 つのみ。信頼ポリシーと権限ポリシーは別物で、
両方が揃わないと呼び出せない（信頼だけでは `403 no identity-based policy allows
the execute-api:Invoke action` になる）。

- `max_session_duration`: 3600 秒（実際の AssumeRole は 900 秒を要求している）

## タグ

全リソースに `default_tags` で以下が付く。

| キー | 値 |
|---|---|
| `Project` | `xacct-verify` |
| `Owner` | `env.local` の `OWNER` |
| `Component` | `account-b` |
| `ManagedBy` | `terraform` |

IAM ロールの `description` は ASCII しか受け付けないため英語。日本語の説明は
HCL のコメントとして残してある。

## 課金

| リソース | 課金 |
|---|---|
| IAM ロール / ポリシー | 無料 |
| API Gateway REST API | リクエスト課金のみ（検証では数リクエスト） |
| Lambda | 実行時間課金のみ（無料枠内） |
| CloudWatch Logs | 保存量課金。保持 7 日で自動削除 |

検証を続けない場合は削除する。

```bash
./scripts/destroy.sh b
# または
terraform -chdir=terraform/account-b destroy -var "profile=$PROFILE_B"
```
