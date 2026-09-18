"""실제 공격 없이 Grafana UI를 확인하는 합성 로그. demo 프로파일에서만 실행."""
import json,os,random,time
from urllib.request import Request,urlopen
url=os.environ.get('LOKI_URL','http://loki:3100')+'/loki/api/v1/push'
while True:
    stamp=time.time_ns();streams=[]
    for server in ['web-01','web-02']:
        values=[]
        for i in range(5):
            status=random.choices([200,401,403,404,500],[70,10,5,10,5])[0]
            row={'synthetic':True,'event_type':'login_failed' if status==401 else 'authorization_denied' if status==403 else 'access',
                 'ip':'198.51.100.'+str(random.randint(1,5)),'path':'/login' if status==401 else '/api/items',
                 'status':status,'request_time':round(random.uniform(.01,.3),3),'event_id':f'demo-{stamp}-{server}-{i}'}
            values.append([str(stamp+i),json.dumps(row)])
        streams.append({'stream':{'job':'web-access','environment':'demo','server':server},'values':values})
    try:
        with urlopen(Request(url,data=json.dumps({'streams':streams}).encode(),headers={'Content-Type':'application/json'}),timeout=5) as r:
            if r.status!=204:print('데모 로그 수신 응답 확인 필요',flush=True)
    except Exception:print('Loki 준비 대기',flush=True)
    time.sleep(2)
