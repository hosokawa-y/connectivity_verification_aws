#!/usr/bin/env python3
"""verify.sh が取得した Lambda のレスポンスを期待値と突き合わせる。

観測項目は doc/cross_acount_test.html の「検証結果」に合わせている。
"""

import argparse
import json
import sys

OK = "OK"
NG = "NG"


class Checker:
    def __init__(self):
        self.failed = 0

    def check(self, label, actual, expected):
        hit = actual == expected
        self._print(label, hit, actual, expected)

    def check_prefix(self, label, actual, prefix):
        hit = isinstance(actual, str) and actual.startswith(prefix)
        self._print(label, hit, actual, f"{prefix}... で始まる")

    def _print(self, label, hit, actual, expected):
        if not hit:
            self.failed += 1
        mark = OK if hit else NG
        print(f"[{mark}] {label}")
        print(f"       実測: {actual!r}")
        if not hit:
            print(f"       期待: {expected!r}")

    @staticmethod
    def info(label, value):
        print(f"[--] {label}")
        print(f"       {value}")

    @staticmethod
    def skip(label, reason):
        print(f"[--] {label} … 判定不能 ({reason})")


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--signed", required=True)
    parser.add_argument("--unsigned", required=True)
    parser.add_argument("--account-b", required=True)
    parser.add_argument("--role-name", required=True)
    parser.add_argument("--session-name", required=True)
    parser.add_argument("--lambda-role-name", required=True)
    args = parser.parse_args()

    signed = load(args.signed)
    unsigned = load(args.unsigned)

    for name, payload in (("signed", signed), ("unsigned", unsigned)):
        if "errorMessage" in payload:
            print(f"[{NG}] Lambda ({name}) が例外終了しました")
            print(f"       {payload.get('errorType')}: {payload['errorMessage']}")
            return 1

    checker = Checker()
    expected_caller_arn = (
        f"arn:aws:sts::{args.account_b}:assumed-role/"
        f"{args.role_name}/{args.session_name}"
    )

    # --- 経路 (1) AssumeRole 前後で principal が切り替わっているか ---
    before_arn = signed.get("callerIdentityBeforeAssume", {}).get("arn", "")
    checker.check_prefix(
        "AssumeRole 前の principal がアカウント A の Lambda 実行ロール",
        before_arn,
        f"arn:aws:sts::{signed.get('callerIdentityBeforeAssume', {}).get('account')}"
        f":assumed-role/{args.lambda_role_name}/",
    )
    checker.check(
        "AssumeRole 後の principal がアカウント B の assumed-role",
        signed.get("callerIdentityAfterAssume", {}).get("arn"),
        expected_caller_arn,
    )
    checker.check(
        "AssumeRole 後のアカウントが B",
        signed.get("callerIdentityAfterAssume", {}).get("account"),
        args.account_b,
    )

    # --- 経路 (2) SigV4 署名が付いているか ---
    header_names = signed.get("signedHeaderNames", [])
    for header in ("authorization", "x-amz-date", "x-amz-security-token"):
        checker.check(f"署名ヘッダ {header} が付与されている", header in header_names, True)

    # --- 経路 (3) API Gateway の IAM 認可を通過したか ---
    api = signed.get("apiResponse", {})
    checker.check("署名ありの HTTP ステータス", api.get("statusCode"), 200)

    body = api.get("body")

    if api.get("statusCode") != 200:
        # 200 でない時点で B 側の観測項目は存在しない。原因は API のレスポンス本文に出る。
        print()
        print("  API のレスポンス本文 (原因の手掛かり):")
        print(f"    {json.dumps(body, ensure_ascii=False)}")
        print()
        print("  よくある原因 (doc/cross_acount_test.html より):")
        print("    - 403 Credential should be scoped to a valid region")
        print("        -> 署名リージョンが呼び出し先 API のものになっていない (var.api_region)")
        print("    - 403 no identity-based policy allows the execute-api:Invoke action")
        print("        -> B 側ロールに execute-api:Invoke が付いていない (信頼と権限は別物)")
        print("    - 403 Missing Authentication Token")
        print("        -> 署名が付いていない / メソッド・パスが一致していない")
        print("    - 502 Internal server error")
        print("        -> 認可は通過済み。B 側 Lambda の実装かハンドラ設定の問題")
        print()
        for label in (
            "B 側で authenticated=true",
            "B 側で観測された accountId",
            "B 側で観測された userArn",
            "caller が AROA 始まり",
            "RoleSessionName の伝播",
            "本文の到達",
        ):
            checker.skip(label, "API が 200 を返していない")
    elif isinstance(body, dict):
        caller = body.get("caller", {})
        checker.check("B 側で authenticated=true", caller.get("authenticated"), True)
        checker.check(
            "B 側で観測された accountId が B (A の ID は現れない)",
            caller.get("accountId"),
            args.account_b,
        )
        checker.check(
            "B 側で観測された userArn", caller.get("userArn"), expected_caller_arn
        )
        checker.check_prefix(
            "caller がロール由来の一時認証情報 (AROA 始まり)",
            caller.get("caller"),
            "AROA",
        )
        checker.check(
            "RoleSessionName が B 側にそのまま現れる",
            caller.get("sessionName"),
            args.session_name,
        )
        checker.check(
            "SigV4 のペイロードハッシュ検証を通過し本文が届いている",
            body.get("request", {}).get("receivedBody"),
            signed.get("requestBody"),
        )
        checker.info("B 側バックエンド", body.get("backend", {}).get("functionArn"))
        checker.info(
            "sourceIp (実行ごとに変わる。IP による制限には使えない)",
            caller.get("sourceIp"),
        )
    else:
        checker.check("B のレスポンス本文が JSON", type(body).__name__, "dict")

    # --- 経路 (4) 署名なしは拒否されるか ---
    checker.check(
        "署名なしの HTTP ステータス",
        unsigned.get("apiResponse", {}).get("statusCode"),
        403,
    )

    if "warning" in signed:
        print(f"[!!] {signed['warning']}")

    print()
    if checker.failed:
        print(f"結果: NG ({checker.failed} 件の不一致)")
        return 1
    print("結果: すべて期待通り。経路は成立している。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
