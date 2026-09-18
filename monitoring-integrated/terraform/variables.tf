variable "aws_region" {
  type = string
  default = "ap-northeast-2"
}
variable "name" {
  type = string
  default = "monitoring-integrated"
  validation {
    condition = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "이름은 영문 소문자로 시작하는 3~31자입니다."
  }
}
variable "vpc_id" { type = string }
variable "subnet_id" {
  type = string
  description = "인터넷 게이트웨이로 기본 경로가 있는 기존 퍼블릭 서브넷"
}
variable "key_name" { type = string }
variable "admin_cidr" {
  type = string
  validation {
    condition = can(cidrnetmask(var.admin_cidr)) && endswith(var.admin_cidr, "/32")
    error_message = "관리자 공인 IPv4 /32를 입력하세요."
  }
}
variable "queue_name" {
  type = string
  description = "기존 같은 계정·리전의 SQS Standard 큐"
  validation {
    condition = !endswith(var.queue_name, ".fifo")
    error_message = "Standard 큐를 지정하세요."
  }
}
variable "sqs_kms_key_arn" {
  type = string
  default = null
}
variable "ami_id" {
  type = string
  default = null
  description = "Ubuntu 24.04 amd64 AMI를 지정하면 버전 고정. null은 Canonical 최신 이미지 검색."
}
variable "instance_type" {
  type = string
  default = "t3.medium"
  validation {
    condition = contains(["t3.medium", "t3.large"], var.instance_type)
    error_message = "지원 범위는 t3.medium 또는 t3.large입니다."
  }
}
variable "data_disk_gb" {
  type = number
  default = 40
  validation {
    condition = var.data_disk_gb >= 20 && floor(var.data_disk_gb) == var.data_disk_gb
    error_message = "데이터 디스크는 20GB 이상의 정수입니다."
  }
}
variable "bedrock_model_id" {
  type = string
  default = ""
  description = "Converse API를 지원하고 사용 권한이 있는 모델 ID 또는 추론 프로파일 ARN. 빈 값은 키워드 모드."
  validation {
    condition = var.bedrock_model_id == "" || can(regex("^[A-Za-z0-9:/._-]+$", var.bedrock_model_id))
    error_message = "모델 ID 또는 ARN 형식을 확인하세요."
  }
}
variable "bedrock_resource_arns" {
  type = list(string)
  default = []
  description = "InvokeModel을 허용할 정확한 모델/프로파일 ARN. 교차 리전 모델의 대상 ARN도 포함해야 합니다."
  validation {
    condition = alltrue([for arn in var.bedrock_resource_arns : startswith(arn, "arn:aws:bedrock:") && !strcontains(arn, "*")])
    error_message = "와일드카드 없이 정확한 Bedrock ARN을 지정하세요."
  }
}

variable "enable_cloudwatch_datasource" {
  type = bool
  default = false
  description = "CloudWatch 메트릭 데이터 소스만 추가. AI 검색은 Loki 로그만 지원합니다."
}
