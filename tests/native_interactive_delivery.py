#!/usr/bin/env python3
"""Opt-in native interactive delivery/return check using a controlled local API.

Runs one owned Claude PTY, real public discovery, production delegate/message
commands, and real permitted Bash tools. API responses are deterministic fixture
responses; this does not assert real-model task interpretation or peer-host health.
"""
import argparse
import errno
import fcntl
import hashlib
import http.server
import json
import os
from pathlib import Path
import pty
import re
import shlex
import struct
import subprocess
import sys
import termios
import threading
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT/'plugins/secondopinion'
CLI = PLUGIN/'bin/secondopinion'
sys.path.insert(0,str(PLUGIN/'scripts'))
from task_mailbox import Mailbox
from task_conversation import Conversation
from worker_hook import ready

EXECUTOR = '''import json,os,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parent
cli=os.environ['FIXTURE_CLI']
worker=os.environ['FIXTURE_WORKER']
def call(*args):
    return json.loads(subprocess.check_output([cli,'task',*args],text=True))
task,operation=sys.argv[1:]
if operation=='work':
    claim=call('claim',task,'--session',worker)
    if claim['execute']:
        with (root/(task+'.effect')).open('x') as stream: stream.write('executions=1')
        report=root/(task+'.report')
        report.write_text('INTERACTIVE_'+task+'_OK')
        call('update',task,'--session',worker,'--revision',str(claim['task']['revision']),
             '--state','complete','--message','fixture done','--file',str(report))
    print(json.dumps(claim))
else:
    for message in call('messages',task,'--session',worker,'--unread'):
        call('message-ack',task,message['id'],'--session',worker,'--sha256',message['sha256'])
        response=root/'reply.md'
        response.write_text('INTERACTIVE_REPLY_OK')
        call('message',task,'--id','reply-'+message['id'],'--session',worker,
             '--reply-to',message['id'],'--file',str(response))
    print('messages consumed and answered')
'''


def run(output):
    output=output.resolve()
    output.mkdir(parents=True,exist_ok=False)
    session=str(uuid.uuid4())
    name='so-delivery-fixture-'+session[:8]
    state=dict(task=None,operation='work',phase='idle',outage=False,requests=[])
    summary=dict(runtime=subprocess.check_output(['claude','--version'],text=True).strip(),
        session=session,checks=[],source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (CLI,PLUGIN/'scripts/task_mailbox.py',PLUGIN/'scripts/task_conversation.py',
                      PLUGIN/'scripts/worker_hook.py',PLUGIN/'claude-hooks/hooks.json')})
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_POST(self):
            data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if 'count_tokens' in self.path:
                self.send_response(200); self.end_headers(); self.wfile.write(b'{"input_tokens":10}'); return
            wire=json.dumps(data)
            notice='Secondopinion mailbox notification' in wire and str(state['task']) in wire
            state['requests'].append(dict(notice=notice,phase=state['phase']))
            if state['phase']=='waiting' and notice and state['outage']:
                state['outage']=False
                summary['outage_notice_received']=True
                (output/'outage-input.json').write_text(json.dumps(data['messages'],indent=2))
                self.send_response(503); self.send_header('Retry-After','0'); self.end_headers()
                self.wfile.write(b'{"type":"error","error":{"type":"api_error","message":"fixture outage"}}')
                return
            tool=state['phase']=='waiting' and notice
            if tool:
                state['phase']='tool_sent'
                content=dict(type='tool_use',id='toolu_'+uuid.uuid4().hex,name='Bash',input={})
                command=shlex.join([sys.executable,'-B',str(output/'executor.py'),state['task'],state['operation']])
                delta=dict(type='input_json_delta',partial_json=json.dumps(dict(command=command,description='Run the authorized isolated mailbox fixture')))
            else:
                state['phase']='idle'
                content=dict(type='text',text='')
                delta=dict(type='text_delta',text='Fixture idle.')
            message=dict(id='msg_'+uuid.uuid4().hex,type='message',role='assistant',model=data['model'],
                content=[],stop_reason=None,stop_sequence=None,usage=dict(input_tokens=10,output_tokens=1))
            parts=[dict(type='message_start',message=message),dict(type='content_block_start',index=0,content_block=content),
                dict(type='content_block_delta',index=0,delta=delta),dict(type='content_block_stop',index=0),
                dict(type='message_delta',delta=dict(stop_reason='tool_use' if tool else 'end_turn',stop_sequence=None),usage=dict(output_tokens=5)),
                dict(type='message_stop')]
            body=''.join('event: '+p['type']+'\ndata: '+json.dumps(p)+'\n\n' for p in parts).encode()
            self.send_response(200); self.send_header('Content-Type','text/event-stream')
            self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    env={k:v for k,v in os.environ.items() if not k.startswith(('ANTHROPIC_','CLAUDE_CODE_','CLAUDE_CONFIG_',
        'SECONDOPINION_','AGENT_MAILBOX_')) and k not in ('CLAUDECODE','CODEX_THREAD_ID')}
    env.update(ANTHROPIC_API_KEY='fixture-local-only',ANTHROPIC_BASE_URL='http://127.0.0.1:'+str(server.server_port),
        CLAUDE_CONFIG_DIR=str(output/'claude-config'),CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
        CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1',SECONDOPINION_DIR=str(output/'store'),
        FIXTURE_CLI=str(CLI),FIXTURE_WORKER=session)
    config=output/'claude-config'
    config.mkdir()
    # Fresh fixture preferences only. Workspace trust and tool permissions stay
    # enabled; no owner configuration or credentials are copied or modified.
    (config/'.claude.json').write_text(json.dumps(dict(theme='dark',hasCompletedOnboarding=True)))
    (output/'executor.py').write_text(EXECUTOR)
    forbidden=output/'forbid-relay'
    forbidden.write_text('#!/bin/sh\nprintf attempted > '+shlex.quote(str(output/'relay-attempted'))+'\nexit 99\n')
    forbidden.chmod(0o700)
    env['SECONDOPINION_CLAUDE']=str(forbidden)
    subprocess.run(['git','init','-q',str(output)],check=True)
    box=Mailbox(output/'store')
    master,slave=pty.openpty()
    fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',60,180,0,0))
    terminal=bytearray()
    log=open(output/'terminal.log','wb',buffering=0)
    child=subprocess.Popen(['claude','--setting-sources','','--plugin-dir',str(PLUGIN),
        '--session-id',session,'--name',name,'--permission-mode','dontAsk','--allowedTools','Bash,Read',
        '--ax-screen-reader','--','Wait for an authorized isolated mailbox fixture task.'],
        cwd=output,env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
    os.close(slave)
    def drain():
        try:
            while True:
                data=os.read(master,65536)
                if not data: break
                terminal.extend(data); log.write(data)
        except OSError as error:
            if error.errno not in (errno.EIO,errno.EBADF): raise
    reader=threading.Thread(target=drain,daemon=True); reader.start()
    def until(predicate,timeout=45):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            result=predicate()
            if result: return result
            if child.poll() is not None: raise RuntimeError('native worker exited')
            time.sleep(.1)
        raise TimeoutError('condition not reached; inspect '+str(output/'terminal.log'))
    def check(label,value):
        summary['checks'].append(dict(name=label,passed=bool(value)))
        print(('PASS ' if value else 'FAIL ')+label,flush=True)
        if not value: raise AssertionError(label)
    def command(*args,expected=0,timeout=45):
        result=subprocess.run([str(CLI),*map(str,args)],cwd=output,env=env,text=True,capture_output=True,timeout=timeout)
        if result.returncode!=expected:
            raise AssertionError('CLI '+str(args[:2])+': '+result.stdout+' '+result.stderr)
        return json.loads(result.stdout)
    trusted=False
    themed=False
    api_confirmed=False
    def lookup():
        nonlocal trusted, themed, api_confirmed
        screen=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',terminal.decode(errors='replace'))
        if 'Choose the text style' in screen and not themed:
            os.write(master,b'2\r'); themed=True
        if 'Yes, I trust this folder' in screen and not trusted:
            if str(output) not in screen: raise AssertionError('unexpected trust target')
            os.write(master,b'y\r' if 'Enter y/n:' in screen else b'\r'); trusted=True
        if 'Do you want to use this API key?' in screen and not api_confirmed:
            if 'fixture-local-only' not in screen: raise AssertionError('unexpected API key prompt')
            os.write(master,b'y\r'); api_confirmed=True
        rows=command('workers')
        return next((row for row in rows if row['sessionId']==session and row['name']==name and row['cwd']==str(output)),None)
    try:
        row=until(lookup)
        check('public directory identifies an existing interactive worker',row['kind']=='interactive')
        until(lambda: ready(box,dict(worker=session,repo=str(output))))
        check('interactive worker hook is listening',True)
        until(lambda: state['requests'] and state['phase']=='idle')
        for task in ('first','second'):
            until(lambda: ready(box,dict(worker=session,repo=str(output))))
            request=output/(task+'.request'); request.write_text('Authorized fixture; run executor.py for '+task)
            state.update(task=task,phase='waiting',operation='work',outage=task=='first')
            result=command('delegate','--id',task,'--worker',session,'--worker-name',name,'--requester','fixture-lead',
                '--file',request,'--timeout','35','--delivery-timeout','2')
            check(task+' real delegate receives worker completion',result['state']=='complete' and result['result']=='INTERACTIVE_'+task+'_OK')
            check(task+' hook route launched no relay',not (output/'relay-attempted').exists())
            check(task+' no fabricated native receipt',result['delivery_receipt'] is None)
            repeat=command('delegate','--id',task,'--worker',session,'--worker-name',name,'--requester','fixture-lead',
                '--file',request,'--timeout','0','--delivery-timeout','2')
            check(task+' same-ID retry preserves one execution',repeat['revision']==result['revision'] and (output/(task+'.effect')).read_text()=='executions=1')
            until(lambda: state['phase']=='idle')
        check('notification arrived while API returned 503',summary.get('outage_notice_received'))
        until(lambda: ready(box,dict(worker=session,repo=str(output))))
        message=output/'message.md'; message.write_text('Authorized fixture follow-up; consume and reply.')
        state.update(task='second',phase='waiting',operation='messages',outage=False)
        sent=command('task','message','second','--id','followup','--session','fixture-lead','--file',message,'--delivery-timeout','2')
        check('follow-up uses worker hook',sent.get('notification',{}).get('transport')=='worker_hook')
        messages=command('task','receive','second','--session','fixture-lead','--timeout','35')
        check('worker consumes follow-up and replies',messages[0]['body']=='INTERACTIVE_REPLY_OK' and messages[0]['reply_to']=='followup')
        check('conversation preserves terminal task and single execution',box.get('second')['state']=='complete' and
            Conversation(box).get('second','followup')['acknowledged_utc'] is not None and (output/'second.effect').read_text()=='executions=1')
        check('entire workflow uses no relay',not (output/'relay-attempted').exists())
    finally:
        child.terminate()
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired: child.kill(); child.wait()
        reader.join(timeout=3); os.close(master); log.close(); server.shutdown()
        summary['watcher_stopped']=not ready(box,dict(worker=session,repo=str(output)))
        summary['requests']=state['requests']
        summary['passed']=len(summary['checks'])==15 and all(c['passed'] for c in summary['checks']) and summary['watcher_stopped']
        (output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        box.db.close()
    if not summary['passed']: raise AssertionError('interactive qualification incomplete')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    run(parser.parse_args().output)
