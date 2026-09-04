variable "project" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "xacct-verify"
}

variable "owner" {
  description = <<-EOT
    リソースの作成者識別子 (例: yourname)。
    アカウント A は開発メンバー共有の検証環境なので、リソース名・ロール名・タグに
    この値を入れて誰が作ったか分かるようにする。他メンバーのリソースと衝突しない。
    account-b 側の var.owner と一致させること (account_a_tfvars 出力経由で自動的に渡る)。
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
    アカウント A (呼び出す側) の AWS CLI プロファイル名。
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

variable "target_role_arn" {
  description = "AssumeRole する対象ロールの ARN (account-b の target_role_arn 出力)"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/", var.target_role_arn))
    error_message = "target_role_arn は IAM ロールの ARN で指定してください。"
  }
}

variable "target_api_url" {
  description = "呼び出す API のエンドポイント URL (account-b の api_invoke_url 出力)"
  type        = string

  validation {
    condition     = can(regex("^https://", var.target_api_url))
    error_message = "target_api_url は https:// で始まる URL で指定してください。"
  }
}

variable "api_region" {
  description = <<-EOT
    SigV4 の署名に使うリージョン。呼び出し先 API のリージョンであり、
    この Lambda 自身のリージョン (var.region) とは別物として持つ。
    ここを取り違えると API Gateway が
    "Credential should be scoped to a valid region" で 403 を返す
    (doc/cross_acount_test.html のエラー 3)。
  EOT
  type        = string
}

variable "http_method" {
  description = "呼び出す HTTP メソッド。account-b の http_method と一致させること。"
  type        = string
  default     = "POST"
}

variable "role_session_name" {
  description = <<-EOT
    AssumeRole 時の RoleSessionName。B 側の呼び出し元 ARN の末尾に現れる。
    空文字 (既定) なら "<owner>-verify" を使う。アカウント A が共有環境なので、
    誰のセッションかが B 側のログで分かるようにしている。
  EOT
  type        = string
  default     = ""
}

variable "external_id" {
  description = "AssumeRole 時に渡す ExternalId。account-b の出力値をそのまま渡す。"
  type        = string
  sensitive   = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持日数"
  type        = number
  default     = 7
}
