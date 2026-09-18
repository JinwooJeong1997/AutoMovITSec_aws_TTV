variable "project_name" {
  description = "리소스 이름 접두사 / SSM 파라미터 경로(/{project_name}/...) 접두사"
  type        = string
  default     = "automovitsec"
}

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

# -----------------------------------------------------------------------------
# 네트워크
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "사용할 가용 영역 (ALB, RDS 서브넷 그룹은 최소 2개 필요)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "웹서버/모니터링 서버가 위치하는 프라이빗 서브넷"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_subnet_cidrs" {
  description = "RDS 전용 프라이빗 서브넷 (웹서버 서브넷과 분리)"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "enable_flow_logs" {
  description = "VPC Flow Logs 생성 여부 (연습 시 false로 끄면 리소스와 비용이 줄어듦)"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "VPC Flow Logs 보관 기간(일). 장기 보관은 S3 Cold 스토리지로 넘기는 구조"
  type        = number
  default     = 14
}

variable "admin_cidrs" {
  description = "Grafana(3000) 접근을 허용할 팀원 공인 IP 목록 (예: [\"1.2.3.4/32\"]). 비워두면 SSM 포트 포워딩으로 접속"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# 웹서버군
# -----------------------------------------------------------------------------
variable "web_instance_type" {
  type    = string
  default = "t3.micro"
}

# 초반(임시 타깃 서버)에는 1대 → 검증 후 3으로 바꾸면 정식 웹서버군으로 전환
variable "web_desired_capacity" {
  type    = number
  default = 1
}

variable "web_min_size" {
  type    = number
  default = 1
}

variable "web_max_size" {
  type    = number
  default = 3
}

variable "app_image" {
  description = "웹서버에서 실행할 앱 컨테이너 이미지. ECR 준비 전까지는 공개 nginx 이미지로 임시 운영"
  type        = string
  default     = "public.ecr.aws/docker/library/nginx:1.27-alpine"
}

# -----------------------------------------------------------------------------
# DB 계층 (RDS for MySQL)
# -----------------------------------------------------------------------------
variable "db_engine_version" {
  description = "MySQL 메이저 버전"
  type        = string
  default     = "8.0"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "GiB 단위. gp3 스토리지"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "초기 생성할 스키마 이름"
  type        = string
  default     = "appdb"
}

variable "db_master_username" {
  type    = string
  default = "appadmin"
}

variable "db_multi_az" {
  description = "실습 환경은 비용 절감을 위해 false. 운영 전환 시 true 고려"
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 1
}

variable "db_deletion_protection" {
  description = "실습 중 destroy가 잦으므로 false. 운영 전환 시 true로 변경"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# 업로드 저장소 (S3)
# -----------------------------------------------------------------------------
variable "uploads_bucket_force_destroy" {
  description = "실습 환경 편의용. 버킷에 객체가 남아 있어도 destroy 허용. 운영 전환 시 false로 변경"
  type        = bool
  default     = true
}
