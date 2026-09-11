#!/usr/bin/env python3
"""Opt-in installed Claude runtime test with a local fake API, no paid inference.

Exercises the source plugin's real hooks in a persistent native stream session.
The second API request receives 503: notification must already be in its input.
No other workers, credentials, global configuration, or native inboxes are used.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / 'plugins/secondopinion'
sys.path.insert(0,str(PLUGIN/'scripts'))
from task_mailbox import Mailbox
from worker_hook import ready, make_available


def run(output):
    output = output.resolve()
    output.mkdir(parents=True,exist_ok=False)
    events = queue.Queue()
    class Handler(http.server.BaseHTTPRequestHandler):
        calls = 0
        def log_message(self,*args):
            pass
        def do_POST(self):
            data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if 'count_tokens' in self.path:
                body = b'{"input_tokens":10}'
                content, status = 'application/json', 200
            else:
                Handler.calls += 1
                events.put(data)
                if Handler.calls > 1:
                    body = b'{"type":"error","error":{"type":"api_error","message":"Intentional local fixture outage"}}'
                    content, status = 'application/json', 503
                else:
                    message = dict(id='msg_fixture',type='message',role='assistant',model=data['model'],
                        content=[],stop_reason=None,stop_sequence=None,usage=dict(input_tokens=10,output_tokens=1))
                    parts = [dict(type='message_start',message=message),
                        dict(type='content_block_start',index=0,content_block=dict(type='text',text='')),
                        dict(type='content_block_delta',index=0,delta=dict(type='text_delta',text='Fixture idle.')),
                        dict(type='content_block_stop',index=0),
                        dict(type='message_delta',delta=dict(stop_reason='end_turn',stop_sequence=None),usage=dict(output_tokens=3)),
                        dict(type='message_stop')]
                    body = ''.join('event: '+p['type']+'\ndata: '+json.dumps(p)+'\n\n' for p in parts).encode()
                    content, status = 'text/event-stream', 200
            self.send_response(status)
            self.send_header('Content-Type',content)
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    session = str(uuid.uuid4())
    env = {k:v for k,v in os.environ.items() if not k.startswith(('ANTHROPIC_','CLAUDE_CODE_','CLAUDE_CONFIG_',
            'SECONDOPINION_','AGENT_MAILBOX_')) and k != 'CLAUDECODE'}
    env.update(ANTHROPIC_API_KEY='fixture-local-only',ANTHROPIC_BASE_URL='http://127.0.0.1:'+str(server.server_port),
        CLAUDE_CONFIG_DIR=str(output/'claude-config'),CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
        SECONDOPINION_DIR=str(output/'store'))
    subprocess.run(['git','init','-q',str(output)],check=True)
    box = Mailbox(output/'store')
    logs = [open(output/'claude.stdout','w'),open(output/'claude.stderr','w')]
    child = subprocess.Popen(['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose',
        '--setting-sources','','--plugin-dir',str(PLUGIN),'--session-id',session,'--tools','',
        '--permission-mode','dontAsk'],cwd=output,env=env,stdin=subprocess.PIPE,stdout=logs[0],stderr=logs[1],text=True)
    summary = dict(runtime=subprocess.check_output(['claude','--version'],text=True).strip(),session=session,
        source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in (PLUGIN/'claude-hooks/hooks.json',PLUGIN/'scripts/worker_hook.py',PLUGIN/'scripts/task_mailbox.py')},
        checks=[])
    def check(name,value):
        summary['checks'].append(dict(name=name,passed=bool(value)))
        if not value:
            raise AssertionError(name)
        print('PASS '+name,flush=True)
    try:
        child.stdin.write(json.dumps(dict(type='user',message=dict(role='user',content='Local fixture initial turn.')))+'\n')
        child.stdin.flush()
        first = events.get(timeout=30)
        check('initial turn uses local API',Handler.calls == 1)
        deadline = time.monotonic()+20
        binding = dict(worker=session,repo=str(output))
        while not ready(box,binding) and time.monotonic()<deadline:
            time.sleep(.1)
        check('source plugin starts native watcher for exact session',ready(box,binding))
        # The first result must have completed before the task is created.
        deadline = time.monotonic()+10
        while '"type":"result"' not in (output/'claude.stdout').read_text() and time.monotonic()<deadline:
            time.sleep(.1)
        check('native session is idle before task creation','"type":"result"' in (output/'claude.stdout').read_text())
        task = box.create('outage-task',session,'fixture-lead',str(output),'Never execute; transport fixture only','fixture')
        make_available(box,task)
        received = events.get(timeout=20)
        wire = json.dumps(received)
        check('task notice reaches same native session before any successful inference',
              'Secondopinion mailbox notification' in wire and 'outage-task' in wire and session in wire)
        check('notification does not use ListAgents or SendMessage',not received.get('tools'))
        check('outage leaves task created and receipt null',box.get('outage-task')['state']=='created'
              and box.get('outage-task')['delivery_receipt'] is None)
        check('first later claim alone can execute',box.claim('outage-task',session)['execute'])
        check('duplicate claim cannot execute',not box.claim('outage-task',session)['execute'])
        (output/'received-messages.json').write_text(json.dumps(received['messages'],indent=2)+'\n')
    finally:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait()
        for stream in logs:
            stream.close()
        server.shutdown()
        deadline = time.monotonic()+5
        while ready(box,dict(worker=session,repo=str(output))) and time.monotonic()<deadline:
            time.sleep(.1)
        summary['watcher_stopped'] = not ready(box,dict(worker=session,repo=str(output)))
        summary['passed'] = all(c['passed'] for c in summary['checks']) and len(summary['checks']) == 8 and summary['watcher_stopped']
        (output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        box.db.close()
    if not summary['passed']:
        raise AssertionError('native hook qualification failed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    run(parser.parse_args().output)
