"""アカウント B 側のバックエンド (API Gateway プロキシ統合)。

API Gateway の IAM 認可 (AWS_IAM) を通過した「呼び出し元が誰か」をそのまま返す。
これにより、アカウント A の Lambda -> AssumeRole -> SigV4 署名という経路で
実際に B に届いた principal を検証できる。

doc/cross_acount_test.html の rsq-caller-identity-echo と同じ観測項目を返す。
"""

import json
import os


def _session_name(user_arn):
    """assumed-role ARN の末尾から RoleSessionName を取り出す。

    A 側が指定した RoleSessionName がそのまま現れるので、
    どの呼び出し元セッションが届いたのか識別できる。
    """
    if not user_arn or ":assumed-role/" not in user_arn:
        return None
    return user_arn.rsplit("/", 1)[-1]


def handler(event, context):
    request_context = event.get("requestContext") or {}
    identity = request_context.get("identity") or {}
    user_arn = identity.get("userArn")

    caller = {
        # AssumeRole で得た一時認証情報の principal (B の assumed-role ARN)
        "userArn": user_arn,
        # 呼び出し元アカウント。ロールが B のものなので B の ID になり、A の ID は現れない
        "accountId": identity.get("accountId"),
        # 先頭が AROA ならロール由来の一時認証情報である証跡 (IAM ユーザー直呼びなら AIDA)
        "caller": identity.get("caller"),
        "user": identity.get("user"),
        "accessKey": identity.get("accessKey"),
        # Lambda の送信元 IP。固定されないので IP による制限には使えない
        "sourceIp": identity.get("sourceIp"),
        "sessionName": _session_name(user_arn),
        # AWS_IAM 認可を通過したか。署名なしなら API Gateway が 403 を返すのでここには来ない
        "authenticated": bool(user_arn),
        "requestId": request_context.get("requestId"),
    }

    # CloudWatch Logs にも残す (B 側だけで呼び出し元を追跡できるように)
    print(json.dumps({"callerIdentity": caller}, ensure_ascii=False))

    body = {
        "ok": True,
        "message": "reached account B backend",
        "caller": caller,
        "backend": {
            "accountId": request_context.get("accountId"),
            "functionArn": context.invoked_function_arn,
            "region": os.environ.get("AWS_REGION"),
        },
        "request": {
            "httpMethod": request_context.get("httpMethod"),
            "resourcePath": request_context.get("resourcePath"),
            "stage": request_context.get("stage"),
            # A 側が送った本文。SigV4 のペイロードハッシュ検証が通った証跡になる
            "receivedBody": event.get("body"),
        },
    }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }
