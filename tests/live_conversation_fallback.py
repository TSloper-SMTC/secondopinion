#!/usr/bin/env python3
"""Real native worker conversation with an isolated store and foreground return."""
import argparse
import json
import os
from pathlib import Path
import sys
import uuid

sys.dont_write_bytecode = True
from live_worker_pool import WorkerPoolCanary
from live_delegation import CLI


class FallbackCanary(WorkerPoolCanary):
    def run(self, async_fallback=False):
        self.report['scope'] = 'real Claude worker and production foreground CLI; isolated store without wake service'
        worker = self.worker('so-fallback-' + os.urandom(5).hex())
        task_id, lead = 'fallback-conversation', 'fallback-lead'
        if async_fallback:
            lead = str(uuid.uuid4())
            self.env['CODEX_THREAD_ID'] = lead
        self.report['async_fallback'] = async_fallback
        token = os.urandom(12).hex()
        expected_question, expected_answer = 'QUESTION_' + token, 'ANSWER_' + token
        self.report.update(task_id=task_id, worker=worker, question=expected_question, answer=expected_answer)
        question = self.work / 'question.md'
        question.write_text(expected_question)
        script = self.work / 'fallback_fixture.py'
        script.write_text("from pathlib import Path\nroot=Path(__file__).resolve().parent\n"
                          "with (root/'executed.once').open('x') as f: f.write('executions=1')\n")
        request = self.work / 'request.md'
        request.write_text('Authorized isolated reporting-only test. Claim this task once, then run python3 ' +
            str(script) + ' exactly once. Send a question using task message with ID question-1, your assigned '
            'worker session and file ' + str(question) + '. END YOUR TURN and wait for the lead reply. '
            'When the reply arrives, read and consume it, acknowledge its exact message ID and hash yourself, '
            'write its exact body to ' + str(self.work / 'result.md') + ', then publish task complete with '
            'that file and the current task revision. Do not fabricate an answer, rerun the script, use native '
            'reply-to-relay messaging or touch anything outside this fixture and its store.\n')
        delegate = self.launch('delegate', [CLI, 'delegate', '--id', task_id,
            '--worker-name', worker['name'], '--requester', lead, '--file', request, '--timeout', '240',
            *(['--async'] if async_fallback else [])])
        rc = delegate.wait(timeout=300)
        self.check('foreground delegate returns pending worker question', rc == 4, (self.output / 'delegate.stderr').read_text())
        if async_fallback:
            self.check('missing service automatically selects foreground collection',
                       'waiting for the worker in this call instead' in (self.output / 'delegate.stderr').read_text())
        result = json.loads((self.output / 'delegate.stdout').read_text())
        self.check('question returned before completion', result['task']['state'] not in ('complete', 'failed', 'refused') and
                   len(result['messages']) == 1 and result['messages'][0]['body'] == expected_question)
        message = result['messages'][0]
        self.task('message-ack', task_id, 'question-1', '--session', lead, '--sha256', message['sha256'])
        answer = self.work / 'answer.md'
        answer.write_text(expected_answer)
        response = self.launch('reply', [CLI, 'task', 'message', task_id, '--id', 'answer-1',
            '--session', lead, '--reply-to', 'question-1', '--file', answer])
        self.check('lead reply delivered through real native relay', response.wait(timeout=150) == 0,
                   (self.output / 'reply.stderr').read_text())
        final = json.loads(self.command([CLI, 'task', 'wait', task_id, '--timeout', '240'], timeout=250))
        self.check('worker consumed reply and completed with exact content', final['result'] == expected_answer)
        self.task('ack', task_id, '--consumer', lead, '--revision', str(final['revision']))
        history = self.task('messages', task_id)
        self.check('both messages retained and acknowledged', len(history) == 2 and all(m['acknowledged_utc'] for m in history))
        self.check('task executed once', (self.work / 'executed.once').read_text() == 'executions=1')
        self.report['status'] = 'passed'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--async-fallback', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    canary = FallbackCanary(args.output)
    try:
        canary.run(args.async_fallback)
    except BaseException as error:
        canary.report.update(status='failed', error=repr(error))
        raise
    finally:
        canary.close()
