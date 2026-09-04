# 学習記録: GCP 経験者が AWS のクロスアカウント検証で理解したこと

普段 GCP を触っている前提で、本リポジトリの検証（アカウント A の Lambda →
アカウント B のロールを AssumeRole → SigV4 署名で B の API Gateway を呼ぶ）を
理解するために必要だった知識をまとめる。

- 検証の構成・手順そのものは `../README.md`
- 前任者による手作業検証の記録 `cross_acount_test.html` は実アカウント ID を含む
  社内限定資料のためリポジトリには含めていない（ローカルにのみ存在）

---

## 1. 用語の対応（GCP → AWS）

| GCP | AWS | 注意点 |
|---|---|---|
| プロジェクト | **アカウント** | リソースと課金の分離単位。GCP で「開発者ごとにプロジェクトを作る」ところが、AWS では「アカウントを作る」に相当する |
| 組織 / フォルダ | Organizations / OU | 階層構造の考え方は近い |
| ラベル | **タグ** | ほぼ同じ。本リポジトリの `Owner=yourname` はこれ |
| サービスアカウント | **IAM ロール** | 人ではないものに与える ID。AWS のロールは「誰かが引き受ける（assume）」形で使う |
| IAM ロール（権限の束） | **IAM ポリシー** | ★用語が逆転している。下記 2 節を必ず読むこと |
| サービスアカウントの権限借用（impersonation） | **AssumeRole**（STS） | 本検証の中心 |
| SA に付ける `roles/iam.serviceAccountTokenCreator` | ロールの**信頼ポリシー** | 「誰がこの ID になりきれるか」の定義 |
| ID トークン / アクセストークンを Bearer ヘッダで送る | **SigV4 署名** | 方式が根本的に違う。下記 4 節 |
| Cloud Run の IAM invoker | API Gateway の **`AWS_IAM` 認可** | 「IAM で認可された呼び出し元だけ通す」点は同じ |
| Cloud Functions / Cloud Run | **Lambda** | |
| Cloud Logging | **CloudWatch Logs** | |
| Cloud Audit Logs | **CloudTrail** | |
| （なし） | **ExternalId** | 下記 5 節 |

## 2. 最初に引っかかる罠: 「ロール」の意味が GCP と逆

これを取り違えると IAM の議論が全部ずれる。

**GCP**
- ロール = 権限の束（`roles/run.invoker` など）
- プリンシパル（ユーザー / サービスアカウント）に**ロールを付与**する

**AWS**
- **ロール = 引き受けられる ID そのもの**（GCP のサービスアカウントに近い）
- 権限の束は**ポリシー**と呼び、ロールにポリシーを付ける

つまり AWS のロールには 2 種類のポリシーがぶら下がる。

```
IAM ロール xacct-verify-yourname-b-invoke-api-role
  ├─ 信頼ポリシー (assume role policy)  … 「誰がこのロールになれるか」
  │    → アカウント A の xacct-verify-yourname-caller-role だけ
  └─ 権限ポリシー (identity-based policy) … 「このロールは何ができるか」
       → execute-api:Invoke（対象は POST /dev/verify の 1 つだけ）
```

**この 2 つは完全に別物。** 前任者の記録のエラー 4
（`403 no identity-based policy allows the execute-api:Invoke action`）は
まさに「信頼ポリシーは書いたが権限ポリシーを付けていなかった」ケース。
GCP だと「SA に invoker ロールを付与」の 1 手で済むところが、AWS では
「なりきる許可」と「できることの許可」を別々に書く必要がある。

## 3. AssumeRole すると「自分が誰か」が変わる

`sts:AssumeRole` は、別アカウントのロールの**一時認証情報**（15 分〜1 時間）を受け取る操作。
受け取った後は、その認証情報を使う限り自分の principal がロール側に切り替わる。

```
AssumeRole 前  arn:aws:sts::111111111111:assumed-role/xacct-verify-yourname-caller-role/...
                    ↑ アカウント A（Lambda 実行ロール）
AssumeRole 後  arn:aws:sts::222222222222:assumed-role/xacct-verify-yourname-b-invoke-api-role/yourname-verify
                    ↑ アカウント B。A のアカウント ID はもう現れない
```

呼び出される B 側から見ると、**呼び出し元は「B 自身のロール」に見える。**
A のアカウント ID は API Gateway のログにも出てこない。ここが理解の要点で、
「A から呼ばれた」という情報を B 側で残したいなら、`RoleSessionName`
（上記 ARN 末尾の `yourname-verify`）に識別子を入れる必要がある。

一時認証情報の識別子（`caller`）の先頭 3 文字で由来が分かる。

- `AROA...` … ロール由来の一時認証情報（今回はこれになるべき）
- `AIDA...` … IAM ユーザーの直呼び

## 4. SigV4 署名は Bearer トークンと違う

GCP は「トークンを取得して `Authorization: Bearer <token>` で送る」。
AWS の SigV4 は「**リクエストの内容から署名を計算して送る**」方式で、署名対象に以下が含まれる。

- HTTP メソッドとパス
- ヘッダ
- **リクエスト本文のハッシュ**
- **リージョン**
- **サービス名**（今回は `execute-api`）

そのため、署名時に指定するリージョンが呼び出し先 API のリージョンと違うと
`403 Credential should be scoped to a valid region` で弾かれる。
記録では 2 度躓いた箇所で、原因は「Lambda 自身のリージョン」を署名に使っていたこと。

本リポジトリでは対策として、署名リージョンを `var.api_region` として
関数自身のリージョンとは別変数に分離している。

```python
# terraform/account-a/lambda/caller_handler.py（抜粋）
request = AWSRequest(method="POST", url=API_URL, data=body, headers={...})
SigV4Auth(credentials, "execute-api", API_REGION).add_auth(request)
#                       ^service        ^呼び出し先 API のリージョン
```

署名の結果として付くヘッダは 3 つ。検証ではこれを確認している。

- `authorization` … 署名本体
- `x-amz-date` … 署名の時刻（ずれると失効）
- `x-amz-security-token` … 一時認証情報を使うときに必要

## 5. ExternalId とは（GCP に対応物がない）

AssumeRole 時に要求できる共有シークレット。**confused deputy 問題**への対策。

信頼ポリシーで「アカウント A から来てよい」と書くと、A の中の誰かが
（意図しない経路で）このロールを使えてしまう余地が残る。ExternalId を条件に加えると、
その値を知っている呼び出し元だけに絞れる。

注意点（記録より）:
- ExternalId は AssumeRole の時点で消費されるので、**B 側の Lambda では受け取れない**
- 本番運用では環境変数の平文ではなく SSM Parameter Store / Secrets Manager に置く

本リポジトリでは B 側で `random_uuid` で自動生成し、Terraform の出力経由で A に渡している
（両側に手で書くと値がずれて `AccessDenied` になるため）。

## 6. `owner` 変数は AWS の機能ではない

AWS には「このリソースを誰が作ったか」を示す標準フィールドがない
（CloudTrail を追えば分かるが、コンソールの一覧では見えない）。

さらに **IAM ロール名はアカウント内で一意**でなければならない。今回アカウント A は
開発メンバー共有の検証環境なので、全員が同じ名前でロールを作ると衝突する。

```
# owner なし → 2 人目の apply が EntityAlreadyExists で失敗する
#              （さらに悪いのは、片方の destroy で他人の検証が壊れること）
xacct-verify-caller-role

# owner あり → 共存できる
xacct-verify-yourname-caller-role
xacct-verify-tanaka-caller-role
```

そこで `var.owner` を導入し、リソース名・タグ・`RoleSessionName` の 3 か所に反映している。
GCP でラベルを付けて誰のリソースか分かるようにする運用と同じ発想。

## 7. 認証: `aws login` は同時に 1 アカウントしか保持できない

本検証で最も時間を取られた箇所。GCP の `gcloud auth login` +
`gcloud config configurations` のような感覚で複数アカウントを並行して持てると考えると詰まる。

**実測した挙動**（2026-09-04）

`aws login`（AWS CLI v2 のコンソールセッション連携）は、ブラウザのコンソールセッションと
紐づく方式。別アカウントにログインすると前のセッションが失効する。

```
$ aws sts get-caller-identity --profile default
An error occurred (ValidationException) ... The provided authorization grant is
invalid, expired, revoked, or malformed
```

さらに `~/.aws/config` の全プロファイルの `login_session` が最新セッションを指すため、
**プロファイル名でアカウントを区別できなくなる**。実際、A / B 用に用意した 2 つの
プロファイルが両方とも同じアカウントを返す状態になった。

**解決: IAM Identity Center の SSO プロファイルに移行**

SSO なら 1 回のログインで、許可された全アカウント分の認証情報を同時に発行できる。
GCP の `gcloud auth login` 1 回で複数プロジェクトを触れる感覚に近い。

```ini
# ~/.aws/config
[sso-session verify-sso]
sso_start_url = https://example.awsapps.com/start
sso_region = us-west-2
sso_registration_scopes = sso:account:access

[profile account-a-profile]      # アカウント A
sso_session = verify-sso
sso_account_id = 111111111111
sso_role_name = YourPermissionSet
region = ap-northeast-1

[profile account-b-profile]                # アカウント B
sso_session = verify-sso
sso_account_id = 222222222222
sso_role_name = YourPermissionSet
region = ap-northeast-1
```

```bash
aws sso login --sso-session verify-sso   # 1 回で両アカウント有効
```

設定は `../scripts/setup-sso.sh` で自動化した（実値は `../env.local` から読む）。

**`sso_region` の調べ方**

`sso_region` は Identity Center インスタンスの所在リージョンで、
リソースを作るリージョンとは別物。分からない場合はアクセスポータルの
レスポンスヘッダから判別できる。

```bash
$ curl -sS -o /dev/null -D - https://example.awsapps.com/start | grep -i sso
link: <https://portal.sso.us-west-2.amazonaws.com/>; rel=preconnect; crossorigin
content-security-policy: ... report-uri https://log.sso-portal.us-west-2.amazonaws.com/log
                                                          ^^^^^^^^^ これが sso_region
```

**用語の整理**

| 用語 | 意味 |
|---|---|
| `sso_start_url` | AWS アクセスポータルの URL。組織で 1 つ |
| `sso_region` | Identity Center インスタンスの所在地（今回 us-west-2） |
| `sso_role_name` | **許可セット名**。`AWSReservedSSO_YourPermissionSet_<hash>` という実際のロール名から、`AWSReservedSSO_` と末尾ハッシュを除いた部分 |
| `region` | そのプロファイルで操作するリソースのリージョン（今回 ap-northeast-1） |

## 8. 検証が確認している 10 項目の意味

`../scripts/verify.sh` の出力を読むときの対応。

| # | 項目 | これが通ると何が言えるか |
|---|---|---|
| 1 | AssumeRole 前の principal が A のロール | Lambda が想定の実行ロールで動いている |
| 2 | AssumeRole 後の principal が B の assumed-role | 信頼ポリシー（+ ExternalId 条件）が正しい |
| 3 | 署名ヘッダ 3 つが付与 | SigV4 署名が実際に作られている |
| 4 | HTTP 200 | 権限ポリシー・署名リージョン・メソッド/パスがすべて整合 |
| 5 | B 側 `authenticated=true` | `AWS_IAM` 認可が有効に働いている |
| 6 | B 側 `accountId` が B | 3 節のとおり A の ID は現れない、という理解の確認 |
| 7 | `caller` が `AROA` 始まり | ロール由来の一時認証情報である証跡 |
| 8 | `sessionName` が伝播 | B 側ログで呼び出し元セッションを識別できる |
| 9 | 本文が一致 | SigV4 のペイロードハッシュ検証を通過した |
| 10 | 署名なしで 403 | IAM 認可が「実際に」拒否している（素通りでない） |

10 番目が重要。1〜9 が通っても、認可が無効で誰でも呼べる状態なら検証の意味がない。
「通ること」と「通らないべきものが通らないこと」を両方見る。

## 9. ステータスコードによる切り分け

記録の 5 エラーから得られた対応表。認可の失敗は全部 403 になるので、本文で切り分ける。

| 症状 | 意味 |
|---|---|
| 403 `Credential should be scoped to a valid region` | 署名リージョンが呼び出し先と不一致（4 節） |
| 403 `no identity-based policy allows the execute-api:Invoke action` | 権限ポリシーがない。信頼ポリシーだけでは呼べない（2 節） |
| 403 `Missing Authentication Token` | 署名なし / メソッド・パスが違う |
| 502 `Internal server error` | **認可は通過済み**。B 側 Lambda の実装かハンドラ設定の問題 |
| `Invalid principal in policy` | 信頼ポリシーに書いた ARN のロールが未作成（IAM は作成時に実在を検証する） |
| `Runtime.HandlerNotFound` | ハンドラ設定 `<file>.<function>` とコードの関数名が不一致 |

## 10. 実機で踏んだ制約: IAM の description は ASCII のみ

apply 時に次のエラーで止まった。

```
Error: creating IAM Role (xacct-verify-<owner>-b-invoke-api-role):
  api error ValidationError: 1 validation error detected:
  Value at 'description' failed to satisfy constraint:
  Member must satisfy regular expression pattern: [...\u0020-\u007E\u00A1-\u00FF]*
```

IAM ロールの `description` は ASCII とラテン 1 補助しか受け付けず、日本語を入れると
`CreateRole` が失敗する。一方 **API Gateway の `description` は日本語でも通った**。
AWS はサービスごとに文字種の制約が違うので、AWS 側に渡す `description` は
すべて ASCII に統一し、日本語の説明は HCL のコメントとして書くのが無難。

このとき 14 リソースのうち 13 が作成済みの状態で停止したが、Terraform は state に
記録しているので、修正後の apply は「残り 2 件の作成 + 1 件の in-place 更新」だけで済んだ。
**部分適用でも作り直しにならない**のが state を持つ利点。

## 11. Terraform 上の注意（この構成固有）

- **apply 順序は B → A で固定。** 信頼ポリシーの principal に未作成のロール ARN を
  直接書くと IAM が拒否する。本構成では principal を A のアカウント root にし
  `aws:PrincipalArn` 条件でロールを限定することで、A 未作成でも B を作れるようにしている。
  A の Lambda は B の API URL を環境変数に必要とするので、逆順にはできない。
- **`terraform output` は AWS を呼ばない。** ローカルの state を読むだけなので、
  別アカウントにログイン中でも他方の出力を取得できる。逐次ログイン運用が成立する理由。
- **state と tfvars はコミットしない。** ExternalId が含まれる。`.gitignore` 済み。
