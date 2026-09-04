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
| IAM ロール（権限の束） | **IAM ポリシー** | ★用語が逆転している。「ロールの意味が GCP と逆」の節を必ず読むこと |
| サービスアカウントの権限借用（impersonation） | **AssumeRole**（STS） | 本検証の中心。「STS とは」の節 |
| SA に付ける `roles/iam.serviceAccountTokenCreator` | ロールの**信頼ポリシー** | 「誰がこの ID になりきれるか」の定義 |
| ID トークン / アクセストークンを Bearer ヘッダで送る | **SigV4 署名** | 方式が根本的に違う。「SigV4 署名」の節 |
| Cloud Run の IAM invoker | API Gateway の **`AWS_IAM` 認可** | 「IAM で認可された呼び出し元だけ通す」点は同じ |
| Cloud Functions / Cloud Run | **Lambda** | |
| Cloud Logging | **CloudWatch Logs** | |
| Cloud Audit Logs | **CloudTrail** | |
| （なし） | **ExternalId** | 「ExternalId とは」の節 |

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

## 3. STS とは（AssumeRole の実行主体）

**STS = AWS Security Token Service。一時的な認証情報を発行するサービス。**
実際に手を動かして確認する手順は `sts-experiments.md` にまとめてある。
`sts:AssumeRole` も `sts:GetCallerIdentity` もこのサービスの API。

### 発行されるもの

```
AccessKeyId      ASIA...            ← 一時認証情報のキー ID
SecretAccessKey  (秘密)
SessionToken     (秘密)             ← 一時認証情報にだけ付く
Expiration       15 分後            ← 本検証では DurationSeconds=900
```

3 点目の `SessionToken` が一時認証情報の特徴。SigV4 署名時に
`x-amz-security-token` ヘッダとして送られる（署名ヘッダ 3 つのうちの 1 つ）。

### 本検証で使っている STS API

| 呼び出し | API | 目的 |
|---|---|---|
| ① | `sts:AssumeRole` | B のロールの一時認証情報を取得 |
| ② | `sts:GetCallerIdentity` | 「今の自分は誰か」を確認 |

`GetCallerIdentity` は **権限が一切不要** な特殊な API で、自分が誰として
認識されているかを返す。デバッグの起点として頻繁に使う。
`aws sts get-caller-identity` はこのコマンドそのもの。

### AssumeRole する前から STS を使っている

検証結果の principal を見ると、AssumeRole の前後どちらも `sts` になっている。

```
前: arn:aws:sts::<ACCOUNT_A_ID>:assumed-role/xacct-verify-<owner>-caller-role/...
     ^^^                        ^^^^^^^^^^^^^
後: arn:aws:sts::<ACCOUNT_B_ID>:assumed-role/xacct-verify-<owner>-b-invoke-api-role/<owner>-verify
```

Lambda は起動時に実行ロールを STS 経由で引き受けているため、AssumeRole する前から
すでに assumed-role セッションとして動いている。AWS では「恒久的なキーを持たず、
ロールを引き受けて一時認証情報を得る」のが基本形で、STS はその仕組みそのもの。

### Lambda 実行ロールのセッション名は関数名になる

`callerIdentityBeforeAssume` の ARN をよく見ると、セッション名の部分が
Lambda の関数名になっている。

```
arn:aws:sts::<ACCOUNT_A_ID>:assumed-role/xacct-verify-<owner>-caller-role/xacct-verify-<owner>-a-caller
                                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                          ロール名                         関数名がセッション名になる
```

Lambda が実行ロールを引き受けるとき、AWS がセッション名に関数名を自動設定する。
自分で指定した `RoleSessionName`（本構成では `<owner>-verify`）が現れるのは、
その後に自分で呼んだ AssumeRole の結果の方。

CloudTrail で「どの Lambda 関数がこの API を呼んだか」を追うときの手掛かりになる。

### ARN の書き分け

```
arn:aws:iam::<account>:role/MyRole                 ← ロールという「入れ物」
arn:aws:sts::<account>:assumed-role/MyRole/session ← それを引き受けた「セッション」
```

サービス名の位置が `iam` と `sts` で違う。B 側の信頼ポリシーの
`aws:PrincipalArn` 条件に 2 パターン書いているのは、環境によってどちらの形式で
評価されるか差があるため。

### RoleSessionName は自己申告なので認可に使えない

`sts-experiments.md` の実験 4 で実測できる。呼び出し側が `RoleSessionName` に
渡した文字列が、そのまま B 側の ARN 末尾と `sessionName` に現れる。

```
実験 3: AROA<ロールの一意 ID>:<owner>-verify
実験 4: AROA<ロールの一意 ID>:experiment-4
        ^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^
        ロールに固定          呼び出し側が自由に決める
```

B 側は「本当にそのセッション名の主体なのか」を検証していない。**自己申告である。**

| 用途 | 使えるか |
|---|---|
| ログでの追跡・attribution | 使える（本来の用途） |
| 「このセッション名なら許可」という認可 | **使えない**（呼び出し元が名乗り放題） |

呼び出し元を認可レベルで区別したいなら **用途ごとにロールを分ける**。
記録にあった「複数の呼び出し元が同じロールを使い始めると B 側で区別できなくなる。
用途ごとにロールを分けるか、セッション名に識別子を入れる」という指摘は、
「識別はセッション名、認可はロール」という切り分けを意味している。

本構成が `<owner>-verify` を使うのは識別が目的。共有アカウント A から複数メンバーが
呼んでも B 側のログで区別できるが、他メンバーが同じ名前を名乗ることは技術的に可能なので
なりすまし防止にはならない。

なお `sts:RoleSessionName` を信頼ポリシーの条件にすることは可能で、命名規約の強制
（`${aws:username}` と一致させる等）には使える。ただし認可された principal に対する
防御にはならない。

### 識別子の先頭 4 文字で由来が分かる

| 接頭辞 | 意味 |
|---|---|
| `AROA` | **ロール**の一意 ID |
| `ASIA` | **一時**認証情報のアクセスキー ID（STS 発行） |
| `AKIA` | IAM **ユーザー**の恒久的なアクセスキー ID |
| `AIDA` | IAM **ユーザー**の一意 ID |

検証で B 側が観測した `caller` は `AROA...`、`accessKey` は `ASIA...` だった。
これが「STS 由来の一時認証情報で呼ばれた」証跡になる。もし `AKIA` が出ていたら
IAM ユーザーの恒久キーを使っていることになり、設計意図から外れていると分かる。

### GCP との対応

| GCP | AWS |
|---|---|
| `iamcredentials.googleapis.com` の `generateAccessToken`（SA の impersonation） | `sts:AssumeRole` |
| `sts.googleapis.com`（Workload Identity 連携のトークン交換） | `sts:AssumeRoleWithWebIdentity` |
| （直接の対応物は少ない） | `sts:GetCallerIdentity` |

GCP では impersonation とトークン交換が別サービスに分かれているが、
AWS はまとめて STS が担う。

### 主な API

| API | 用途 |
|---|---|
| `AssumeRole` | ロールを引き受ける（本検証で使用。クロスアカウントの基本） |
| `GetCallerIdentity` | 自分が誰かを確認（権限不要） |
| `AssumeRoleWithWebIdentity` | OIDC 連携。GitHub Actions から AWS を触る際の定番 |
| `AssumeRoleWithSAML` | SAML 連携 |

`AssumeRoleWithWebIdentity` は CI/CD を組むときに使う。恒久キーを CI に
置かずに済むので、将来 GitHub Actions からデプロイする場合はこれを選ぶ。

## 4. AssumeRole すると「自分が誰か」が変わる

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

## 5. SigV4 署名は Bearer トークンと違う

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

## 6. ExternalId とは（GCP に対応物がない）

AssumeRole 時に、信頼ポリシーの `sts:ExternalId` 条件で要求できる任意の文字列。
**confused deputy（混乱した代理人）問題**への対策。

### なぜ必要か: confused deputy 問題

典型例は「第三者の SaaS に自アカウントを触らせる」場面。

監視 SaaS ベンダーに自分の AWS アカウントを見せたいとき、ベンダーのアカウントを
信頼するロールを作る。しかしベンダーは他社も顧客に持っている。

```
                    ┌─────────────────────────────┐
自社のロール  <─────┤ 監視 SaaS ベンダーのアカウント │
                    │  顧客 X 用の処理            │
他社のロール  <─────┤  顧客 Y 用の処理            │
                    └─────────────────────────────┘
```

ベンダーのシステムが（設定ミスや攻撃で）「顧客 Y の依頼を処理しているつもりで
自社のロール ARN を使う」状態になると、他社の指示で自社アカウントが操作されてしまう。
ベンダーは信頼されている代理人（deputy）なので、AWS から見れば正当な AssumeRole に見える。

ここで自社が「私のロールを引き受けるときは `abc-123` を必ず付けろ」と要求しておけば、
その値を知らない経路からの AssumeRole は通らない。これが ExternalId。
ベンダー側は顧客ごとに異なる ExternalId を管理する。

### 「外部」ID という名前の由来

自分のアカウントの内部で管理する識別子ではなく、**信頼関係の相手（外部）との間で
取り決める識別子**という意味。パスワードのような認証情報ではなく、
「どの取引先との関係か」を示すラベルに近い。ただし推測可能な値では意味がないので、
UUID など推測困難な値にし、公開もしない。

### ExternalId は「鍵」ではない（実測）

`sts-experiments.md` の実験 2 で確認できる重要な点。

**正しい ExternalId を持っていても、principal が許可されていなければ拒否される。**

```
$ aws sts assume-role --role-arn <B のロール> --role-session-name manual-test \
    --external-id <正しい値>
AccessDenied: User: arn:aws:sts::<A>:assumed-role/AWSReservedSSO_.../<自分>
is not authorized to perform: sts:AssumeRole
```

信頼ポリシーの条件は **AND** で評価される。ExternalId は
「principal の条件を満たした上で、さらに要求される追加条件」であって、
これ単体で通れる鍵ではない。

```json
"Condition": {
  "ArnLike":      { "aws:PrincipalArn": [...] },   ← これと
  "StringEquals": { "sts:ExternalId": "..." }      ← これの両方を満たす必要がある
}
```

### 本検証での扱い

A と B は両方とも自社アカウントなので、厳密には confused deputy のリスクは低い。
それでも前任者の記録が ExternalId を使った構成で成立を確認しているため、
同じ構成を再現している。

B 側で `random_uuid` により自動生成し、Terraform の `account_a_tfvars` 出力経由で
A に渡している。両側に手で書くと値がずれて `AccessDenied` になるため。

### 注意点

- **ExternalId は AssumeRole の時点で消費される。** B 側の Lambda では受け取れない
  （API Gateway のイベントにも載らない）ので、アプリケーションで再利用はできない
- **本番運用では平文の環境変数に置かない。** 現状は Lambda 環境変数だが、
  SSM Parameter Store / Secrets Manager へ移すのが無難
- GCP に直接の対応物はない。GCP の SA impersonation は
  「誰が impersonate できるか」を SA の IAM ポリシーで指定するのみで、
  追加の共有識別子という概念を持たない

## 7. `owner` 変数は AWS の機能ではない

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

## 8. 認証: `aws login` は同時に 1 アカウントしか保持できない

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

## 9. 検証が確認している 10 項目の意味

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

## 10. ステータスコードによる切り分け

記録の 5 エラーから得られた対応表。認可の失敗は全部 403 になるので、本文で切り分ける。

| 症状 | 意味 |
|---|---|
| 403 `Credential should be scoped to a valid region` | 署名リージョンが呼び出し先と不一致（4 節） |
| 403 `no identity-based policy allows the execute-api:Invoke action` | 権限ポリシーがない。信頼ポリシーだけでは呼べない（2 節） |
| 403 `Missing Authentication Token` | 署名なし / メソッド・パスが違う |
| 502 `Internal server error` | **認可は通過済み**。B 側 Lambda の実装かハンドラ設定の問題 |
| `Invalid principal in policy` | 信頼ポリシーに書いた ARN のロールが未作成（IAM は作成時に実在を検証する） |
| `Runtime.HandlerNotFound` | ハンドラ設定 `<file>.<function>` とコードの関数名が不一致 |

## 11. 実機で踏んだ制約: IAM の description は ASCII のみ

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

## 12. Terraform 上の注意（この構成固有）

- **apply 順序は B → A で固定。** 信頼ポリシーの principal に未作成のロール ARN を
  直接書くと IAM が拒否する。本構成では principal を A のアカウント root にし
  `aws:PrincipalArn` 条件でロールを限定することで、A 未作成でも B を作れるようにしている。
  A の Lambda は B の API URL を環境変数に必要とするので、逆順にはできない。
- **`terraform output` は AWS を呼ばない。** ローカルの state を読むだけなので、
  別アカウントにログイン中でも他方の出力を取得できる。逐次ログイン運用が成立する理由。
- **state と tfvars はコミットしない。** ExternalId が含まれる。`.gitignore` 済み。
