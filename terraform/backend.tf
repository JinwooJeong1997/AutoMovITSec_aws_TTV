# =============================================================================
# 원격 상태(tfstate) 저장소 — 팀원과 GitHub Actions가 같은 상태를 공유하기 위해 필요
#  담당자 미정 (팀 협의 필요, CLAUDE.md 5-7)
#
# 사용 방법
#  1) 새 팀 AWS 계정에서 S3 버킷을 콘솔/CLI로 먼저 1회 생성 (버전 관리 + 퍼블릭 액세스 차단 켜기)
#  2) 아래 주석을 해제하고 bucket 이름 수정
#  3) terraform init -migrate-state
#
# use_lockfile(S3 자체 잠금)은 Terraform 1.10 이상에서 동작합니다.
# 더 낮은 버전을 쓴다면 DynamoDB 테이블 잠금(dynamodb_table)을 사용하세요.
# =============================================================================

# terraform {
#   backend "s3" {
#     bucket       = "automovitsec-tfstate-CHANGE-ME"
#     key          = "infra/terraform.tfstate"
#     region       = "ap-northeast-2"
#     encrypt      = true
#     use_lockfile = true
#   }
# }
