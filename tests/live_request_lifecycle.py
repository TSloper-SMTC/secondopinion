#!/usr/bin/env python3
"""Opt-in real Claude request lifecycle in an isolated checkout and store."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

sys.dont_write_bytecode = True
from live_delegation import Canary, CLI


class RequestLifecycle(Canary):
    def status(self, exchange):
        return json.loads(self.command([CLI, 'status', exchange, '--json']))

    def exchange(self, label):
        output = (self.output / (label + '.stdout')).read_text()
        return re.search(r'^Exchange-ID: (.+)$', output, re.M)[1]

    def ask(self, label, body, *options, command='ask'):
        # Detailed focus stays out of long-running command lines and outside the
        # target checkout. Only the fixture/store are authorized for model edits.
        with tempfile.NamedTemporaryFile(mode='w', prefix='secondopinion-lifecycle-', suffix='.md') as request:
            request.write(body)
            request.flush()
            args = [CLI, command, '--file', request.name, '--timeout', '180', '--grace', '0', *options]
            if command == 'ask':
                args.extend(['--topic', label])
            caller = self.launch(label, args)
            self.check(label + ' real responder succeeds', caller.wait(timeout=200) == 0,
                       (self.output / (label + '.stderr')).read_text()[-2500:])
        exchange = self.exchange(label)
        self.report.setdefault('exchanges', {})[label] = exchange
        self.save()
        return exchange, self.command([CLI, 'read-response', exchange])

    def run(self):
        self.report['scope'] = 'real Claude ordinary ask, follow-up, native resume, review, cancel/attach, write and retention'
        self.report['harness_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        self.report['claude_version'] = self.command(['claude', '--version']).strip()
        token = 'CONTEXT_' + os.urandom(12).hex()
        parent, response = self.ask('persist', 'Read-only fixture. Remember context value ' + token +
            '. Return that value in your answer. Follow the required exchange response workflow.',
            '--persist', '--model', 'sonnet', '--effort', 'medium')
        self.check('persisted ask has exact answer and native session', token in response and bool(self.status(parent).get('session_id')))
        parent_dir = Path(self.command([CLI, 'path', parent]).strip())
        snapshot = {name: hashlib.sha256((parent_dir / name).read_bytes()).hexdigest() for name in ('prompt.md', 'response.md')}
        follow, response = self.ask('follow-up', 'Read-only. Return the prior context value followed by /FOLLOW_UP.', '--follow-up', parent)
        self.check('follow-up links parent and consumes its context', token + '/FOLLOW_UP' in response and
                   self.status(follow)['parent_exchange'] == parent)
        resumed, response = self.ask('resume', 'Read-only. Return the earlier context value followed by /RESUMED.', '--resume', parent)
        self.check('native resume reuses exact session and context', token + '/RESUMED' in response and
                   self.status(resumed)['session_id'] == self.status(parent)['session_id'])
        self.check('parent request and response remain byte-identical', snapshot ==
                   {name: hashlib.sha256((parent_dir / name).read_bytes()).hexdigest() for name in snapshot})

        target = self.work / 'arithmetic.py'
        target.write_text('def add(a, b):\n    return a + b\n')
        self.command(['git', 'add', 'arithmetic.py', 'AGENTS.md'])
        self.command(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'])
        target.write_text('def add(a, b):\n    return a - b\n')
        for label, options in (('review', ()), ('adversarial-review', ('--adversarial', '--base', 'HEAD~1'))):
            if label == 'adversarial-review':
                self.command(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                              'commit', '-qam', 'seed regression'])
            exchange, _ = self.ask(label, 'Read-only review of arithmetic.py. add(2,3) must return 5. '
                'Identify any correctness regression. Do not fix files. Use the structured review JSON contract.',
                *options, command='review')
            parsed = self.command([CLI, 'review-result', exchange])
            self.check(label + ' detects seeded defect with structured output', 'needs-attention' in parsed and
                       'arithmetic.py' in parsed and 'parse_ok=yes' in parsed, parsed)
            self.check(label + ' leaves checkout untouched', target.read_text() == 'def add(a, b):\n    return a - b\n')

        # Exercise genuine job cancellation after the owned responder reaches a
        # harmless gate, then recover that SAME exchange with --attach.
        gate, ready = self.work / 'release', self.work / 'waiting.ready'
        script = self.work / 'wait_fixture.py'
        script.write_text('from pathlib import Path\nimport time\nroot=Path(__file__).resolve().parent\n'
            '(root/"waiting.ready").write_text("waiting")\ndeadline=time.monotonic()+150\n'
            'while not (root/"release").exists() and time.monotonic()<deadline: time.sleep(.1)\n'
            'assert (root/"release").exists()\nprint("RECOVERED_' + token + '")\n')
        with tempfile.NamedTemporaryFile(mode='w', prefix='secondopinion-cancel-', suffix='.md') as request:
            request.write('Authorized fixture-only write test. Run python3 ' + str(script) +
                ' once in this attempt, allowing up to 160 seconds. Never create the release file or bypass '
                'the gate. Once it exits, include its exact stdout in your response. The script may be '
                'run again after cancellation; its writes are idempotent. Touch no other project files.')
            request.flush()
            caller = self.launch('cancel', [CLI, 'ask', '--topic', 'cancel-recover', '--write', '--file', request.name,
                                           '--timeout', '180', '--grace', '0'])
            self.until(lambda: ready.exists(), 150)
            # Successful asks print the response only at completion. Discover
            # this owned in-flight request through the public pending list.
            pending = json.loads(self.command([CLI, 'list', '--pending', '--json']))
            self.check('one owned pending request before cancellation', len(pending) == 1)
            exchange = pending[0]['exchange_id']
            before = self.status(exchange)
            self.check('real running job is visible', before['state'] == 'claimed' and
                       exchange in self.command([CLI, 'jobs']))
            self.check('cancel identifies and stops owned responder', 'cancelled=yes' in self.command([CLI, 'cancel', exchange]))
            self.check('cancelled foreground returns failure', caller.wait(timeout=25) != 0)
        state = self.status(exchange)
        self.check('cancel releases exact claim for recovery', state['state'] == 'published' and state['responder_status'] == 'cancelled')
        original_hash = state['prompt_sha256']
        gate.touch()
        attached = self.launch('attach', [CLI, 'ask', '--attach', exchange, '--write', '--timeout', '180', '--grace', '0'])
        self.check('attach recovers same sealed exchange', attached.wait(timeout=200) == 0 and
                   self.exchange('attach') == exchange and self.status(exchange)['prompt_sha256'] == original_hash)
        self.check('recovered worker publishes exact result', 'RECOVERED_' + token in self.command([CLI, 'read-response', exchange]))
        self.report['exchanges']['cancel-recovered'] = exchange
        ids = set(self.report['exchanges'].values())
        for exchange in ids:
            self.command([CLI, 'archive', exchange])
        self.check('all completed requests archive cleanly', len(list((self.store / 'archive').iterdir())) == len(ids))
        dry_run = self.command([CLI, 'prune', '--retain', '2'])
        self.check('retention preview preserves archives', 'pruned=0' in dry_run and
                   len(list((self.store / 'archive').iterdir())) == len(ids))
        applied = self.command([CLI, 'prune', '--retain', '2', '--apply'])
        self.check('retention applies only to isolated fixture archives', len(list((self.store / 'archive').iterdir())) == 2 and
                   'pruned=' + str(len(ids) - 2) in applied)
        self.report['status'] = 'passed'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    canary = RequestLifecycle(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status='failed', error=repr(error))
        raise
    finally:
        canary.close()
