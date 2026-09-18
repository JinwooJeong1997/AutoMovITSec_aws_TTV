# =============================================================================
# 업로드 저장소: S3
#  - 버킷 이름은 계정별로 전역 유일해야 하므로 계정 ID를 접미사로 사용
#  - 퍼블릭 접근 전면 차단 + 기본 암호화 + 버전 관리(덮어쓰기 공격 대비)
#  - 접근 권한은 웹서버 IAM 역할에만 부여 (iam.tf 참고)
# =============================================================================

resource "aws_s3_bucket" "uploads" {
  bucket        = "${var.project_name}-uploads-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.uploads_bucket_force_destroy

  tags = { Name = "${var.project_name}-uploads" }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 미완료 멀티파트 업로드 정리(비용 방지)
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_ssm_parameter" "uploads_bucket_name" {
  name  = "${local.ssm_prefix}/uploads/bucket_name"
  type  = "String"
  value = aws_s3_bucket.uploads.bucket
}
