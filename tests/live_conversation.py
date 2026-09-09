#!/usr/bin/env python3
"""Installed natural-language conversation test with two real, owned workers.

The controller opens fixture sessions and external timing gates. Real Codex
issues delegate/message/ack; real Claude workers ask, consume replies and report.
No existing conversations, hardware or unrelated projects are addressed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from live_natural_worker import NaturalCanary
from live_delegation import CLI
from codex_wakeup import default_socket


FIXTURE = '''import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(__file__).resolve().parent
label, mode = sys.argv[1:3]
config = json.loads((root / (label + '.config.json')).read_text())
def gate(name):
    deadline = time.monotonic() + 480
    while not (root / name).exists():
        if time.monotonic() >= deadline: raise SystemExit('test gate timeout')
        time.sleep(.2)
def once(name, text):
    with (root / name).open('x') as f: f.write(text)
if mode == 'start':
    once(label + '.execution', 'executions=1')
    gate('start.release')
    path = root / (label + '.question1.md')
    path.write_text('Question 1 from ' + label + ': which test order? Challenge ' + config['challenge'])
    print(json.dumps(dict(question=1, file=str(path))))
elif mode == 'reply':
    message = json.loads(subprocess.check_output([config['cli'], 'task', 'message-read', config['task'], sys.argv[3]], text=True))
    assert message['recipient'] == config['worker'] and message['sender'] == config['lead']
    assert message['acknowledged_utc'], 'worker must consume and acknowledge the message itself'
    stage = {'question-1': 1, 'question-2': 2}[message['reply_to']]
    assert message['body'].strip() == config['answers'][str(stage)], 'wrong or misrouted lead answer'
    once(label + '.stage' + str(stage), message['body'].strip())
    if stage == 1:
        gate('second.release')
        path = root / (label + '.question2.md')
        path.write_text('Question 2 from ' + label + ': which report format? Received answer 1: ' + message['body'].strip())
        print(json.dumps(dict(question=2, file=str(path))))
    else:
        path = root / (label + '.report.md')
        path.write_text('CONVERSATION_' + label.upper() + '_' + config['challenge'] + '\\n' +
                        (root / (label + '.stage1')).read_text() + '\\n' + message['body'].strip())
        print(json.dumps(dict(complete=True, file=str(path))))
else:
    raise SystemExit('unknown fixture operation')
'''


class ConversationCanary(NaturalCanary):
    def run(self, native_worker=True):
        self.store = Path.home() / '.secondopinion'
        self.env['SECONDOPINION_DIR'] = str(self.store)
        self.env.pop('CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS', None)
        self.socket = Path(default_socket())
        self.rpc = self.connect('conversation-coordinator')
        self.report['scope'] = 'installed skills; two real existing workers; two question/reply rounds each; automatic idle return'
        self.report['implementation_sha256'] = {str(p.relative_to(CLI.parent.parent)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (CLI, *(CLI.parent.parent / 'scripts').glob('*.py'))}
        self.report['harness_sha256'][Path(__file__).name] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        self.report['codex_version'] = self.command(['codex', '--version']).strip()
        self.report['claude_version'] = self.command(['claude', '--version']).strip()
        (self.work / 'AGENTS.md').write_text('Isolated reporting-only secondopinion acceptance fixture. '
            'Only this checkout and records for the named fixture tasks/exchanges in ' + str(self.store) +
            ' may change. The task authorizes messaging only its two specified fixture workers. '
            'No hardware, other projects, permission changes, memory updates, unrelated conversations, '
            'commits or network configuration changes. Only the controller may release *.release gates.\n')
        result = self.rpc.call('thread/start', {'cwd': str(self.work), 'ephemeral': False,
            'sandbox': 'workspace-write', 'approvalPolicy': 'never'})
        self.thread_id = result['thread']['id']
        self.env['CODEX_THREAD_ID'] = self.thread_id
        self.report.update(thread_id=self.thread_id, model=result.get('model'))
        ready = self.start_text('Remember context token ' + self.token + '. Reply exactly READY <token>.')
        self.completed(ready)
        self.attach_tui('conversation-ordinary-codex', local_default=True)
        (self.work / 'conversation_fixture.py').write_text(FIXTURE)
        tasks, workers, configs, requests = {}, {}, {}, {}
        for label in ('a', 'b'):
            workers[label] = self.worker('so-conversation-' + label + '-' + self.token[:8])
            tasks[label] = 'conversation-' + self.token[:12] + '-' + label
            config = dict(task=tasks[label], worker=workers[label]['sessionId'], lead=self.thread_id,
                          challenge=os.urandom(8).hex(), cli=str(CLI),
                          answers={str(n): 'LEAD_' + label.upper() + str(n) + '_' + os.urandom(8).hex() for n in (1, 2)})
            configs[label] = config
            (self.work / (label + '.config.json')).write_text(json.dumps(config))
            request = self.work / (label + '.request.md')
            request.write_text('Authorized reporting-only conversation fixture for worker ' + label + '. '
                'Claim this task once. Run python3 ' + str(self.work / 'conversation_fixture.py') + ' ' + label +
                ' start exactly once. It waits for the controller gate; keep its command alive and do not release '
                'the gate yourself. Send its resulting question file to the lead using task message, with '
                'message ID question-1 and your assigned worker session, then END YOUR TURN. '
                'For each incoming lead reply, read and consume it, acknowledge its exact ID/hash yourself, '
                'then run python3 ' + str(self.work / 'conversation_fixture.py') + ' ' + label +
                ' reply RECEIVED_MESSAGE_ID exactly once for that message. If the script returns question=2, '
                'send the returned file using task message with ID question-2 and --reply-to RECEIVED_MESSAGE_ID, '
                'then END YOUR TURN. If it returns complete=true, publish task complete with the returned report '
                'file using the latest task revision. Never fabricate a report or rerun the original task. '
                'Do not directly read the config files; the script validates the actual replies. '
                'No permissions beyond this reporting fixture are authorized.\n')
            requests[label] = str(request)
        self.report.update(task_ids=tasks, workers=workers, configs=configs)
        task_text = '\n'.join(f"Worker {label}: exact name {workers[label]['name']}; task ID {tasks[label]}; "
            f"request file {requests[label]}; answer question-1 exactly {configs[label]['answers']['1']}; "
            f"answer question-2 exactly {configs[label]['answers']['2']}." for label in ('a', 'b'))
        turn = self.start_text('Use the installed secondopinion plugin to delegate these authorized reporting-only '
            'requests to my two existing Claude workers. Use each request file exactly.\n' + task_text + '\n'
            'Use automatic return. Do not execute the worker fixture yourself, inspect config files, release gates '
            'or start replacement workers. Once BOTH deliveries are accepted, reply exactly DELEGATED and END '
            'THIS TURN so you are idle before questions arrive. On each later worker message, consume it, '
            'acknowledge that exact message yourself, then answer with task message on the SAME task using '
            '--reply-to and the exact answer specified above. Send your answer with message ID answer-1 or '
            'answer-2 for the corresponding question. Use a private file; do not answer only in your user-facing '
            'chat. After sending any answers currently needed, END YOUR TURN again and wait for automatic '
            'messages. When final task results arrive, consume and acknowledge them yourself and display '
            'CONSUMED <remembered context token> followed by the exact worker result. A relay receipt or question '
            'is not completion. Do not poll indefinitely or ask the human to shuttle messages.')
        self.report['active_turn'] = turn
        self.save()
        self.completed(turn, timeout=360)
        self.check('lead naturally delegates both tasks and yields', 'DELEGATED' in self.text(turn), self.text(turn))
        self.until(lambda: all((self.work / (label + '.execution')).exists() for label in tasks), 180)
        self.idle('lead is idle before workers ask their first questions')
        route = json.loads(self.command([CLI, 'wake', 'status', 'codex-' + self.thread_id]))
        self.check('both task routes registered by lead', set(route['tasks']) == set(tasks.values()) and route['service_running'])
        (self.work / 'start.release').touch()
        self.until(lambda: all((self.work / (label + '.stage1')).exists() for label in tasks), 480)
        self.idle('lead answered first questions and returned to idle')
        for label, task in tasks.items():
            messages = self.task('messages', task)
            self.check(label + ' first round has real question and matching consumed reply',
                {m['id'] for m in messages} == {'question-1', 'answer-1'} and
                all(m['acknowledged_utc'] for m in messages))
            self.check(label + ' first answer reached correct worker',
                (self.work / (label + '.stage1')).read_text() == configs[label]['answers']['1'])
        # Restart only the plugin-owned notification bridge, never the shared
        # Codex server, and only after both first-round conversations are idle.
        self.command(['systemctl', '--user', 'restart', 'secondopinion-wakeup.service'])
        self.check('plugin return service restarted between conversation rounds',
                   self.command(['systemctl', '--user', 'is-active', 'secondopinion-wakeup.service']).strip() == 'active')
        (self.work / 'second.release').touch()
        def finished():
            for task in tasks.values():
                if self.task('status', task)['state'] != 'complete':
                    return False
            return self.task('inbox', '--consumer', self.thread_id) == []
        self.until(finished, 480)
        self.idle('lead consumed and acknowledged both final results')
        for label, task_id in tasks.items():
            task = self.task('status', task_id)
            expected = 'CONVERSATION_' + label.upper() + '_' + configs[label]['challenge'] + '\n' + \
                       configs[label]['answers']['1'] + '\n' + configs[label]['answers']['2']
            self.check(label + ' exact final report includes both lead answers', task['result'] == expected)
            messages = self.task('messages', task_id)
            self.check(label + ' full four-message conversation retained and consumed',
                [m['id'] for m in messages] == ['question-1', 'answer-1', 'question-2', 'answer-2'] and
                all(m['acknowledged_utc'] for m in messages))
            self.check(label + ' all replies link to their incoming message',
                [m['reply_to'] for m in messages] == [None, 'question-1', 'answer-1', 'question-2'])
            self.check(label + ' worker execution happened once', (self.work / (label + '.execution')).read_text() == 'executions=1')
            self.check(label + ' identity and original request preserved',
                task['worker'] == workers[label]['sessionId'] and task['requester'] == self.thread_id and
                task['request'] == Path(requests[label]).read_text())
        self.report['status'] = 'passed'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    canary = ConversationCanary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status='failed', error=repr(error))
        raise
    finally:
        canary.close()
