# アカウント A に作成されたリソース一覧

`terraform/account-a` の apply で作成される 5 リソースの一覧と役割。

- 実機で確認した内容（2026-09-04 / ap-northeast-1 / 5 リソース作成完了）
- 実アカウント ID・ExternalId は伏せている（下記「実値の確認方法」参照）
- `<owner>` は `env.local` の `OWNER`

**アカウント A は開発メンバー共有の検証環境。** 他メンバーも同じアカウント A に
自分のリソースを作るため、名前とタグに `<owner>` を入れて衝突と混同を防いでいる。
IAM ロール名はアカウント内で一意でなければならないので、これは必須の措置。

アカウント B 側のリソースは `account-b-resources.md` を参照。

## 実値の確認方法

```bash
terraform -chdir=terraform/account-a output
terraform -chdir=terraform/account-a state list
terraform -chdir=terraform/account-a state show aws_lambda_function.caller
```

## リソース一覧（5 件）

| # | Terraform アドレス | AWS リソース | 名前 | 役割 |
|---|---|---|---|---|
| 1 | `aws_iam_role.caller` | IAM ロール | `xacct-verify-<owner>-caller-role` | Lambda の実行ロール。**B 側の信頼ポリシーがこの名前を条件に指定している** |
| 2 | `aws_iam_role_policy.assume_target_role` | インラインポリシー | `assume-account-b-role` | B のロール 1 つへの `sts:AssumeRole` のみ |
| 3 | `aws_iam_role_policy_attachment.caller_basic` | ポリシーのアタッチ | — | `AWSLambdaBasicExecutionRole`（ログ出力権限） |
| 4 | `aws_lambda_function.caller` | Lambda 関数 | `xacct-verify-<owner>-a-caller` | AssumeRole して SigV4 署名で B の API を呼ぶ |
| 5 | `aws_cloudwatch_log_group.caller` | ロググループ | `/aws/lambda/xacct-verify-<owner>-a-caller` | 保持 7 日 |

`data.*`（`aws_caller_identity` / `aws_iam_policy_document` / `archive_file`）は
参照のみでリソースを作らないため一覧に含めていない。

B 側が 14 リソースに対して A 側が 5 リソースなのは、**API 呼び出しの権限を A 側に
持たせていない**ため。A が持つのは「B のロールになる権限」だけで、
`execute-api:Invoke` は B のロールが持つ。

## リソースの関係

```
アカウント A                                          アカウント B
─────────────────────────────────────────           ──────────────────────

aws_lambda_function.caller                    [4]
  xacct-verify-<owner>-a-caller
    │
    ├─ 実行ロール
    │   aws_iam_role.caller                    [1]
    │     xacct-verify-<owner>-caller-role
    │       ├─ AWSLambdaBasicExecutionRole     [3]
    │       └─ assume-account-b-role           [2]
    │            sts:AssumeRole ───────────────────> xacct-verify-<owner>-b-invoke-api-role
    │            (対象は B のロール 1 つのみ)          信頼ポリシーが [1] の名前を条件に指定
    │                                                        │
    ├─ 環境変数                                               │ 一時認証情報
    │   TARGET_ROLE_ARN    B のロール ARN  <──────────────────┘
    │   TARGET_API_URL     B の API URL
    │   API_REGION         署名リージョン
    │   HTTP_METHOD        POST
    │   ROLE_SESSION_NAME  <owner>-verify
    │   EXTERNAL_ID        AssumeRole の条件
    │
    ├─ SigV4 署名して呼び出し ────────────────────> API Gateway POST /dev/verify
    │                                                 authorization = AWS_IAM
    │
    └─ ログ
        aws_cloudwatch_log_group.caller        [5]
```

## Lambda の詳細

| 項目 | 値 |
|---|---|
| 関数名 | `xacct-verify-<owner>-a-caller` |
| ランタイム | `python3.12` |
| ハンドラ | `caller_handler.handler` |
| ソース | `terraform/account-a/lambda/caller_handler.py`（`archive_file` で zip 化） |
| タイムアウト | 30 秒 |
| メモリ | 128 MB |
| 実行ロール | `xacct-verify-<owner>-caller-role` |

B 側の Lambda（10 秒）より長いのは、1 回の invoke で AssumeRole →
STS での principal 確認 → API 呼び出しを順に行うため。

外部依存パッケージは無し。SigV4 署名は Lambda ランタイム同梱の
botocore（`SigV4Auth`）で行うので、zip は単一ファイル（約 3 KB）で済む。

### 環境変数

| キー | 内容 |
|---|---|
| `TARGET_ROLE_ARN` | AssumeRole する B のロール ARN |
| `TARGET_API_URL` | 呼び出す B の API エンドポイント |
| `API_REGION` | **SigV4 の署名リージョン。** 呼び出し先 API のリージョンで、この関数自身のリージョン（`AWS_REGION`）とは別物 |
| `HTTP_METHOD` | `POST` |
| `ROLE_SESSION_NAME` | `<owner>-verify`。B 側の呼び出し元 ARN 末尾に現れる |
| `EXTERNAL_ID` | AssumeRole 時に渡す共有シークレット（値は伏せる） |

`API_REGION` を独立した変数にしているのは、署名リージョンの取り違えが
`403 Credential should be scoped to a valid region` を招くため。詳細は
`learning-notes.md` の SigV4 の節。

`EXTERNAL_ID` は現状 Lambda 環境変数に平文。本番運用では
SSM Parameter Store / Secrets Manager へ移す。

## IAM の詳細

### `xacct-verify-<owner>-caller-role`

信頼ポリシー（誰がこのロールになれるか）:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Principal": { "Service": "lambda.amazonaws.com" }
  }]
}
```

Lambda サービスがこのロールを引き受けて関数を実行する。これは AWS で
Lambda を作るときの定型で、クロスアカウントの話とは別。

権限ポリシー `assume-account-b-role`（このロールが何をできるか）:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AssumeAccountBRole",
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": "arn:aws:iam::<ACCOUNT_B_ID>:role/xacct-verify-<owner>-b-invoke-api-role"
  }]
}
```

加えて `AWSLambdaBasicExecutionRole`（CloudWatch Logs への書き込み）をアタッチ。

**`execute-api:Invoke` は含まれていない。** A 側は「B のロールになる」ことしかできず、
API を叩く権限は AssumeRole 後に B のロールから得る。これが本検証の確認対象。

- `max_session_duration`: 3600 秒

### ロール名が固定である理由

B 側の信頼ポリシーは、A 側のこのロール名を `aws:PrincipalArn` 条件で参照している。

```
"aws:PrincipalArn": [
  "arn:aws:iam::<ACCOUNT_A_ID>:role/xacct-verify-<owner>-caller-role",
  "arn:aws:sts::<ACCOUNT_A_ID>:assumed-role/xacct-verify-<owner>-caller-role/*"
]
```

そのため両側で同じ式（`${project}-${owner}-caller-role`）から導出しており、
`project` と `owner` は B の `account_a_tfvars` 出力経由で A に自動的に渡る。
片方だけ名前を変えると AssumeRole が `AccessDenied` になる。

## タグ

| キー | 値 |
|---|---|
| `Project` | `xacct-verify` |
| `Owner` | `env.local` の `OWNER` |
| `Component` | `account-a` |
| `ManagedBy` | `terraform` |

共有アカウントなので `Owner` タグで作成者を特定できるようにしている。
IAM ロールの `description` は ASCII しか受け付けないため英語。

## 課金

| リソース | 課金 |
|---|---|
| IAM ロール / ポリシー | 無料 |
| Lambda | 実行時間課金のみ（無料枠内） |
| CloudWatch Logs | 保存量課金。保持 7 日で自動削除 |

## 削除

作成と逆順（A → B）で削除する。

```bash
./scripts/destroy.sh a
./scripts/destroy.sh b
```

**共有アカウントなので、削除対象が自分の `<owner>` のリソースだけであることを
destroy の plan で必ず確認する。**
