variable "project" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "xacct-verify"
}

variable "owner" {
  description = <<-EOT
    リソースの作成者識別子 (例: yourname)。
    アカウント A は開発メンバー共有の検証環境なので、A 側に作るリソース名・ロール名・
    タグにこの値を入れて誰が作ったか分かるようにする。メンバーごとに別の値を設定する。
    account-a 側の var.owner と一致させること (account_a_tfvars 出力経由で自動的に渡る)。
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,20}$", var.owner))
    error_message = "owner は英小文字・数字・ハイフンで 1〜21 文字で指定してください (IAM / Lambda の名前に使うため)。"
  }
}

variable "region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "profile" {
  description = <<-EOT
    アカウント B (呼び出される側) の AWS CLI プロファイル名。
    実値はコミット対象に置かないため既定値を持たない。scripts/deploy.sh が env.local の
    PROFILE_A / PROFILE_B から -var で渡す。手で plan / apply する場合は
    -var profile=<name> を指定する。
  EOT
  type        = string

  validation {
    condition     = length(var.profile) > 0
    error_message = "profile を指定してください (例: -var profile=my-aws-profile)。"
  }
}

variable "account_a_id" {
  description = "アカウント A (呼び出す側) の 12 桁アカウント ID"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_a_id))
    error_message = "account_a_id は 12 桁の数字で指定してください。"
  }
}

variable "external_id" {
  description = <<-EOT
    AssumeRole 時に要求する ExternalId。
    空文字 (既定) の場合は random_uuid で自動生成する。生成値は account_a_tfvars
    出力経由で account-a に渡るため、両側の値は自動的に一致する。
    本番運用では環境変数平文ではなく SSM Parameter Store / Secrets Manager へ置くこと
    (doc/cross_acount_test.html の「運用へ移す前の確認事項」参照)。
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "http_method" {
  description = "検証エンドポイントの HTTP メソッド。SigV4 のペイロードハッシュも検証するため既定は POST。"
  type        = string
  default     = "POST"
}

variable "resource_path" {
  description = "検証エンドポイントのパス (単一セグメント)"
  type        = string
  default     = "verify"
}

variable "stage_name" {
  description = "API Gateway のステージ名"
  type        = string
  default     = "dev"
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持日数"
  type        = number
  default     = 7
}
