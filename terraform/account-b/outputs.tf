output "account_b_id" {
  description = "アカウント B のアカウント ID"
  value       = data.aws_caller_identity.current.account_id
}

output "api_id" {
  description = "API Gateway の REST API ID"
  value       = aws_api_gateway_rest_api.this.id
}

output "api_invoke_url" {
  description = "検証エンドポイントの URL (account-a の var.target_api_url に渡す)"
  value       = "${aws_api_gateway_stage.this.invoke_url}/${var.resource_path}"
}

output "api_region" {
  description = <<-EOT
    API のリージョン。SigV4 の署名リージョンはこの値を使う必要がある
    (呼び出し元 Lambda 自身のリージョンではない)。
  EOT
  value       = var.region
}

output "http_method" {
  description = "検証エンドポイントの HTTP メソッド"
  value       = var.http_method
}

output "target_role_arn" {
  description = "アカウント A が AssumeRole する対象ロールの ARN (account-a の var.target_role_arn に渡す)"
  value       = aws_iam_role.cross_account.arn
}

output "target_role_name" {
  description = "AssumeRole 対象ロール名 (検証時に呼び出し元 ARN を突き合わせるのに使う)"
  value       = aws_iam_role.cross_account.name
}

output "external_id" {
  description = "AssumeRole に要求される ExternalId"
  value       = local.external_id
  sensitive   = true
}

output "expected_caller_arn_prefix" {
  description = "B 側で観測されるはずの呼び出し元 principal のプレフィックス"
  value       = "arn:aws:sts::${data.aws_caller_identity.current.account_id}:assumed-role/${aws_iam_role.cross_account.name}/"
}

output "owner" {
  description = "リソースの作成者識別子"
  value       = var.owner
}

output "caller_role_name" {
  description = "信頼ポリシーで許可しているアカウント A 側のロール名"
  value       = local.caller_role_name
}

output "account_a_tfvars" {
  description = "account-a にそのまま渡せる tfvars (scripts/deploy.sh が書き出す)"
  sensitive   = true
  value       = <<-EOT
    project         = "${var.project}"
    owner           = "${var.owner}"
    target_role_arn = "${aws_iam_role.cross_account.arn}"
    target_api_url  = "${aws_api_gateway_stage.this.invoke_url}/${var.resource_path}"
    api_region      = "${var.region}"
    http_method     = "${var.http_method}"
    external_id     = "${local.external_id}"
  EOT
}
