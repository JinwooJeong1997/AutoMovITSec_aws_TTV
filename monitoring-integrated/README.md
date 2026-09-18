# Sentinel — AWS 통합 관제와 선택적 AI 검색

기본 화면은 상단 검색창과 하단 Grafana 대시보드입니다. 검색하지 않으면 전체 서버·최근 15분을 표시하고 패널은 1분마다 갱신합니다. 검색하면 동일 대시보드에 필터가 적용됩니다. `기본 화면` 버튼으로 초기화합니다.

## 구성과 구현 범위

- 기존 SQS → Python Worker → Loki → Grafana. Alloy는 필요하지 않습니다.
- Terraform: 관제 EC2, IAM 역할, SSH 보안 그룹, 배포용 비공개 S3, 별도 암호화 EBS.
- Docker Compose: Worker, Loki, Grafana, Agent API, 인증 게이트웨이.
- AI 검색: Bedrock Converse로 질문을 제한된 JSON 필터로 변환 → 서버 검증 → Loki 조회. 임의 LogQL이나 명령은 모델이 실행하지 않습니다.
- 원본 로그는 모델에 전달하지 않습니다. 사용자가 검색창에 입력한 문장은 전달됩니다.
- 모델 미설정 시 규칙 기반 키워드 검색임을 명시합니다. 직접 필터는 모델 없이 동작합니다.
- 최근 최대 24시간, 서버 1개, IP 1개, 정확한 경로 1개, HTTP 상태 코드 또는 4xx/5xx, 이벤트 유형을 조합할 수 있습니다. 결과 요약·조건·LogQL·최근 최대 50개 로그를 제공합니다.
- 요약은 조회 건수에 기반한 프로그램 생성 문장입니다. AI 원인 분석, 복수 서버 비교, 자유 형식 통계, 알림 생성, 자동 차단은 포함하지 않습니다.
- CloudWatch는 선택적으로 Grafana 데이터 소스만 등록합니다. 기본 8개 패널과 Agent 검색은 Loki 로그용입니다.

## 1. AWS 없이 화면 확인

Linux 또는 WSL2에 Docker Engine/Desktop + Compose v2, Python 3, OpenSSL이 필요합니다.
프로젝트 루트에서:

```bash
python3 scripts/init_local.py
cd runtime
docker compose --profile demo config --quiet
docker compose --profile demo up -d --build
cat secrets/credentials.txt
```

http://localhost:8080 에 접속하여 출력 파일의 `operator` 계정으로 로그인합니다. Grafana는 같은 인증으로 Viewer 권한을 사용합니다. 시작 직후에는 Loki 준비와 이미지 다운로드에 시간이 필요합니다.

검색 예시: `최근 30분 5xx`, `최근 1시간 로그인 실패`, `최근 15분 web-01`, `198.51.100.2 /login`.
합성 로그에는 `synthetic=true`, `environment=demo`가 표시됩니다. 실제 공격이나 차단은 수행하지 않습니다.

```bash
docker compose --profile demo logs --tail=80
# 데모 종료: 데이터는 runtime/data에 유지됩니다.
docker compose --profile demo down
```

데모와 실운영은 별도 디렉터리/서버에서 실행하세요. AWS 프로파일은 데모를 자동 실행하지 않지만 이전 데모 데이터가 있는 저장소를 재사용하면 함께 조회될 수 있습니다.

## 2. Terraform으로 AWS 배포

기존 같은 계정·리전의 VPC, 인터넷 게이트웨이로 나가는 퍼블릭 서브넷, EC2 키페어, SQS Standard 큐가 필요합니다. 웹 EC2, CloudWatch 구독, Lambda, SQS/DLQ는 생성하지 않습니다. SQS redrive policy와 DLQ는 기존 큐 소유자가 설정해야 합니다. 잘못된 메시지가 무한 재수신되지 않도록 DLQ와 보존 기간을 확인하세요.

로컬 AWS 자격증명으로 Terraform을 실행합니다. EC2 내부 애플리케이션은 IAM 역할을 사용합니다. 자격증명 파일은 컨테이너에 마운트하지 않습니다.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars의 VPC·서브넷·키페어·관리자 공인 IP/32·큐 이름 수정
terraform init
terraform fmt
terraform validate
terraform plan -out=monitor.tfplan
terraform apply monitor.tfplan
terraform output -raw ssh_tunnel
```

apply는 유료 자원을 생성합니다. AI를 켜면 Bedrock 사용 비용도 추가됩니다. 출력된 SSH 명령의 YOUR_KEY.pem을 실제 경로로 바꿔 실행합니다. EC2에서:

```bash
sudo cloud-init status --wait
sudo systemctl status monitoring --no-pager
sudo test -f /opt/monitoring/bootstrap-complete
sudo cat /srv/monitoring-data/secrets/credentials.txt
```

PC에서 http://localhost:8080 접속 후 로그인합니다. 비밀번호는 EC2에서 생성되며 Terraform state에는 저장되지 않습니다. `8080`, `3000`, `3100`을 보안 그룹에서 열지 않습니다. SSH 터널은 실행 상태로 유지하세요.

## 3. AI 활성화

terraform.tfvars에서 계정이 접근 가능한 Converse 지원 모델 ID/추론 프로파일과 정확한 ARN을 설정합니다.

```hcl
bedrock_model_id = "실제-모델-ID-또는-추론-프로파일-ARN"
bedrock_resource_arns = ["실제-InvokeModel-대상-ARN"]
```

예시 문자열을 그대로 적용하지 마세요. 모델 사용 권한·지원 리전·모델별 이용 조건을 확인해야 합니다. 교차 리전 추론 프로파일은 프로파일 ARN뿐 아니라 해당 대상 모델 ARN도 필요할 수 있습니다. 이 설정은 모델 이용 권한을 신청하거나 모델을 배포하지 않습니다. 모델이나 IAM 오류는 화면에 실패로 표시하고 기존 대시보드를 유지합니다.

`terraform plan`에서 EC2 교체 여부를 확인한 뒤 적용합니다. 부팅 환경 변경은 EC2 교체를 유발합니다. 별도 EBS의 로그·Grafana DB·로그인 정보는 유지합니다. 단일 EC2이므로 교체 중에는 중단 시간이 있습니다.

AI는 자연어 조건 해석을 담당합니다. 예: `최근 30분 동안 web-01에서 발생한 500 오류만 보여줘`. 다중 서버 비교나 원인 규명처럼 지원하지 않는 요청은 직접 필터로 좁혀주세요. 검색은 수집 범위를 변경하지 않습니다.

## 4. Lambda → SQS 입력 계약

SQS 메시지 하나당 원본 이벤트 하나를 넣습니다. SNS envelope나 CloudWatch 압축 배치 본문은 직접 지원하지 않습니다.

```json
{
  "event_id": "원본-CloudWatch-event-id",
  "log_group": "/web/nginx/access",
  "log_stream": "i-0123456789abcdef0",
  "timestamp": 1789722000000,
  "message": "{\"ip\":\"198.51.100.2\",\"path\":\"/login\",\"status\":401,\"request_time\":0.125,\"event_type\":\"login_failed\"}"
}
```

timestamp는 이벤트 발생 시각의 UNIX 밀리초 정수입니다. 위 예시의 고정 시각을 실제 전송에 재사용하지 마세요. `logGroup`/`logStream`도 지원하지만 snake_case와 동시에 제공할 경우 값이 같아야 합니다. event_id가 없으면 그룹·스트림·시각·본문의 SHA-256으로 생성합니다. 이것은 중복 제거 저장소가 아닙니다.

라벨은 `job=web-access`, `environment=aws`, `server=log_stream`으로 통일합니다. 로그 본문 필드는 다음과 같습니다.

| 필드 | 의미 |
|---|---|
| ip | 클라이언트 IP. 원본이 remote_addr이면 상위 변환 과정에서 ip로 매핑 |
| path | 쿼리 문자열을 제외한 요청 경로. 요청 URI 전체와 혼동하지 않기 |
| status | HTTP 상태 코드 |
| request_time | 초 단위 응답시간. 없고 duration_ms가 숫자면 /1000 변환 |
| event_type | access, login_failed, authorization_denied, suspicious_request 등 |

일반 NGINX 로그만으로 로그인 실패나 공격을 확정하지 않습니다. 해당 이벤트 필터는 애플리케이션/탐지기가 명시한 event_type이 있을 때 의미가 있습니다. JSON이 아닌 원문은 raw_message와 event_type=unparsed로 저장하며 원본 로그 패널에서 확인합니다. 응답시간 누락 로그는 p95 계산에서 제외됩니다.

## 5. 실패 처리와 보안

- Loki HTTP 204일 때만 SQS 삭제. 200·리다이렉트·400·429·500 및 네트워크 실패는 삭제하지 않습니다.
- 한 번에 메시지 1건, long polling 20초, visibility 120초. 429/5xx는 제한된 지수 백오프·지터를 적용합니다.
- Loki 준비 상태 확인 후 SQS 수신. 수신/삭제 실패는 기록하고 재시도합니다.
- Loki 401/403/404 시 Worker는 소비를 멈춥니다. 설정 수정 후 재시작해야 합니다.
- 정상 저장 후 SQS 삭제 실패 시 재전송될 수 있습니다. exactly-once 보장이 없습니다.
- Loki의 오래된/순서가 뒤늦은 로그 수용 한도를 넘으면 재시도 끝에 DLQ로 이동할 수 있습니다. 장기간 장애 복구를 무손실로 보장하지 않습니다.
- API는 질문 500자, 요청 4KB, 동시 조회 2개, 게이트웨이에서 분당 6회(+burst 3) 제한. 직접/AI 필터 모두 허용 목록 검증을 거칩니다.
- 원본 로그는 UI에서 textContent로 표시하고 모델 프롬프트에 넣지 않습니다.
- 감사 로그에는 검색 모드·기간·결과 건수만 기록합니다. 질의 전체와 사용자별 감사 기록은 추가 구현 대상입니다.
- 모든 컨테이너는 같은 EC2 역할에 접근할 수 있습니다. 컨테이너별 IAM 권한 격리는 구현하지 않았습니다. 운영 확장 시 역할 분리를 고려하세요.
- 현재 접근 방식은 SSH 터널 + 공통 operator 계정입니다. 인터넷 공개용 TLS·SSO·사용자별 권한 체계는 별도 작업입니다.

## 6. 점검과 복구

관제 EC2:

```bash
cd /opt/monitoring/runtime
sudo docker compose --profile aws ps
sudo docker compose logs --tail=100 worker agent loki grafana gateway
sudo journalctl -u monitoring --no-pager -n 100
# 부팅 실패 상세
sudo tail -n 100 /var/log/cloud-init-output.log
```

1. 웹 서버에 고유 경로로 요청 → CloudWatch → SQS → Worker 성공 로그 → 대시보드 경로 필터에서 확인.
2. `sudo docker compose stop worker` 후 웹 요청 생성 → SQS 대기 → `sudo docker compose start worker` 후 조회 확인.
3. `sudo docker compose stop loki` 후 요청 생성 → SQS 삭제되지 않는지 확인 → `sudo docker compose start loki` 후 재처리 확인. 이미 수신된 메시지는 120초 후 재등장할 수 있습니다.
4. 실제 이벤트가 존재하는 서버/IP/경로로 직접 필터와 AI 검색 결과 비교. 로그 없는 조건은 0건이어야 합니다.
5. `기본 화면`으로 전체·최근 15분 복귀. 검색 실패 시 이전 대시보드 유지 확인.

## 7. 데이터·업데이트·삭제

별도 gp3 EBS에 Loki, Grafana, 초기 자격증명을 저장합니다. Loki 보존 기간은 7일입니다. 루트 EBS 20GB와 데이터 EBS 기본 40GB가 별도 과금됩니다. 디스크 부족은 보존 기간만으로 방지되지 않으므로 사용량과 백업을 관리해야 합니다.

EBS에는 `prevent_destroy=true`가 적용되어 전체 `terraform destroy`와 데이터 볼륨 교체가 차단됩니다. 삭제가 필요하면 먼저 서비스를 중지하고 스냅샷/복원 계획을 확인한 뒤 명시적으로 수명주기 보호를 수정해야 합니다. 이 보호는 AWS 콘솔에서의 직접 삭제나 디스크 손상까지 막지 않습니다. 자동 백업은 포함하지 않았습니다.

EC2 교체 전 서비스를 정상 중지하고 백업을 권장합니다. EBS는 같은 가용 영역에서만 재연결됩니다. 서브넷의 AZ 변경은 데이터 이전 작업이 필요합니다. AMI를 고정하지 않으면 최신 AMI 조회 때문에 다음 plan에서 EC2 교체가 나올 수 있습니다.

Terraform state와 .terraform.lock.hcl은 팀의 기존 관리 방식으로 보관하세요. 동시 배포에는 원격 state/잠금 설정이 필요하며 이 패키지에는 backend를 지정하지 않았습니다. 이미지 버전은 태그를 고정했지만 digest와 Python 전이 의존성은 완전 고정하지 않았습니다.

## 검증 상태

로컬 Worker/Planner/HTTP 테스트를 수행했습니다. 자세한 범위는 VALIDATION.md를 확인하세요. 실제 AWS, Bedrock 호출, Docker 전체 실행 및 브라우저의 Grafana 임베딩은 배포 환경에서 검증해야 합니다.

공식 참고:
- https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html
- https://grafana.com/docs/loki/latest/operations/storage/retention/
- https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/auth-proxy/
