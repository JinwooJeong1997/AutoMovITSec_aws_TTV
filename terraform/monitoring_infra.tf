# =============================================================================
# Monitoring Pipeline: SQS Buffer Queue, EventBridge Rules, S3 Cold Storage
#  담당: 노혜린(AWS 파이프라인) · 이승훈(대시보드) — 문희재(웹 인프라)는 관여하지 않음
#  자세한 배경은 README.md "모니터링 파이프라인 작업 가이드" 참고
#
# 0. 시작 전 필수 확인 — Terraform State
#    ------------------------------------------------------------------------
#    backend.tf가 아직 로컬 state로 되어있어 tfstate가 문희재 개인 PC에만 있음.
#    이 상태에서 각자 PC에서 `terraform apply`를 돌리면 Terraform이 기존
#    VPC/ALB/RDS 등을 "존재하지 않음"으로 착각해 통째로 재생성을 시도할 수
#    있음(이름 충돌·중복 리소스 위험). 원격 백엔드(S3)가 준비되기 전까지는
#    코드 작성/PR까지만 진행하고, apply는 문희재에게 요청하거나 기존
#    terraform.tfstate를 공유받은 뒤에 실행할 것.
#
# 1. 이미 만들어져 있는 것 — 새로 만들지 말고 아래 리소스를 그대로 참조
#    ------------------------------------------------------------------------
#    같은 terraform/ 디렉터리(= 같은 state)이므로 데이터 소스 조회 없이
#    리소스 참조로 바로 쓸 수 있음.
#      - VPC:              aws_vpc.main.id
#      - 배치용 서브넷:     aws_subnet.private[*].id (프라이빗 2개 — 새 서브넷 X)
#      - 모니터링 보안 그룹: aws_security_group.monitoring.id
#                           (웹서버 9100/8080 스크레이프, Grafana 3000 인바운드
#                            규칙이 main.tf에 이미 정의되어 있음)
#      - Flow Logs 로그 그룹: aws_cloudwatch_log_group.flow_logs[0].name
#                            ("/automovitsec/vpc-flow-logs")
#      - 웹 ASG/인스턴스 태그: Role = "web" (Prometheus 자동 탐색용, 3번 참고)
#      - SSM 파라미터 네임스페이스: "/automovitsec/..." 하위로 통일
#                                 (DB 접속정보는 이미 /automovitsec/db/* 에 있음)
#
# 2. 이 파일에 채워야 할 것
#    ------------------------------------------------------------------------
#    a) SQS 큐 — worker.py(monitoring/sqs-worker)가 폴링하는 대상.
#       DLQ(Dead Letter Queue)와 큐 지표(ApproximateNumberOfMessagesVisible)
#       CloudWatch 알람도 함께 구성
#    b) CloudWatch Logs 구독 필터 + Lambda — 웹서버 nginx 로그를
#       CloudWatch Logs에서 SQS로 전달. worker.py가 기대하는 메시지 스키마에
#       맞춰서 Lambda가 SQS 메시지를 만들어야 함:
#         { "logGroup": "...", "logStream": "...",
#           "timestamp": 1234567890000, "message": "..." }
#    c) S3 Cold Storage 버킷 — 장기 보관/Athena 조회 대상 (승훈님 파트).
#       s3_uploads.tf의 업로드 버킷과는 용도가 다른 별도 버킷
#    d) 모니터링 EC2(또는 ASG) — 1번의 프라이빗 서브넷 + 모니터링 SG를 사용.
#       ec2_target.tf의 웹서버 launch template과 동일하게 IMDSv2 강제,
#       EBS 암호화 적용. SSH(22) 열지 않고 SSM Session Manager로 접속
#    e) 모니터링 EC2용 IAM 역할(신규) — iam.tf의 웹 역할과 같은 패턴으로 작성.
#       필요 권한: SQS ReceiveMessage/DeleteMessage/GetQueueAttributes,
#       CloudWatch PutMetricData, S3 Cold Storage 버킷 접근, Athena 쿼리,
#       EC2 Describe*(3번의 Prometheus 자동 탐색용), SSM Session Manager.
#       managed policy 통짜 부여보다 커스텀 정책으로 리소스 스코프를 좁힐 것
#
# 3. 결정 필요 — Node Exporter/cAdvisor 존치 여부
#    ------------------------------------------------------------------------
#    메트릭 수집 경로가 CloudWatch Metrics API로 바뀌는 중이라 웹서버의
#    Node Exporter(:9100)/cAdvisor(:8080)가 불필요해질 수 있음.
#      - 불필요 확정 시: user_data/web.sh에서 두 컨테이너 제거 +
#        main.tf의 web-sg 9100/8080 인바운드 규칙 삭제 (문희재가 처리)
#      - 계속 사용 시: 그대로 두고 Role=web 태그로 Prometheus 서비스
#        디스커버리 구성
#    → 대시보드 설계가 정해지면 문희재에게 알려줄 것
#
# 4. 로컬 검증 전 먼저 고쳐야 하는 기존 버그
#    ------------------------------------------------------------------------
#    monitoring/docker-compose.yml의 `generator` 서비스가 `./generator`
#    폴더를 빌드하려는데 레포에 해당 폴더가 없어 `docker compose up`이
#    바로 실패함. Alloy 제거 후 안 쓰는 `alloy-data` 볼륨도 정리 필요
# =============================================================================
