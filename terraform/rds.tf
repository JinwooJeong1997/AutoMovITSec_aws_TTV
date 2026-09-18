# =============================================================================
# DB 계층: RDS for MySQL
#  - 전용 DB 서브넷(격리, 인터넷 경로 없음)에 배치
#  - 접근은 웹서버 보안 그룹에서만 허용 (SQLi 탐지 시연 대상)
#  - 접속 정보(호스트/포트/이름/계정/비밀번호)는 SSM 파라미터 스토어에 저장,
#    앱은 웹서버 IAM 역할로 런타임에 조회 (iam.tf 참고)
# =============================================================================

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "${var.project_name}-db-subnet-group" }
}

resource "aws_security_group" "db" {
  name        = "${var.project_name}-db-sg"
  description = "RDS MySQL (private, web-only)"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_web" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from web fleet only"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.web.id
}

# 마스터 비밀번호는 코드/변수에 두지 않고 무작위 생성 후 SSM SecureString으로만 보관
resource "random_password" "db_master" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_instance" "mysql" {
  identifier     = "${var.project_name}-mysql"
  engine         = "mysql"
  engine_version = var.db_engine_version

  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  max_allocated_storage = var.db_allocated_storage * 2

  db_name  = var.db_name
  username = var.db_master_username
  password = random_password.db_master.result
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period = var.db_backup_retention_days
  deletion_protection     = var.db_deletion_protection
  skip_final_snapshot     = true # 실습 환경: destroy 시 스냅샷 생략(운영 전환 시 false + final_snapshot_identifier 지정)
  apply_immediately       = true

  tags = { Name = "${var.project_name}-mysql" }
}

# --- SSM 파라미터 스토어: 앱/운영자가 조회할 접속 정보 ------------------------
resource "aws_ssm_parameter" "db_host" {
  name  = "${local.ssm_prefix}/db/host"
  type  = "String"
  value = aws_db_instance.mysql.address
}

resource "aws_ssm_parameter" "db_port" {
  name  = "${local.ssm_prefix}/db/port"
  type  = "String"
  value = tostring(aws_db_instance.mysql.port)
}

resource "aws_ssm_parameter" "db_name" {
  name  = "${local.ssm_prefix}/db/name"
  type  = "String"
  value = aws_db_instance.mysql.db_name
}

resource "aws_ssm_parameter" "db_username" {
  name  = "${local.ssm_prefix}/db/username"
  type  = "String"
  value = aws_db_instance.mysql.username
}

resource "aws_ssm_parameter" "db_password" {
  name  = "${local.ssm_prefix}/db/password"
  type  = "SecureString"
  value = random_password.db_master.result
}
