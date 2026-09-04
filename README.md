# connectivity_verification_aws

アカウント A の Lambda から、アカウント B の IAM ロールを AssumeRole し、
SigV4 署名付きでアカウント B の API Gateway（IAM 認可）を呼び出す経路を、
実際の AWS アカウント上で検証する。

前任者が手作業で成立を確認した構成（2026-09-03、別リージョン）を、Terraform で
再現・自動検証できるようにしたもの。元の検証記録 `doc/cross_acount_test.html` は
実アカウント ID を含む社内限定資料のため**リポジトリには含めていない**（`.gitignore` 済み）。
記録から得た知識は `doc/learning-notes.md` に転記してある。

| | アカウント | AWS CLI プロファイル |
|---|---|---|
| A（呼び出す側） | account-a-profile | `account-a-profile` |
| B（呼び出される側） | account-b-profile | `account-b-profile` |

リージョンは `ap-northeast-1`。プロファイル名・リージョンは Terraform 変数で変更可能。

## 検証する経路

```
┌─ アカウント A ────────────────┐   ┌─ アカウント B ─────────────────────────┐
│                               │   │                                        │
│  Lambda                       │   │  IAM ロール                            │
│  xacct-verify-a-caller        │   │  xacct-verify-b-invoke-api-role        │
│  python / boto3 + SigV4Auth   │   │    信頼: A の root                     │
│    │                          │   │      + 条件 aws:PrincipalArn           │
│    │ ① sts:AssumeRole ────────┼───┼──>   + 条件 sts:ExternalId             │
│    │    + ExternalId          │   │    権限: execute-api:Invoke            │
│    │ <── ② 一時認証情報 ──────┼───┼──         (POST /dev/verify のみ)      │
│    │       (15 分)            │   │                                        │
│    │                          │   │  API Gateway (REST / REGIONAL)         │
│    │ ③ SigV4 署名付き HTTPS   │   │  POST /dev/verify                      │
│    └──────────────────────────┼───┼──> 認可タイプ: AWS_IAM                 │
│                               │   │        │                               │
│  実行ロール                   │   │        └─> ④ Lambda                    │
│  xacct-verify-caller-role     │   │            xacct-verify-b-echo         │
│    権限: sts:AssumeRole       │   │            呼び出し元 ID を記録して返す│
│          (B のロール 1 つのみ)│   │                                        │
└───────────────────────────────┘   └────────────────────────────────────────┘

B 側で観測される呼び出し元:
  arn:aws:sts::<B>:assumed-role/xacct-verify-b-invoke-api-role/xacct-verify-a-caller
  accountId は B。A の ID は現れない。
```

`scripts/verify.sh` が自動判定する項目:

| # | 確認内容 | 期待値 |
|---|---|---|
| 1 | AssumeRole 前の principal | A の Lambda 実行ロール |
| 2 | AssumeRole 後の principal | B の assumed-role |
| 3 | 署名ヘッダ | `authorization` / `x-amz-date` / `x-amz-security-token` |
| 4 | 署名ありの HTTP ステータス | **200** |
| 5 | B 側 `authenticated` | `true`（AWS_IAM 認可が効いている） |
| 6 | B 側 `accountId` | B のアカウント ID（A の ID は現れない） |
| 7 | B 側 `caller` | `AROA` 始まり（ロール由来の一時認証情報である証跡） |
| 8 | B 側 `sessionName` | A 側の `RoleSessionName` がそのまま現れる |
| 9 | 本文の到達 | 送信した JSON と一致（ペイロードハッシュ検証を通過） |
| 10 | 署名なしの HTTP ステータス | **403** |

## 記録で踏んだ 5 件のエラーへの対策

`doc/cross_acount_test.html` で解消されたエラーを、構成側で踏まないようにしている。

| # | 記録上のエラー | このリポジトリでの対策 |
|---|---|---|
| 1 | `Invalid principal in policy`（信頼ポリシーに未作成の A 側ロール ARN を指定） | 記録では「A を先に作る」で解消。ここでは principal を **A の root** にし `aws:PrincipalArn` 条件でロールを限定。A 未作成でも B を apply できるため、Terraform の適用順を B → A に固定できる（A の Lambda は B の API URL を必要とするので逆順にはできない） |
| 2 | `Runtime.HandlerNotFound`（ハンドラ設定とコードの関数名が不一致） | `handler = "<file>.handler"` と `def handler` を対応させ、`archive_file` で単一ファイルを固定 |
| 3 | `403 Credential should be scoped to a valid region`（署名リージョンが呼び出し先と違う） | 署名リージョンを `var.api_region` として**関数自身のリージョンと分離**。B の `api_region` 出力をそのまま A に渡す。実行時に URL 内のリージョンと突き合わせて不一致なら警告も返す |
| 4 | `403 no identity-based policy allows the execute-api:Invoke action`（信頼だけで権限がない） | B 側ロールに `execute-api:Invoke` のインラインポリシーを付与。対象は当該メソッド/パスのみ |
| 5 | `502 Internal server error`（B 側 Lambda の実装エラー） | B 側ハンドラは例外を出さない実装にし、`verify.sh` が 502 を「認可は通過済み・実装の問題」と切り分けて表示 |

## 設計上のポイント

- **API 呼び出し権限は B 側のロールが持つ。** A の実行ロールに与えるのは
  `sts:AssumeRole`（対象は B のロール 1 つのみ）だけ。
- **ロール名は固定。** `account-a` の `lambda_role_name` と `account-b` の
  `caller_role_name` は一致させる必要がある（既定値は同じ）。
- **ExternalId は B 側で自動生成**（`random_uuid`）し、`account_a_tfvars` 出力経由で
  A に渡すので両側の値がずれない。固定値にしたい場合は B の `var.external_id` を指定する。
- **署名は botocore の `SigV4Auth`。** Lambda ランタイム同梱の boto3/botocore で
  完結するので依存パッケージのバンドルは不要。
- **メソッドは POST（本文あり）。** SigV4 のペイロードハッシュ検証も経路に含める。

## 手順

### 1. 実値を env.local に設定

実アカウント ID・SSO の URL・プロファイル名はコミット対象のファイルには書かない
（リポジトリが公開される可能性があるため）。すべて `env.local` に集約する。

```bash
cp env.local.example env.local
# ACCOUNT_A_ID / ACCOUNT_B_ID / PROFILE_A / PROFILE_B / OWNER / SSO_* を設定
```

| 変数 | 意味 |
|---|---|
| `ACCOUNT_A_ID` | 呼び出す側。開発メンバー共有の検証環境 |
| `ACCOUNT_B_ID` | 呼び出される側。各自の AWS アカウント |
| `OWNER` | リソースの作成者識別子（下記「複数メンバーでの利用」） |
| `SSO_*` | IAM Identity Center の設定（`scripts/setup-sso.sh` が使う） |

Terraform 側にも B 用の tfvars が必要（こちらも `.gitignore` 済み）。

```bash
cp terraform/account-b/terraform.tfvars.example terraform/account-b/terraform.tfvars
# account_a_id と owner を設定する
```

### 2. 認証（2 アカウント分を同時に用意する）

`aws login`（コンソールセッション連携）は **同時に 1 つのセッションしか保持できない**。
別アカウントにログインすると前のセッションが失効し、`~/.aws/config` の全プロファイルが
最新セッションを指すため、プロファイル名でアカウントを区別できなくなる。

そのため IAM Identity Center の SSO プロファイルを使う。1 回のログインで、
許可された全アカウント分の認証情報が同時に有効になる。

```bash
./scripts/setup-sso.sh                      # ~/.aws/config に SSO プロファイルを書く
aws sso login --sso-session verify-sso      # 1 回で両アカウント有効
```

確認:

```bash
source ./env.local
for p in "$PROFILE_A" "$PROFILE_B"; do
  aws sts get-caller-identity --profile "$p" --query '[Account,Arn]' --output text
done
```

別々のアカウント ID が 2 行出れば準備完了。詳細と背景は `doc/learning-notes.md` の
「認証: `aws login` は同時に 1 アカウントしか保持できない」を参照。

### 3. デプロイ

SSO で両アカウントが同時に有効なら一括で実行できる（B → A の順に apply される）。

```bash
./scripts/deploy.sh check   # apply せず、アカウント対応だけ確認
./scripts/deploy.sh all     # B -> A の順に apply
```

`aws login` など 1 アカウントずつしか認証できない場合は段階実行する。
各段は自分のアカウントの認証情報だけで完結する。

```bash
./scripts/deploy.sh b   # アカウント B にログイン中
./scripts/deploy.sh a   # アカウント A にログイン中
```

各段の冒頭で「今ログインしているアカウントが正しいか」を実アカウント ID で検証し、
取り違えていればその場で止まる。`stage` の後ろに `-auto-approve` などを渡せる。

### 4. 検証

```bash
./scripts/verify.sh   # アカウント A の認証が必要
```

正常系（署名あり）と異常系（署名なし）を invoke し、上表 10 項目を突き合わせる。
すべて期待通りなら終了コード 0。失敗時は API のレスポンス本文と、記録にある
よくある原因を併せて表示する。

### 5. 後片付け

作成と逆順（A → B）。逐次ログインの場合は間でログインし直す。

```bash
./scripts/destroy.sh a   # アカウント A にログイン中
./scripts/destroy.sh b   # アカウント B にログイン中
# 同時に有効なら ./scripts/destroy.sh all
```

## ディレクトリ構成

```
env.local.example        実値のテンプレート。cp して env.local を作る（env.local は .gitignore 済み）
doc/learning-notes.md    学習記録。GCP 経験者向けの用語対応、つまずいた点の整理
doc/cross_acount_test.html  前回の手作業検証の記録。社内限定資料のため .gitignore 済み（ローカルのみ）
terraform/account-b/     先に apply。API Gateway (IAM 認可) + バックエンド Lambda + AssumeRole される側のロール
terraform/account-a/     後に apply。呼び出し元 Lambda + 実行ロール
scripts/setup-sso.sh     ~/.aws/config に SSO プロファイルを設定（env.local を読む）
scripts/deploy.sh        apply (stage: b / a / all)。B の出力を A の tfvars に反映
scripts/verify.sh        Lambda を invoke して正常系/異常系を判定
scripts/assert_result.py verify.sh が使う期待値突き合わせ
scripts/destroy.sh       destroy (stage: a / b / all)
```

## 運用へ移す前の確認事項

`doc/cross_acount_test.html` の指摘をそのまま引き継ぐ。

- **`sourceIp` による制限はできない。** Lambda の送信元 IP は固定されない。
  呼び出し元を絞るなら `aws:PrincipalArn` 等の条件を使う（本構成では使用済み）。
- **ExternalId の保管場所。** 現状は Lambda 環境変数に平文。本番運用では
  SSM Parameter Store / Secrets Manager へ移す。
- **`RoleSessionName` に識別子を入れる。** 記録では固定値だったため B 側で呼び出し元を
  区別できなかった。本構成では `owner` から `<owner>-verify` を導出して対応済み。
  invoke 時の `role_session_name` でも上書きできる。
- **ExternalId はイベントに載らない。** AssumeRole の時点で消費される条件なので、
  B 側 Lambda で受け取ることはできない。
- **本番実装では AssumeRole 結果をキャッシュする。** 本検証では経路全体を毎回通すため
  invoke ごとに AssumeRole している。

## 注意

- **コミット対象のファイルに実値を書かない。** リポジトリは将来公開される可能性がある。
  実アカウント ID・SSO の URL・プロファイル名・個人名は `env.local` と
  `terraform/*/terraform.tfvars`（どちらも `.gitignore` 済み）に置く。
  ドキュメント中の ID（`111111111111` 等）とプロファイル名はすべてダミー値。
- Terraform の state はローカル（`terraform.tfstate`）。`.gitignore` 済み。
  ExternalId が含まれるのでコミットしないこと。
- `scripts/verify.sh` の出力先 `out/` も `.gitignore` 済み。
  一時認証情報のアクセスキー ID（`AROA...`）が含まれる。
- 前回の検証記録（`doc/*.html` と `doc/*.png`）は実アカウント ID と外部共有 URL を
  含むため `.gitignore` 済み。知識は `doc/learning-notes.md` に転記してある。
