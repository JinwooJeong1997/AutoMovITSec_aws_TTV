# Outputs — 팀원들이 이 인프라를 참조하는 창구

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "모니터링 서버 배치 시 사용"
  value       = aws_subnet.private[*].id
}

output "db_subnet_ids" {
  description = "RDS 전용 서브넷"
  value       = aws_subnet.db[*].id
}

output "web_sg_id" {
  value = aws_security_group.web.id
}

output "monitoring_sg_id" {
  description = "모니터링 서버에 붙일 보안 그룹 (웹서버 9100/8080 접근 허용됨)"
  value       = aws_security_group.monitoring.id
}

output "db_sg_id" {
  value = aws_security_group.db.id
}

output "alb_url" {
  description = "웹 서비스 접속 주소 / OWASP ZAP 점검 대상 (정진우)"
  value       = "http://${aws_lb.web.dns_name}"
}

output "web_asg_name" {
  description = "배포 대상 식별용 (정진우 app-deploy.yml)"
  value       = aws_autoscaling_group.web.name
}

output "web_role_name" {
  description = "웹서버 IAM 역할 이름 (권한 추가가 필요하면 여기에 연결)"
  value       = aws_iam_role.web.name
}

output "flow_log_group_name" {
  description = "VPC Flow Logs 로그 그룹 (구독 필터로 SQS 파이프라인에 연결 가능, 노혜린)"
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}

output "db_endpoint" {
  description = "RDS 엔드포인트(호스트:포트). 접속 정보는 SSM(/{project_name}/db/*)로도 조회 가능"
  value       = aws_db_instance.mysql.endpoint
}

output "db_ssm_parameter_prefix" {
  description = "DB 접속 정보가 저장된 SSM 파라미터 경로 접두사"
  value       = "${local.ssm_prefix}/db"
}

output "uploads_bucket_name" {
  description = "업로드 파일 저장 S3 버킷"
  value       = aws_s3_bucket.uploads.bucket
}
