output "account_a_id" {
  description = "アカウント A のアカウント ID"
  value       = data.aws_caller_identity.current.account_id
}

output "lambda_function_name" {
  description = "検証用に invoke する Lambda 関数名"
  value       = aws_lambda_function.caller.function_name
}

output "lambda_role_arn" {
  description = "Lambda 実行ロールの ARN (account-b の信頼ポリシーが条件に使う)"
  value       = aws_iam_role.caller.arn
}

output "log_group_name" {
  description = "Lambda のロググループ"
  value       = aws_cloudwatch_log_group.caller.name
}

output "account_b_id" {
  description = "target_role_arn から導出したアカウント B のアカウント ID"
  value       = local.account_b_id
}

output "profile" {
  description = "invoke に使う AWS CLI プロファイル名"
  value       = var.profile
}

output "region" {
  description = "デプロイ先リージョン"
  value       = var.region
}

output "role_session_name" {
  description = "AssumeRole 時の RoleSessionName (B 側の呼び出し元 ARN 末尾に現れる)"
  value       = local.role_session_name
}

output "lambda_role_name" {
  description = "Lambda 実行ロール名 (account-b の caller_role_name と一致していること)"
  value       = aws_iam_role.caller.name
}

output "owner" {
  description = "リソースの作成者識別子"
  value       = var.owner
}
