# STS を理解するための実験手順

`scripts/verify.sh` は合否を自動判定するが、STS（AWS Security Token Service）が
何をしているのかを理解するには、**あえて失敗させる実験**を挟むのが有効。

前提: `terraform/account-a` と `terraform/account-b` の apply が完了していること。
STS 自体の解説は `learning-notes.md` の「STS とは」の節を参照。

## 準備

実験で使う変数は `scripts/exp-env.sh` にまとめてある。

```bash
source ./scripts/exp-env.sh
```

これで `PROFILE_A` / `PROFILE_B` / `ACCOUNT_B_ID` / `OWNER` /
`AWS_RESOURCE_REGION` / `FUNC`（Lambda 関数名）/ `ROLE_ARN`（B のロール）が
使えるようになり、`out/` ディレクトリも作られる。

### 準備コマンドを何回実行するか

**実行方法によって変わる。**

| 実行方法 | 準備コマンド |
|---|---|
| ターミナルで対話的に作業する | **最初に 1 回だけ**（同じシェルの中で変数が保持される） |
| 1 コマンドずつ実行する（Claude Code の `!` など） | **毎回必要**（コマンドごとに別シェルになり変数が引き継がれない） |

1 コマンドずつ実行する場合は、各実験のコマンドの先頭に付ける。
本ドキュメントの各実験はこの形で書いてある。

```bash
source ./scripts/exp-env.sh && <実験のコマンド>
```

新しいターミナルを開いた場合も再実行が必要。変数が空になっていないかは
これで確認できる。

```bash
echo "FUNC=[$FUNC] ROLE_ARN=[$ROLE_ARN]"
```

### zsh の注意

`$ACCOUNT_B_ID:role/...` と書くと `:r` が zsh の修飾子（拡張子を除去する）として
解釈され、ARN が `arn:aws:iam::<ACCOUNT_B_ID>ole/...` に壊れる。実際にこれを踏んで
`ValidationError: ... is invalid` になった。エラーが `AccessDenied` ではないので
権限問題と誤診しやすい。必ず `${ACCOUNT_B_ID}` と波括弧で囲む
（`scripts/exp-env.sh` では対処済み）。

## 実験 1: 自分が誰かを見る

```bash
source ./scripts/exp-env.sh && \
  aws sts get-caller-identity --profile "$PROFILE_A"
```

期待される結果:

```json
{
  "UserId": "AROA...:<メールアドレス>",
  "Account": "<ACCOUNT_A_ID>",
  "Arn": "arn:aws:sts::<ACCOUNT_A_ID>:assumed-role/AWSReservedSSO_<許可セット>_<hash>/<メールアドレス>"
}
```

**確認すること**: `Arn` が `arn:aws:sts::...:assumed-role/...` 形式であること。

SSO でログインした人間のセッションも、**STS の assumed-role セッション**である。
IAM ユーザーとして直接操作しているのではない。`UserId` も `AROA...` で始まる。
AWS では人間も Lambda も同じ仕組みで動いている。

`GetCallerIdentity` は権限が一切不要な API なので、権限周りで詰まったときの
最初の確認手段として使える。

## 実験 2: 手で AssumeRole してみる（失敗する）

```bash
source ./scripts/exp-env.sh && \
  aws sts assume-role --profile "$PROFILE_A" --role-arn "$ROLE_ARN" \
    --role-session-name manual-test
```

期待される結果:

```
An error occurred (AccessDenied) when calling the AssumeRole operation:
User: arn:aws:sts::<ACCOUNT_A_ID>:assumed-role/AWSReservedSSO_<許可セット>_<hash>/<メール>
is not authorized to perform: sts:AssumeRole
on resource: arn:aws:iam::<ACCOUNT_B_ID>:role/xacct-verify-<owner>-b-invoke-api-role
```

次に **正しい ExternalId を付けて** もう一度試す。

```bash
source ./scripts/exp-env.sh && \
  aws sts assume-role --profile "$PROFILE_A" --role-arn "$ROLE_ARN" \
    --role-session-name manual-test \
    --external-id "$(terraform -chdir=terraform/account-b output -raw external_id)"
```

**確認すること**: ExternalId が正しくても `AccessDenied` のままであること。

これが信頼ポリシーの働き。B のロールは `aws:PrincipalArn` 条件で
**A の Lambda 実行ロールだけ**を許可しているので、同じアカウント A にいる
自分の SSO セッションでは引き受けられない。

**ExternalId は追加条件であって、それ単体が鍵ではない。** 6 実験のうち
最も学びが大きい箇所。「権限のあるアカウントにいる自分でも引き受けられない」ことを
実測すると、信頼ポリシーが何を守っているのかが腑に落ちる。

## 実験 3: Lambda 経由で成功する経路を見る

```bash
source ./scripts/exp-env.sh && \
  aws lambda invoke --profile "$PROFILE_A" --region "$AWS_RESOURCE_REGION" \
    --function-name "$FUNC" --cli-binary-format raw-in-base64-out \
    --payload '{}' out/exp3.json >/dev/null
python3 -m json.tool out/exp3.json
```

**確認すること**: 3 つの identity が並んでいる。

| フィールド | 誰か |
|---|---|
| `callerIdentityBeforeAssume.arn` | A の Lambda 実行ロール（実験 1 の自分とは別） |
| `assumedRoleUser.arn` | AssumeRole の戻り値 |
| `callerIdentityAfterAssume.arn` | 同じ認証情報で STS に聞き直した結果 |

`assumedRoleUser` と `callerIdentityAfterAssume` が一致することを確認する。
「AssumeRole が返した ID」と「実際にその認証情報で名乗れる ID」が同じ、という
当たり前を実測で確かめる工程。

`callerIdentityBeforeAssume` が既に `sts` の assumed-role になっている点にも注目。
Lambda は起動時に実行ロールを STS 経由で引き受けている。

さらにその ARN のセッション名が **Lambda の関数名**になっている。

```
.../assumed-role/xacct-verify-<owner>-caller-role/xacct-verify-<owner>-a-caller
                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                  ロール名                          関数名（AWS が自動設定）
```

自分で指定した `RoleSessionName`（`<owner>-verify`）が現れるのは、その後に
自分で呼んだ AssumeRole の結果（`assumedRoleUser` 以降）の方。

**実験 2 との対比がこの実験の核心。** 同じロール、同じ ExternalId で、
違うのは principal だけ。実験 2 では拒否され、実験 3 では成功した。
B の信頼ポリシーの `aws:PrincipalArn` 条件が効いている証拠になる。

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

**確認すること**: ARN 末尾が `/experiment-4` に変わり、`sessionName` もそれになる。

一方 `caller` の `AROA...` の部分は **実験 3 と変わらない**。

```
caller = "AROA<ロールの一意 ID>:experiment-4"
          ^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^
          ロールに固定           呼び出し側が決める
```

**重要な帰結**: セッション名は呼び出し側が自由に決められるので、
**認可の判断材料には使えない**。B 側は「本当にそのセッション名の主体か」を
検証していない（自己申告）。ログでの追跡には使えるが、
「このセッション名なら許可」という制御には使えない。
呼び出し元を認可レベルで区別したいなら用途ごとにロールを分ける。

これが「B 側のログで誰の呼び出しか識別する」仕組みの正体。本構成では
`RoleSessionName` を `<owner>-verify` にしているので、共有アカウント A から
複数メンバーが呼んでも B 側で区別できる。

## 実験 5: 一時認証情報が毎回変わることを見る

実験 3 と 4 の結果を比べる。

```bash
python3 -c "
import json
for f in ['out/exp3.json','out/exp4.json']:
    d=json.load(open(f))
    print(f)
    print('  accessKey :', d['apiResponse']['body']['caller']['accessKey'])
    print('  expiration:', d['assumedRoleUser']['expiration'])
"
```

**確認すること**: `accessKey`（`ASIA...`）が 2 回で異なり、`expiration` も
呼び出し時刻から 15 分後にずれている。

呼び出しごとに STS が新しい一時認証情報を発行している。
本検証では経路全体を毎回通すため invoke ごとに AssumeRole しているが、
本番実装では有効期限まで結果をキャッシュする。

接頭辞の意味:

| 接頭辞 | 意味 |
|---|---|
| `ASIA` | 一時認証情報のアクセスキー ID（STS 発行） |
| `AKIA` | IAM ユーザーの恒久的なアクセスキー ID |
| `AROA` | ロールの一意 ID |
| `AIDA` | IAM ユーザーの一意 ID |

`ASIA` が出ていれば STS 由来の一時認証情報で呼ばれた証跡。`AKIA` が出ていたら
IAM ユーザーの恒久キーを使っていることになり、設計意図から外れていると分かる。

## 実験 6: 署名を外して認可が効いていることを確認

```bash
source ./scripts/exp-env.sh && \
  aws lambda invoke --profile "$PROFILE_A" --region "$AWS_RESOURCE_REGION" \
    --function-name "$FUNC" --cli-binary-format raw-in-base64-out \
    --payload '{"skip_signing":true}' out/exp6.json >/dev/null
python3 -c "
import json; d=json.load(open('out/exp6.json'))
print(d['apiResponse'])
"
```

期待される結果:

```python
{'statusCode': 403, 'body': {'message': 'Missing Authentication Token'}}
```

**確認すること**: 403 で拒否されること。

AssumeRole は成功していても、SigV4 署名を付けなければ API Gateway は通さない。
**STS で一時認証情報を得ることと、それで署名することは別の工程。**

この実験が無いと、200 が返っても認可が実際に働いているのか
（誰でも通る状態になっていないか）が判別できない。

## STS の概念と確認場所の対応

| STS の概念 | どこで確認できるか |
|---|---|
| 人も Lambda も assumed-role セッション | 実験 1 と 3 の `arn` |
| 信頼ポリシーが引き受け可否を決める | 実験 2 の `AccessDenied` |
| ExternalId は追加条件（単体の鍵ではない） | 実験 2 の ExternalId 付き版 |
| 一時認証情報は呼び出しごとに新規発行 | 実験 5 の `accessKey` / `expiration` |
| セッション名は呼び出し側が決める | 実験 4 の ARN 末尾 |
| `AROA` = ロール、`ASIA` = 一時キー | 実験 4、5 |
| 認証情報の取得と署名は別工程 | 実験 6 |

## 後片付け

`out/` は `.gitignore` 済みなので、実験結果がコミットされることはない。
不要になれば削除する。

```bash
rm -rf out
```

なお `out/*.json` には一時認証情報のアクセスキー ID（`ASIA...`）が含まれる。
シークレットキーは含まれないので単体では使えないが、共有はしないこと。
