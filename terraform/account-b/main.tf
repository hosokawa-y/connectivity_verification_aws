data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.owner}-b"

  # アカウント A 側の Lambda 実行ロール名。account-a と同じ式で導出するため、
  # project / owner が一致していれば名前がずれない。
  caller_role_name = "${var.project}-${var.owner}-caller-role"

  # アカウント A 側の Lambda 実行ロール。
  # 信頼ポリシーの principal に直接この ARN を書くと、A 側をまだ apply して
  # いない場合に IAM が "Invalid principal" で拒否する。そのため principal は
  # アカウント A の root にし、aws:PrincipalArn 条件でこのロールだけに絞る。
  # (assumed-role セッション ARN 形式でも一致するよう 2 パターン許可する)
  caller_principal_patterns = [
    "arn:aws:iam::${var.account_a_id}:role/${local.caller_role_name}",
    "arn:aws:sts::${var.account_a_id}:assumed-role/${local.caller_role_name}/*",
  ]

  # ExternalId は指定が無ければ自動生成し、account_a_tfvars 出力で A 側に渡す。
  # これにより A / B の値がずれて AccessDenied になる事故を防ぐ。
  external_id = var.external_id != "" ? var.external_id : random_uuid.external_id.result
}

resource "random_uuid" "external_id" {}

# ---------------------------------------------------------------------------
# バックエンド Lambda (API Gateway プロキシ統合)
# ---------------------------------------------------------------------------

data "archive_file" "echo" {
  type        = "zip"
  source_file = "${path.module}/lambda/echo_handler.py"
  output_path = "${path.module}/.build/echo_handler.zip"
}

data "aws_iam_policy_document" "echo_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "echo" {
  name               = "${local.name_prefix}-echo-role"
  assume_role_policy = data.aws_iam_policy_document.echo_assume.json
}

resource "aws_iam_role_policy_attachment" "echo_basic" {
  role       = aws_iam_role.echo.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "echo" {
  name              = "/aws/lambda/${local.name_prefix}-echo"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "echo" {
  function_name    = "${local.name_prefix}-echo"
  role             = aws_iam_role.echo.arn
  handler          = "echo_handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.echo.output_path
  source_code_hash = data.archive_file.echo.output_base64sha256
  timeout          = 10

  depends_on = [
    aws_iam_role_policy_attachment.echo_basic,
    aws_cloudwatch_log_group.echo,
  ]
}

# ---------------------------------------------------------------------------
# API Gateway REST API (IAM 認可)
# ---------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "this" {
  name = "${local.name_prefix}-api"
  # IAM 認可付きのクロスアカウント検証用 API
  # AWS 側の description は ASCII のみ (IAM ロールの制約に合わせて統一)
  description = "Cross-account verification API with IAM authorization"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "verify" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = var.resource_path
}

# authorization = AWS_IAM が本検証の核心。
# 署名なし / 権限のない principal からの呼び出しは 403 になる。
resource "aws_api_gateway_method" "verify" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.verify.id
  http_method   = var.http_method
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "verify" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.verify.id
  http_method = aws_api_gateway_method.verify.http_method
  type        = "AWS_PROXY"
  # Lambda プロキシ統合では常に POST。var.http_method (クライアントが使うメソッド) とは別物。
  integration_http_method = "POST"
  uri                     = aws_lambda_function.echo.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.echo.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/${var.http_method}/${var.resource_path}"
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.verify.id,
      aws_api_gateway_method.verify.id,
      aws_api_gateway_integration.verify.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name
}

# ---------------------------------------------------------------------------
# アカウント A から AssumeRole される側のロール
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cross_account_assume" {
  statement {
    sid     = "AllowAccountACallerRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_a_id}:root"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = local.caller_principal_patterns
    }

    # 記録 (doc/) の構成に合わせ ExternalId を必須にする
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.external_id]
    }
  }
}

resource "aws_iam_role" "cross_account" {
  name = "${local.name_prefix}-invoke-api-role"
  # アカウント A の Lambda が AssumeRole して API Gateway を叩くためのロール。
  # IAM ロールの description は ASCII のみ受け付ける (日本語を入れると
  # CreateRole が ValidationError になる)。
  description          = "Assumed by account A Lambda to invoke the verification API"
  assume_role_policy   = data.aws_iam_policy_document.cross_account_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "invoke_api" {
  statement {
    sid     = "InvokeVerifyEndpoint"
    effect  = "Allow"
    actions = ["execute-api:Invoke"]

    resources = [
      "${aws_api_gateway_rest_api.this.execution_arn}/${var.stage_name}/${var.http_method}/${var.resource_path}",
    ]
  }
}

resource "aws_iam_role_policy" "invoke_api" {
  name   = "invoke-api"
  role   = aws_iam_role.cross_account.id
  policy = data.aws_iam_policy_document.invoke_api.json
}
