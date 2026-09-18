terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  # 모든 리소스에 공통 태그 자동 부여
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # SSM 파라미터 경로 접두사. CloudWatch Agent 설정(/automovitsec/cwagent-config)과 동일한 규칙
  ssm_prefix = "/${var.project_name}"
}

# =============================================================================
# 1. VPC (우리 팀 전용 단지)
# =============================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

# VPC Flow Logs — 네트워크 접속 기록 (침해 분석 시 "누가 어디로 접속했나" 추적용)
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/${var.project_name}/vpc-flow-logs"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_write" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.project_name}-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_write[0].json
}

resource "aws_flow_log" "main" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60
}

# 기본 보안 그룹은 모든 트래픽을 막아 둠 (Trivy/Checkov 권장 사항)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-default-sg-locked" }
}

# =============================================================================
# 2. 서브넷 (2개 AZ × 퍼블릭/프라이빗/DB)
#    퍼블릭: ALB, NAT / 프라이빗: 웹서버, 모니터링 서버 / DB: RDS 전용(계층 분리)
# =============================================================================
resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # 퍼블릭 서브넷이라도 IP 자동 할당은 끔 (ALB, NAT는 자체적으로 IP를 받음)
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-public-${substr(var.azs[count.index], -1, 1)}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = length(var.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project_name}-private-${substr(var.azs[count.index], -1, 1)}"
    Tier = "private"
  }
}

resource "aws_subnet" "db" {
  count = length(var.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project_name}-db-${substr(var.azs[count.index], -1, 1)}"
    Tier = "db"
  }
}

# =============================================================================
# 3. 출입문(IGW, NAT)과 길 안내(라우팅 테이블)
# =============================================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# NAT는 비용 절감을 위해 1개만 (첫 번째 퍼블릭 서브넷에 배치)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project_name}-nat" }

  depends_on = [aws_internet_gateway.main]
}

# 퍼블릭: 인터넷(0.0.0.0/0) → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 프라이빗(웹서버/모니터링): 인터넷(0.0.0.0/0) → NAT (나가기만 가능)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# DB 서브넷: 인터넷 경로 없음(완전 격리). RDS는 아웃바운드 인터넷이 필요 없음
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-db-rt" }
}

resource "aws_route_table_association" "db" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# =============================================================================
# 4. 보안 그룹 (각 집의 경비원)
#    규칙은 IP가 아니라 "보안 그룹 참조"로 연결 → 인스턴스가 바뀌어도 유지됨
#    (RDS용 보안 그룹은 rds.tf에서 정의)
# =============================================================================
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Public ALB for web fleet"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-alb-sg" }
}

resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg"
  description = "Web target fleet (private)"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-web-sg" }
}

resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-monitoring-sg"
  description = "Central monitoring server (private)"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-monitoring-sg" }
}

# --- ALB ---------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet (ZAP scan target)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to web fleet only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.web.id
}

# --- Web ---------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "HTTP from ALB only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "web_node_exporter" {
  security_group_id            = aws_security_group.web.id
  description                  = "Node Exporter scrape from monitoring"
  ip_protocol                  = "tcp"
  from_port                    = 9100
  to_port                      = 9100
  referenced_security_group_id = aws_security_group.monitoring.id
}

resource "aws_vpc_security_group_ingress_rule" "web_cadvisor" {
  security_group_id            = aws_security_group.web.id
  description                  = "cAdvisor scrape from monitoring"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.monitoring.id
}

# 패키지 설치, ECR pull, CloudWatch/SSM 통신을 위해 외부로 나가는 HTTPS/HTTP 허용
resource "aws_vpc_security_group_egress_rule" "web_https" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS outbound via NAT (ECR, SSM, CloudWatch, S3, packages)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP outbound via NAT (package repositories)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# DB 계층 접근: 웹서버 → RDS(MySQL, 3306). aws_security_group.db는 rds.tf에서 정의
resource "aws_vpc_security_group_egress_rule" "web_to_db" {
  security_group_id            = aws_security_group.web.id
  description                  = "MySQL to RDS only"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.db.id
}

# --- Monitoring --------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "monitoring_to_web_node" {
  security_group_id            = aws_security_group.monitoring.id
  description                  = "Scrape Node Exporter"
  ip_protocol                  = "tcp"
  from_port                    = 9100
  to_port                      = 9100
  referenced_security_group_id = aws_security_group.web.id
}

resource "aws_vpc_security_group_egress_rule" "monitoring_to_web_cadvisor" {
  security_group_id            = aws_security_group.monitoring.id
  description                  = "Scrape cAdvisor"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.web.id
}

resource "aws_vpc_security_group_egress_rule" "monitoring_https" {
  security_group_id = aws_security_group.monitoring.id
  description       = "HTTPS outbound via NAT (SQS, S3, Athena, images)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Grafana 접근은 팀원 IP만 (admin_cidrs가 비어 있으면 규칙을 만들지 않음 → SSM 포트 포워딩 사용)
resource "aws_vpc_security_group_ingress_rule" "monitoring_grafana" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.monitoring.id
  description       = "Grafana from team IP"
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
  cidr_ipv4         = each.value
}
