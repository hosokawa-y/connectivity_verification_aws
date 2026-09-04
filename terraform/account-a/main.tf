data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.owner}-a"

  # account-b の信頼ポリシー条件と一致させる必要があるため、同じ式で導出する。
  caller_role_name = "${var.project}-${var.owner}-caller-role"

  # B 側の assumed-role ARN 末尾に現れる。誰のセッションか分かるようにする。
  role_session_name = var.role_session_name != "" ? var.role_session_name : "${var.owner}-verify"

  # arn:aws:iam::<account-b-id>:role/<name> から B のアカウント ID を取り出す
  account_b_id = split(":", var.target_role_arn)[4]
}

# ---------------------------------------------------------------------------
# Lambda 実行ロール
#   - 名前は account-b の信頼ポリシー条件と一致させる必要があるため固定
#   - 付与する権限は「B のロールを AssumeRole する」ことだけ
#     (API 呼び出し権限は B のロール側が持つ)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "caller" {
  name = local.caller_role_name
  # アカウント B のロールを AssumeRole して API Gateway を呼ぶ Lambda の実行ロール。
  # IAM ロールの description は ASCII のみ受け付ける。
  description        = "Lambda execution role that assumes the account B role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "caller_basic" {
  role       = aws_iam_role.caller.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "assume_target_role" {
  statement {
    sid       = "AssumeAccountBRole"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [var.target_role_arn]
  }
}

resource "aws_iam_role_policy" "assume_target_role" {
  name   = "assume-account-b-role"
  role   = aws_iam_role.caller.id
  policy = data.aws_iam_policy_document.assume_target_role.json
}

# ---------------------------------------------------------------------------
# 呼び出し元 Lambda
# ---------------------------------------------------------------------------

data "archive_file" "caller" {
  type        = "zip"
  source_file = "${path.module}/lambda/caller_handler.py"
  output_path = "${path.module}/.build/caller_handler.zip"
}

resource "aws_cloudwatch_log_group" "caller" {
  name              = "/aws/lambda/${local.name_prefix}-caller"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "caller" {
  function_name    = "${local.name_prefix}-caller"
  role             = aws_iam_role.caller.arn
  handler          = "caller_handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.caller.output_path
  source_code_hash = data.archive_file.caller.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      TARGET_ROLE_ARN   = var.target_role_arn
      TARGET_API_URL    = var.target_api_url
      HTTP_METHOD       = var.http_method
      ROLE_SESSION_NAME = local.role_session_name
      # 署名リージョンは呼び出し先 API のもの。関数自身の AWS_REGION とは別に持つ。
      API_REGION  = var.api_region
      EXTERNAL_ID = var.external_id
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.caller_basic,
    aws_iam_role_policy.assume_target_role,
    aws_cloudwatch_log_group.caller,
  ]
}
