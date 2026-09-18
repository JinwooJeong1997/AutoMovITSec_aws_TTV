import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from urllib.request import urlopen
from planner import DEFAULT, validate, plan_search, compile_query, dashboard_url

logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
LOKI=os.environ.get('LOKI_URL','http://loki:3100')
SLOTS=threading.BoundedSemaphore(2)

def loki_get(path,params):
    with urlopen(LOKI+path+'?'+urlencode(params),timeout=8) as r:
        data=json.load(r)
    if data.get('status')!='success':raise RuntimeError('Loki 조회 실패')
    return data['data']

def search(plan):
    end=time.time_ns();query=compile_query(plan)
    result=loki_get('/loki/api/v1/query_range',{'query':query,'start':str(end-plan['minutes']*60*10**9),'end':str(end),'limit':50,'direction':'backward'})
    rows=[]
    for stream in result.get('result',[]):
        for ts,line in stream['values']:
            rows.append({'timestamp_ns':ts,'server':stream['stream'].get('server',''),'line':line})
    rows=sorted(rows,key=lambda x:int(x['timestamp_ns']),reverse=True)[:50]
    count=loki_get('/loki/api/v1/query',{'query':f'sum(count_over_time({query}[{plan["minutes"]}m]))','time':str(end)})
    total=sum(float(x['value'][1]) for x in count.get('result',[]))
    return {'plan':plan,'query':query,'dashboard_url':dashboard_url(plan),'total':int(total),'rows':rows,
            'summary':f'최근 {plan["minutes"]}분 동안 조건에 맞는 로그 {int(total):,}건. 최근 최대 50건을 표시합니다. 공격 성공 여부를 판정한 결과는 아닙니다.'}

class Handler(BaseHTTPRequestHandler):
    def send(self,status,data,ctype='application/json'):
        body=data if isinstance(data,bytes) else json.dumps(data,ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type',ctype+'; charset=utf-8')
        self.send_header('Content-Length',str(len(body)))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.end_headers();self.wfile.write(body)
    def do_GET(self):
        path=urlsplit(self.path).path
        if path=='/':return self.send(200,Path(__file__).with_name('index.html').read_bytes(),'text/html')
        if path=='/api/config':return self.send(200,{'engine':'bedrock' if os.environ.get('BEDROCK_MODEL_ID') else 'keyword','default_url':dashboard_url(DEFAULT)})
        if path=='/health':return self.send(200,{'status':'ok'})
        return self.send(404,{'error':'찾을 수 없습니다.'})
    def do_POST(self):
        if self.path!='/api/search':return self.send(404,{'error':'찾을 수 없습니다.'})
        origin=self.headers.get('Origin')
        if origin and (urlsplit(origin).netloc!=self.headers.get('Host') or urlsplit(origin).scheme not in ('http','https')):
            return self.send(403,{'error':'요청 출처를 확인하세요.'})
        if not SLOTS.acquire(blocking=False):return self.send(429,{'error':'조회 중입니다. 잠시 후 다시 시도하세요.'})
        try:
            size=int(self.headers.get('Content-Length','0'))
            if not 0<size<=4096 or self.headers.get('Content-Type','').split(';')[0]!='application/json':raise ValueError('JSON 요청은 4KB 이내여야 합니다.')
            body=json.loads(self.rfile.read(size))
            if not isinstance(body,dict):raise ValueError('요청 형식 오류')
            if 'plan' in body:plan=validate(body['plan']);engine='manual'
            else:
                text=body.get('text','')
                if not isinstance(text,str) or not 1<=len(text.strip())<=500:raise ValueError('검색어는 1~500자입니다.')
                plan,engine=plan_search(text)
            result=search(plan);result['engine']=engine
            # 사용자 질문·원본 로그 대신 검증된 범위와 결과 건수만 감사 기록한다.
            logging.info('search engine=%s minutes=%s count=%s',engine,plan['minutes'],result['total'])
            return self.send(200,result)
        except (ValueError,TypeError,KeyError):return self.send(400,{'error':'검색 조건을 해석할 수 없습니다. 지원 범위를 확인하거나 직접 필터를 사용하세요.'})
        except Exception as exc:
            logging.error('search failed: %s',type(exc).__name__)
            return self.send(502,{'error':'AI 또는 로그 저장소 연결을 확인하세요. 검색 실패 시 기존 대시보드를 유지합니다.'})
        finally:SLOTS.release()
    def log_message(self,*args):pass

if __name__=='__main__':ThreadingHTTPServer(('0.0.0.0',8000),Handler).serve_forever()
