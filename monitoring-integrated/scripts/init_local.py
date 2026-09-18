"""로컬 및 EC2 공통 초기 자격증명 생성. 비밀번호는 로그에 출력하지 않는다."""
import os,secrets,subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]/'runtime'
secret=root/'secrets';secret.mkdir(mode=0o700,exist_ok=True)
if not (secret/'credentials.txt').exists():
    password=secrets.token_hex(18)
    digest=subprocess.run(['openssl','passwd','-apr1','-stdin'],input=password+'\n',text=True,capture_output=True,check=True).stdout.strip()
    (secret/'htpasswd').write_text('operator:'+digest+'\n')
    (secret/'credentials.txt').write_text('사용자: operator\n비밀번호: '+password+'\n')
    (secret/'credentials.txt').chmod(0o600)
if not (secret/'grafana-password').exists():
    (secret/'grafana-password').write_text(secrets.token_hex(24)+'\n')
# bind mount로 필요한 파일만 전달한다. 원본 디렉터리는 0700이다.
for name in ['htpasswd','grafana-password']:(secret/name).chmod(0o644)
print('초기화 완료. runtime/secrets/credentials.txt에서 로그인 정보를 확인하세요.')
