"""アカウント A 側の呼び出し元 Lambda。

検証する経路 (doc/cross_acount_test.html と同じ):
  1. Lambda 実行ロール (アカウント A) の認証情報で sts:AssumeRole (+ ExternalId)
     -> アカウント B のロールの一時認証情報を取得
  2. その一時認証情報で sts:GetCallerIdentity を実行し、principal が
     B 側の assumed-role に切り替わったことを確認
  3. 同じ認証情報で SigV4 署名を作り、B の API Gateway (IAM 認可) を呼ぶ

署名リージョン (API_REGION) は呼び出し先 API のリージョンであり、この関数自身の
リージョン (AWS_REGION) とは別物。取り違えると API Gateway が
"Credential should be scoped to a valid region" で 403 を返す。

イベントパラメータ (すべて任意):
  {
    "skip_signing": true,          # 署名なしで呼び、403 になることを確認する
    "role_session_name": "...",    # 既定は環境変数 ROLE_SESSION_NAME
    "payload": {...}               # 送信する JSON 本文
  }
"""

import json
import os
import urllib.error
import urllib.request
from urllib.parse import urlsplit

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials

SERVICE = "execute-api"
HTTP_TIMEOUT_SECONDS = 10
SESSION_DURATION_SECONDS = 900

ROLE_ARN = os.environ["TARGET_ROLE_ARN"]
API_URL = os.environ["TARGET_API_URL"]
API_REGION = os.environ["API_REGION"]
EXTERNAL_ID = os.environ.get("EXTERNAL_ID", "")
HTTP_METHOD = os.environ.get("HTTP_METHOD", "POST")
DEFAULT_SESSION_NAME = os.environ.get("ROLE_SESSION_NAME", "xacct-verify-a-caller")


def _region_in_url(url):
    """https://<api-id>.execute-api.<region>.amazonaws.com/... の region 部分。

    API_REGION の設定ミスを検知するためだけに使う (署名には API_REGION を使う)。
    """
    host = urlsplit(url).hostname or ""
    parts = host.split(".")
    if len(parts) >= 3 and parts[1] == "execute-api":
        return parts[2]
    return None


def _assume_role(session_name):
    """アカウント B のロールを引き受けて一時認証情報を得る。

    検証用途なので毎回 AssumeRole する (経路全体を毎回通す)。
    本番実装では有効期限まで結果をキャッシュする。
    """
    sts = boto3.client("sts", region_name=os.environ.get("AWS_REGION"))
    params = {
        "RoleArn": ROLE_ARN,
        "RoleSessionName": session_name,
        "DurationSeconds": SESSION_DURATION_SECONDS,
    }
    if EXTERNAL_ID:
        params["ExternalId"] = EXTERNAL_ID

    response = sts.assume_role(**params)
    creds = response["Credentials"]
    credentials = Credentials(
        access_key=creds["AccessKeyId"],
        secret_key=creds["SecretAccessKey"],
        token=creds["SessionToken"],
    ).get_frozen_credentials()

    return credentials, response["AssumedRoleUser"], creds["Expiration"].isoformat()


def _identity_of(credentials):
    """その認証情報が実際にどの principal なのかを STS に問い合わせる。"""
    sts = boto3.client(
        "sts",
        region_name=os.environ.get("AWS_REGION"),
        aws_access_key_id=credentials.access_key,
        aws_secret_access_key=credentials.secret_key,
        aws_session_token=credentials.token,
    )
    identity = sts.get_caller_identity()
    return {
        "account": identity["Account"],
        "arn": identity["Arn"],
        "userId": identity["UserId"],
    }


def _signed_headers(body, credentials):
    """SigV4 署名済みヘッダを作る。

    AWSRequest に本文を渡すことで、署名にペイロードハッシュが含まれる。
    """
    request = AWSRequest(
        method=HTTP_METHOD,
        url=API_URL,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    SigV4Auth(credentials, SERVICE, API_REGION).add_auth(request)
    return dict(request.headers)


def _call_api(body, headers):
    request = urllib.request.Request(
        API_URL,
        data=body.encode("utf-8"),
        headers=headers,
        method=HTTP_METHOD,
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return {
                "statusCode": response.status,
                "body": _maybe_json(response.read().decode("utf-8")),
            }
    except urllib.error.HTTPError as error:
        # 403 も検証結果として意味があるので例外にせず返す
        return {
            "statusCode": error.code,
            "body": _maybe_json(error.read().decode("utf-8")),
        }


def _maybe_json(text):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def handler(event, context):
    event = event or {}
    session_name = event.get("role_session_name") or DEFAULT_SESSION_NAME
    skip_signing = bool(event.get("skip_signing", False))
    body = json.dumps(event.get("payload") or {"hello": "world"})

    result = {
        "config": {
            "targetRoleArn": ROLE_ARN,
            "targetApiUrl": API_URL,
            "httpMethod": HTTP_METHOD,
            "signingRegion": API_REGION,
            "functionRegion": os.environ.get("AWS_REGION"),
            "regionInUrl": _region_in_url(API_URL),
            "externalIdUsed": bool(EXTERNAL_ID),
            "roleSessionName": session_name,
            "skipSigning": skip_signing,
        },
        # AssumeRole する前の principal (= アカウント A の Lambda 実行ロール)
        "callerIdentityBeforeAssume": _identity_of(
            boto3.Session().get_credentials().get_frozen_credentials()
        ),
        "requestBody": body,
    }

    if result["config"]["regionInUrl"] not in (None, API_REGION):
        result["warning"] = (
            "API_REGION と URL のリージョンが一致していません。"
            "署名リージョンは呼び出し先 API のリージョンにする必要があります。"
        )

    if skip_signing:
        # 署名なしのリクエスト。IAM 認可が効いていれば API Gateway が 403 を返す。
        result["apiResponse"] = _call_api(body, {"Content-Type": "application/json"})
        result["expectation"] = "IAM 認可が有効なら statusCode は 403"
        print(json.dumps(result, ensure_ascii=False))
        return result

    credentials, assumed_role_user, expiration = _assume_role(session_name)
    result["assumedRoleUser"] = {
        "arn": assumed_role_user["Arn"],
        "assumedRoleId": assumed_role_user["AssumedRoleId"],
        "expiration": expiration,
    }
    # AssumeRole 後の principal (= アカウント B のロール)
    result["callerIdentityAfterAssume"] = _identity_of(credentials)

    headers = _signed_headers(body, credentials)
    result["signedHeaderNames"] = sorted(k.lower() for k in headers)
    result["apiResponse"] = _call_api(body, headers)
    result["expectation"] = "経路が通っていれば statusCode は 200"

    print(json.dumps(result, ensure_ascii=False))
    return result
