# Cloud Security SOAR & DevSecOps Monitoring Project

Shift-Left 보안(배포 전 차단)과 중앙 관제(운영 중 탐지)를 결합한 AWS DevSecOps 아키텍처.

## 프로젝트 구조 & 담당 폴더

| 폴더 | 담당 | 내용 | 참고할 것 |
|---|---|---|---|
| `terraform/` | **문희재** (웹 인프라) | VPC/서브넷/SG/라우팅, 웹서버군(EC2·ALB·ASG), RDS(MySQL), 업로드용 S3, IAM | `terraform/outputs.tf`(다른 파트가 참조하는 값), `terraform.tfvars.example` |
| `app/` | 정진우 (PM/파이프라인) | 웹 서비스 컨테이너 소스 & Dockerfile | `terraform` output의 `alb_url`, `web_asg_name` |
| `monitoring/` | 노혜린 · 이승훈 (대시보드/파이프라인) | Loki + Grafana + SQS 워커 (Docker Compose 기반 관제 스택) | `terraform` output의 `flow_log_group_name`, `monitoring_sg_id`. **인프라 담당자가 임의로 수정하지 않음** |
| `.github/workflows/` | 정진우 (PM) | CI/CD 파이프라인 정의 | 아래 "CI/CD 동작 방식" 참고 |

`terraform/monitoring_infra.tf`는 모니터링 파이프라인(SQS 버퍼 큐, EventBridge, S3 Cold Storage)용 인프라 코드 자리이며, 담당자가 정해지면 채웁니다. 서브넷/보안 그룹(`monitoring_sg_id`)은 이미 `terraform/main.tf`에 준비되어 있으니 새로 만들지 말고 참조하세요.

## 작업 규칙 (공통)

- `main`에 직접 push 금지. 브랜치 생성 후 PR로 병합
- `terraform/`을 건드릴 때는 커밋 전에 **반드시** 아래 3개를 로컬에서 실행
  ```
  terraform fmt -recursive
  terraform validate
  trivy config terraform/
  ```
- `.tf` 파일은 BOM 없이 UTF-8, 줄바꿈 LF
- 자격 증명(`terraform.tfvars`, `terraform.tfstate`, `.env`, `*.pem`)은 커밋 금지 — `.gitignore`가 막아주지만 `git add` 후 `git status`로 한 번 더 확인
- 개인 값이 필요하면 `terraform/terraform.tfvars.example`을 복사해서 `terraform.tfvars`로 사용 (이 파일은 커밋되지 않음)

## CI/CD 동작 방식 — 누가 push하면 무엇이 실행되는가

두 개의 워크플로가 **경로별로** 분리되어 있습니다 (`.github/workflows/`).

### Track A — `infra-deploy.yml` (`terraform/**` 변경 시, `main` push)
1. `terraform fmt -check` → `terraform init` → `terraform plan`까지만 실행
2. **아직 `terraform apply`는 자동으로 되지 않습니다.** plan 결과만 확인하는 단계
3. **현재 갭:** AWS 자격 증명을 얻는 스텝이 없어서, 이 워크플로는 지금 push해도 `init`/`plan`에서 인증 오류로 실패합니다. 팀 계정용 OIDC 역할이 준비되기 전까지는 그렇습니다 (담당: 정진우, `CLAUDE.md` 이슈 11)
4. 그래서 **실제로 AWS에 반영(apply)하려면 지금은 담당자가 로컬에서 `terraform apply`를 수동 실행**해야 합니다. 파이프라인에 OIDC 인증 + apply 스텝이 추가되고 나서야 "PR 병합 = 자동 반영" 구조가 됩니다

### Track B — `app-deploy.yml` (`app/**` 변경 시, `main` push)
1. Docker 빌드 → Trivy 이미지 취약점 스캔(CRITICAL/HIGH 발견 시 실패)까지만 실행
2. ECR 푸시, EC2 배포 스텝은 아직 주석 처리(미구현) 상태 — 즉 이것도 자동 배포는 아직 안 됨

### `monitoring/**` 변경
- **이 경로를 트리거하는 워크플로가 아예 없습니다.** 모니터링 스택(Loki/Grafana/SQS 워커) 변경은 지금은 CI 없이 각자 로컬 `docker compose`로 검증 후 PR 리뷰로만 반영됩니다

> 요약: 지금 이 시점에서는 **어떤 폴더를 push해도 AWS 인프라나 실제 서버가 자동으로 바뀌지 않습니다.** Terraform은 `plan`까지만(그나마 인증 없어 실패), 앱은 빌드+스캔까지만 자동화되어 있고, 최종 반영(`apply`, 배포)은 담당자의 수동 작업입니다.

## `terraform/` 인프라 세팅 가이드

새 팀 AWS 계정 기준 — 어제 개인 계정에서 apply했던 것과는 별개로 처음부터 구성합니다.

1. `cp terraform.tfvars.example terraform.tfvars` 후 값 채우기
2. AWS 자격 증명은 팀 계정용으로 새로 설정 (`aws configure --profile <team-profile>` 등). 기존에 이 머신에 남아있는 개인/샘플 계정 자격 증명을 그대로 쓰지 않도록 주의
3. `terraform init` (원격 백엔드는 `backend.tf` — 버킷이 준비되기 전까지는 로컬 state로 진행)
4. `terraform plan` 확인 후 `terraform apply`
5. `terraform output`으로 `alb_url`, `db_endpoint`, `uploads_bucket_name` 등을 확인해 다른 파트에 공유

### 이번에 추가된 것 (DB 계층 + 업로드)
- RDS for MySQL (`terraform/rds.tf`): 전용 DB 서브넷(격리)에 배치, 웹 보안 그룹에서만 3306 접근 허용
- DB 접속 정보(호스트/포트/DB명/계정/비밀번호)는 SSM 파라미터 스토어 `/{project_name}/db/*`에 저장. 비밀번호는 SecureString
- 업로드 파일 저장용 S3 버킷 (`terraform/s3_uploads.tf`): 퍼블릭 차단 + 암호화 + 버전 관리. 버킷 이름은 `/{project_name}/uploads/bucket_name` SSM 파라미터로도 조회 가능
- 웹서버 IAM 역할에 위 SSM 파라미터 읽기 + 업로드 버킷 read/write 권한 추가 (`terraform/iam.tf`)
- `client_max_body_size 10m` (Nginx), 앱 보안 이벤트 로그 디렉터리 `/var/log/app/` 준비, IMDS hop limit 1→2 (컨테이너 내 앱이 SDK로 S3/SSM에 접근 가능하도록)

### 아직 보류 중인 것 (CLAUDE.md 참고)
- Nginx `realip` 설정, Node Exporter/cAdvisor 유지 여부 — 메트릭 경로 재검토 후 결정
- tfstate 원격 백엔드, GitHub Actions OIDC 역할 — 담당자 미정
