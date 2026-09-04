# 実験記録: STS の挙動を実機で確認する

`sts-experiments.md` の手順を実際に実行した記録。コマンド・実行結果・読み方をセットで残す。

- 実行日: 2026-09-04
- 環境: アカウント A（共有検証環境）→ アカウント B、ap-northeast-1
- **実行結果はダミー値に置換済み**（下記「置換した値」参照）。構造と関係は実物のまま
- 現在 **実験 1〜4 まで実施済み**。実験 5・6 は未実施

## 置換した値

記録として残すため、実際の出力から以下を機械的に置換している。
値そのものではなく「どのフィールドに何が現れるか」が学習の対象なので、
置換しても記録の意味は損なわれない。

| 種別 | 実値 | 本記録での表記 |
|---|---|---|
| アカウント A の ID | 12 桁の数字 | `111111111111` |
| アカウント B の ID | 12 桁の数字 | `222222222222` |
| 作成者識別子（`owner`） | 実名 | `yourname` |
| メールアドレス | 実アドレス | `you@example.com` |
| SSO 許可セット名 | 実名 + hash | `YourPermissionSet_0123456789abcdef` |
| ロールの一意 ID | `AROA` + 17 文字 | `AROAEXAMPLE...` |
| 一時認証情報のキー ID | `ASIA` + 16 文字 | `ASIAEXAMPLE...` |
| API Gateway の API ID | 10 文字 | `abcde12345` |
| 送信元 IP | 実 IP | `203.0.113.10`（ドキュメント用予約範囲） |
| リクエスト ID | UUID | オールゼロ |

ExternalId は出力に現れない（Terraform で `sensitive` 指定、かつ AssumeRole の時点で
消費されるため API Gateway のイベントにも載らない）。

---

## 実験 1: 自分が誰かを見る

```bash
source ./scripts/exp-env.sh && \
  aws sts get-caller-identity --profile "$PROFILE_A"
```

```json
{
    "UserId": "AROAEXAMPLESSOUSER001:you@example.com",
    "Account": "111111111111",
    "Arn": "arn:aws:sts::111111111111:assumed-role/AWSReservedSSO_YourPermissionSet_0123456789abcdef/you@example.com"
}
```

### 読み方

**SSO でログインした人間のセッションも STS の assumed-role である。**

| フィールド | 読み |
|---|---|
| `Arn` | `arn:aws:sts::...:assumed-role/...` 形式。`iam` ではなく `sts` |
| `AWSReservedSSO_<許可セット>_<hash>` | IAM Identity Center が自動生成したロール名 |
| `UserId` | `AROA...` 始まり = ロール由来 |
| セッション名 | メールアドレスが入る（SSO が設定） |

IAM ユーザーとして直接操作しているのではない。AWS では人間も Lambda も
「ロールを引き受けて一時認証情報を得る」同じ仕組みで動いている。

`GetCallerIdentity` は権限が一切不要な API なので、権限周りで詰まったときの
最初の確認手段になる。

---

## 実験 2: 手で AssumeRole してみる（失敗する）

ExternalId なしと、正しい ExternalId ありの 2 パターンを実行した。

```bash
source ./scripts/exp-env.sh && \
  aws sts assume-role --profile "$PROFILE_A" --role-arn "$ROLE_ARN" \
    --role-session-name manual-test

source ./scripts/exp-env.sh && \
  aws sts assume-role --profile "$PROFILE_A" --role-arn "$ROLE_ARN" \
    --role-session-name manual-test \
    --external-id "$(terraform -chdir=terraform/account-b output -raw external_id)"
```

**両方とも同じエラーになった。**

```
An error occurred (AccessDenied) when calling the AssumeRole operation: User: arn:aws:sts::111111111111:assumed-role/AWSReservedSSO_YourPermissionSet_0123456789abcdef/you@example.com is not authorized to perform: sts:AssumeRole on resource: arn:aws:iam::222222222222:role/xacct-verify-yourname-b-invoke-api-role
```

### 読み方

エラー文を 3 つに分解する。

| 部分 | 意味 |
|---|---|
| `User: arn:aws:sts::111111111111:assumed-role/AWSReservedSSO_.../you@example.com` | 今の自分（実験 1 の identity と同じ） |
| `is not authorized to perform: sts:AssumeRole` | やろうとした操作 |
| `on resource: arn:aws:iam::222222222222:role/xacct-verify-yourname-b-invoke-api-role` | 対象のロール |

自分はアカウント A にいて開発者向けの許可セットを割り当てられている。
それでも B のロールは引き受けられない。B の信頼ポリシーが `aws:PrincipalArn` 条件で
**A の Lambda 実行ロールだけ**を許可しているため。

**正しい ExternalId を付けても同じ `AccessDenied` だった。** これが重要で、
ExternalId は「知っていれば通る鍵」ではなく、信頼ポリシーの条件が
すべて揃って初めて通る **AND 条件の 1 つ**であることが実測できた。

```json
"Condition": {
  "ArnLike":      { "aws:PrincipalArn": [...] },   // これと
  "StringEquals": { "sts:ExternalId": "..." }      // これの両方
}
```

### 期待どおりでないエラーの見分け方

| エラー | 意味 | 対処 |
|---|---|---|
| `AccessDenied ... not authorized to perform: sts:AssumeRole` | **期待どおり** | 実験 3 へ進む |
| `ValidationError: ... is invalid` | ARN が壊れている（zsh の `:r` 罠） | `${ACCOUNT_B_ID}` と波括弧で囲む |
| `The config profile ... could not be found` | プロファイル名が違う | `env.local` の `PROFILE_A` を確認 |
| `Your session has expired` | SSO セッション切れ | `aws sso login --sso-session verify-sso` |

---

## 実験 3: Lambda 経由で成功する経路を見る

実験 2 で拒否されたのと**同じロール**に、A の Lambda からアクセスする。

```bash
source ./scripts/exp-env.sh && \
  aws lambda invoke --profile "$PROFILE_A" --region "$AWS_RESOURCE_REGION" \
    --function-name "$FUNC" --cli-binary-format raw-in-base64-out \
    --payload '{}' out/exp3.json >/dev/null
python3 -m json.tool out/exp3.json
```

```json
{
    "config": {
        "targetRoleArn": "arn:aws:iam::222222222222:role/xacct-verify-yourname-b-invoke-api-role",
        "targetApiUrl": "https://abcde12345.execute-api.ap-northeast-1.amazonaws.com/dev/verify",
        "httpMethod": "POST",
        "signingRegion": "ap-northeast-1",
        "functionRegion": "ap-northeast-1",
        "regionInUrl": "ap-northeast-1",
        "externalIdUsed": true,
        "roleSessionName": "yourname-verify",
        "skipSigning": false
    },
    "callerIdentityBeforeAssume": {
        "account": "111111111111",
        "arn": "arn:aws:sts::111111111111:assumed-role/xacct-verify-yourname-caller-role/xacct-verify-yourname-a-caller",
        "userId": "AROAEXAMPLEROLEACCTA1:xacct-verify-yourname-a-caller"
    },
    "requestBody": "{\"hello\": \"world\"}",
    "assumedRoleUser": {
        "arn": "arn:aws:sts::222222222222:assumed-role/xacct-verify-yourname-b-invoke-api-role/yourname-verify",
        "assumedRoleId": "AROAEXAMPLEROLEACCTB1:yourname-verify",
        "expiration": "2026-09-04T09:49:01+00:00"
    },
    "callerIdentityAfterAssume": {
        "account": "222222222222",
        "arn": "arn:aws:sts::222222222222:assumed-role/xacct-verify-yourname-b-invoke-api-role/yourname-verify",
        "userId": "AROAEXAMPLEROLEACCTB1:yourname-verify"
    },
    "signedHeaderNames": [
        "authorization",
        "content-type",
        "x-amz-date",
        "x-amz-security-token"
    ],
    "apiResponse": {
        "statusCode": 200,
        "body": {
            "ok": true,
            "message": "reached account B backend",
            "caller": {
                "userArn": "arn:aws:sts::222222222222:assumed-role/xacct-verify-yourname-b-invoke-api-role/yourname-verify",
                "accountId": "222222222222",
                "caller": "AROAEXAMPLEROLEACCTB1:yourname-verify",
                "user": "AROAEXAMPLEROLEACCTB1:yourname-verify",
                "accessKey": "ASIAEXAMPLETEMPKEY01",
                "sourceIp": "203.0.113.10",
                "sessionName": "yourname-verify",
                "authenticated": true,
                "requestId": "00000000-0000-0000-0000-000000000000"
            },
            "backend": {
                "accountId": "222222222222",
                "functionArn": "arn:aws:lambda:ap-northeast-1:222222222222:function:xacct-verify-yourname-b-echo",
                "region": "ap-northeast-1"
            },
            "request": {
                "httpMethod": "POST",
                "resourcePath": "/verify",
                "stage": "dev",
                "receivedBody": "{\"hello\": \"world\"}"
            }
        }
    },
    "expectation": "\u7d4c\u8def\u304c\u901a\u3063\u3066\u3044\u308c\u3070 statusCode \u306f 200"
}
```

### 読み方 1: 実験 2 との違いは principal だけ

| | 実験 2（拒否） | 実験 3（成功） |
|---|---|---|
| principal | `assumed-role/AWSReservedSSO_.../you@example.com` | `assumed-role/xacct-verify-yourname-caller-role/...` |
| アカウント | `111111111111`（A） | `111111111111`（**同じ A**） |
| 対象ロール | B の invoke-api-role | **同じ** |
| ExternalId | 正しい値を指定 | `externalIdUsed: true` |
| 結果 | `AccessDenied` | 一時認証情報を取得 |

同じアカウント・同じ対象・同じ ExternalId で結果が分かれた。
**信頼ポリシーの `aws:PrincipalArn` 条件が効いている決定的な証拠。**

### 読み方 2: 3 つの ARN

```
callerIdentityBeforeAssume  sts::111111111111:assumed-role/xacct-verify-yourname-caller-role/xacct-verify-yourname-a-caller
assumedRoleUser             sts::222222222222:assumed-role/xacct-verify-yourname-b-invoke-api-role/yourname-verify
callerIdentityAfterAssume   sts::222222222222:assumed-role/xacct-verify-yourname-b-invoke-api-role/yourname-verify
                                 ↑ 下 2 つは完全一致
```

下 2 つの一致は「AssumeRole が返した ID」と「その認証情報で実際に名乗れる ID」が
同じであることの実測。

1 つ目のセッション名が **Lambda の関数名**になっている点にも注目
（`/xacct-verify-yourname-a-caller`）。Lambda が実行ロールを引き受けるとき、
AWS がセッション名に関数名を自動設定する。自分で指定した `RoleSessionName`
（`yourname-verify`）が現れるのは、その後に自分で呼んだ AssumeRole の結果の方。

### 読み方 3: AROA が切り替わっている

```
AROAEXAMPLEROLEACCTA1:xacct-verify-yourname-a-caller   ← A のロール
AROAEXAMPLEROLEACCTB1:yourname-verify                  ← B のロール
ASIAEXAMPLETEMPKEY01                                   ← B の一時キー
```

ロールが変われば `AROA` の一意 ID も変わる。実物では B の `AROA` と `ASIA` が
同じ 8 文字の成分を共有しており、**キーを見ればどのアカウントのものか推測できる**
（公式に保証された仕様ではないので依存すべきではないが、ログを追う手掛かりになる）。

### 読み方 4: その他

| フィールド | 読み |
|---|---|
| `signedHeaderNames` が 4 つ | `content-type` が入るのは POST で本文を送っているため |
| `receivedBody` == `requestBody` | SigV4 のペイロードハッシュ検証を通過した証跡 |
| `regionInUrl` == `signingRegion` | 署名リージョンの取り違えが起きていない |
| `expiration` | invoke 時刻の 15 分後（`DurationSeconds=900`） |
| `accountId` が B | B 側から見た呼び出し元は「B 自身のロール」。A の ID は現れない |
| `authenticated: true` | `AWS_IAM` 認可を通過した |
| `sourceIp` | Lambda の送信元 IP。**実行ごとに変わる**（後述） |

---

## 実験 4: セッション名を変えて呼ぶ

```bash
source ./scripts/exp-env.sh && \
  aws lambda invoke --profile "$PROFILE_A" --region "$AWS_RESOURCE_REGION" \
    --function-name "$FUNC" --cli-binary-format raw-in-base64-out \
    --payload '{"role_session_name":"experiment-4"}' out/exp4.json >/dev/null
python3 -c "
import json; d=json.load(open('out/exp4.json'))
c = d['apiResponse']['body']['caller']
print('B が観測した ARN :', c['userArn'])
print('caller          :', c['caller'])
print('sessionName     :', c['sessionName'])
"
```

```
B が観測した ARN : arn:aws:sts::222222222222:assumed-role/xacct-verify-yourname-b-invoke-api-role/experiment-4
caller          : AROAEXAMPLEROLEACCTB1:experiment-4
sessionName     : experiment-4
```

### 読み方

実験 3 と並べると構造が見える。

```
実験 3: AROAEXAMPLEROLEACCTB1:yourname-verify
実験 4: AROAEXAMPLEROLEACCTB1:experiment-4
        ^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^
        変わらない             変わった
```

前半はロールの一意 ID なのでロールが同じなら不変。コロンの後ろは呼び出し側が
`RoleSessionName` として渡した文字列がそのまま入る。

### 重要な帰結: セッション名は認可に使えない

`experiment-4` と指定したら、B 側にはそのまま `experiment-4` として届いた。
B 側は「本当にそのセッション名の主体なのか」を検証していない。**自己申告である。**

| 用途 | 使えるか |
|---|---|
| ログでの追跡・attribution | 使える（本来の用途） |
| 「このセッション名なら許可」という認可 | **使えない**（呼び出し元が名乗り放題） |

呼び出し元を認可レベルで区別したいなら **用途ごとにロールを分ける**。
前任者の記録にあった「用途ごとにロールを分けるか、セッション名に識別子を入れる」は、
**識別はセッション名、認可はロール**という切り分けを意味している。

本構成が `<owner>-verify` を使うのは識別が目的。共有アカウント A から複数メンバーが
呼んでも B 側のログで区別できるが、他メンバーが同じ名前を名乗ることは技術的に可能なので
なりすまし防止にはならない。

---

## ここまでで確認できたこと

| # | 確認事項 | 根拠 |
|---|---|---|
| 1 | 人間の SSO セッションも STS の assumed-role | 実験 1 の `Arn` |
| 2 | 信頼ポリシーの `aws:PrincipalArn` 条件が実際に効いている | 実験 2 の `AccessDenied` と実験 3 の成功の対比 |
| 3 | ExternalId は単体の鍵ではなく AND 条件の 1 つ | 実験 2（正しい値でも拒否） |
| 4 | AssumeRole 後は principal が B に切り替わる | 実験 3 の 3 つの ARN |
| 5 | B 側に A のアカウント ID は現れない | 実験 3 の `accountId` |
| 6 | Lambda 実行ロールのセッション名は関数名 | 実験 3 の `callerIdentityBeforeAssume` |
| 7 | SigV4 のペイロードハッシュ検証まで通っている | 実験 3 の `receivedBody` |
| 8 | セッション名は呼び出し側が自由に決められる（自己申告） | 実験 4 |

## 未実施

| 実験 | 内容 | 確認したいこと |
|---|---|---|
| 5 | 実験 3 と 4 の `accessKey` / `expiration` を比較 | 一時認証情報が呼び出しごとに新規発行されること |
| 6 | 署名なしで呼ぶ（`skip_signing`） | 認可が実際に拒否していること（403） |

手順は `sts-experiments.md` を参照。実行後、結果をこの記録に追記する。
