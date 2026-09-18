# =============================================================================
# 웹서버용 IAM 역할 (인스턴스 프로파일)
#  - SSM: SSH(22) 없이 Session Manager로 접속, Run Command로 배포
#  - CloudWatch Agent: 로그 송출 (노혜린)
#  - ECR ReadOnly: 앱 이미지 pull (정진우 파이프라인)
#  - SSM 파라미터 스토어 읽기: DB 접속 정보 조회 (rds.tf)
#  - S3: 업로드 버킷 읽기/쓰기 (s3_uploads.tf)
# =============================================================================
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "web" {
  name               = "${var.project_name}-web-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "web" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.web.name
  policy_arn = each.value
}

# 앱이 조회할 SSM 파라미터는 /{project_name}/* 아래로만 한정 (최소 권한)
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

data "aws_iam_policy_document" "web_app" {
  statement {
    sid = "ReadAppParameters"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"]
  }

  statement {
    sid       = "DecryptSecureStringParameters"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }

  statement {
    sid = "UploadsBucketObjectAccess"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]
  }

  statement {
    sid       = "UploadsBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.uploads.arn]
  }
}

resource "aws_iam_role_policy" "web_app" {
  name   = "app-ssm-and-s3-access"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.web_app.json
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.project_name}-web-profile"
  role = aws_iam_role.web.name
}

# TODO(팀 협의):
#  - 모니터링 서버용 역할 (SQS 읽기, S3/Athena, EC2 Describe → Prometheus 자동 탐색) — monitoring_infra.tf 담당자
#  - GitHub Actions용 OIDC 역할 (정진우 파이프라인에서 terraform apply / ECR push) — 담당자 미정
