#!/bin/bash
# =============================================================================
# 웹서버 부팅 스크립트 (Terraform templatefile로 렌더링됨)
#  - 주의: 이 파일에서 달러+중괄호 표기는 Terraform 변수입니다.
#          셸 변수는 중괄호 없이 $VAR 형태로만 사용하세요.
# 구성: Docker + Nginx(리버스 프록시, JSON 로그) + 앱 컨테이너
#       + Node Exporter(:9100) + cAdvisor(:8080) + CloudWatch Agent(설치만)
# =============================================================================
set -eux
exec > >(tee -a /var/log/user-data.log) 2>&1

REGION="${region}"
APP_IMAGE="${app_image}"

# -----------------------------------------------------------------------------
# 1. 패키지 설치
# -----------------------------------------------------------------------------
dnf update -y
dnf install -y docker nginx amazon-cloudwatch-agent
systemctl enable --now docker

# -----------------------------------------------------------------------------
# 2. 앱 보안 이벤트 로그 디렉터리
#    앱이 여기 기록 → 컨테이너 볼륨으로 마운트 → 추후 CloudWatch Agent가 수집
# -----------------------------------------------------------------------------
mkdir -p /var/log/app
chown 1000:1000 /var/log/app

# -----------------------------------------------------------------------------
# 3. 앱 컨테이너 (호스트의 127.0.0.1:8000에만 노출 → 외부 직접 접근 불가)
#    8080은 cAdvisor가 사용하므로 앱은 8000 사용
#    /var/log/app 마운트: 앱 보안 이벤트 로그(로그인 실패, IDOR 시도 등) 기록용
# -----------------------------------------------------------------------------
if echo "$APP_IMAGE" | grep -q '\.dkr\.ecr\.'; then
  REGISTRY=$(echo "$APP_IMAGE" | cut -d/ -f1)
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
fi

docker run -d --name app --restart unless-stopped \
  -p 127.0.0.1:8000:80 \
  -v /var/log/app:/var/log/app \
  "$APP_IMAGE"

# -----------------------------------------------------------------------------
# 4. Nginx: 리버스 프록시 + JSON 액세스 로그 (Logstash 파싱용, 노혜린)
#    client_max_body_size 10m: 기본 1MB 제한 때문에 업로드 검증 우회
#    공격 시나리오(용량 제한 우회) 테스트가 막히지 않도록 상향
# -----------------------------------------------------------------------------
cat > /etc/nginx/nginx.conf << 'NGINX'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events { worker_connections 1024; }

http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;

    client_max_body_size 10m;

    log_format json_log escape=json '{'
        '"time":"$time_iso8601",'
        '"client_ip":"$http_x_forwarded_for",'
        '"remote_addr":"$remote_addr",'
        '"method":"$request_method",'
        '"uri":"$request_uri",'
        '"status":$status,'
        '"bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"upstream_time":"$upstream_response_time",'
        '"referer":"$http_referer",'
        '"user_agent":"$http_user_agent",'
        '"host":"$hostname"'
    '}';

    access_log /var/log/nginx/access.log json_log;

    server {
        listen 80 default_server;
        server_name _;

        # ALB 헬스체크 전용 (로그 제외)
        location = /healthz {
            access_log off;
            return 200 "ok\n";
        }

        location / {
            proxy_pass         http://127.0.0.1:8000;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }
    }
}
NGINX

nginx -t
systemctl enable --now nginx

# -----------------------------------------------------------------------------
# 5. 메트릭 Exporter (이승훈) — 공급망 공격 대비 latest 대신 버전 고정
#    TODO(팀 협의, 보류): 메트릭 경로가 CloudWatch Metrics API로 바뀌면
#    이 두 컨테이너와 web-sg의 9100/8080 인바운드 규칙을 함께 제거할 것
# -----------------------------------------------------------------------------
docker run -d --name node-exporter --restart unless-stopped \
  --net host --pid host \
  -v /:/host:ro,rslave \
  quay.io/prometheus/node-exporter:v1.8.2 \
  --path.rootfs=/host

docker run -d --name cadvisor --restart unless-stopped \
  -p 8080:8080 \
  -v /:/rootfs:ro \
  -v /var/run:/var/run:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker/:/var/lib/docker:ro \
  -v /dev/disk/:/dev/disk:ro \
  --privileged --device /dev/kmsg \
  gcr.io/cadvisor/cadvisor:v0.49.1

# -----------------------------------------------------------------------------
# 6. CloudWatch Agent (노혜린) — 설치만 수행
#    설정 파일(수집할 로그 경로 등)이 정해지면 아래처럼 로드
#    예) SSM Parameter Store에 설정 저장 후:
#    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
#      -a fetch-config -m ec2 -s -c ssm:/automovitsec/cwagent-config
#    수집 대상 로그: /var/log/nginx/access.log (JSON), /var/log/nginx/error.log,
#                    /var/log/app/*.log (앱 보안 이벤트)
# -----------------------------------------------------------------------------

echo "user-data finished"
