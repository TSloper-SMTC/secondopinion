"""Durable task conversations between the two bound participants.

Messages are independent of task revisions and never grant another execution.
Native delivery is at least observable, not exactly-once consumption. Ambiguous
relay sends require explicit reconciliation before retrying the same message.
"""
import fcntl
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import uuid

from task_mailbox import bounded, digest, emit, identifier, read_text, utc

MAX_MESSAGE = 16384


def message_digest(message):
    return digest(json.dumps({k: message[k] for k in
        ('task', 'id', 'sender', 'recipient', 'reply_to', 'body')},
        sort_keys=True, ensure_ascii=True, separators=(',', ':')))


class Conversation:
    def __init__(self, box):
        self.box, self.db = box, box.db
        with box.transaction():
            self.db.execute("""CREATE TABLE IF NOT EXISTS task_messages (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                task TEXT NOT NULL REFERENCES tasks(id), id TEXT NOT NULL,
                sender TEXT NOT NULL, recipient TEXT NOT NULL, reply_to TEXT,
                body TEXT NOT NULL, sha256 TEXT NOT NULL, created_utc TEXT NOT NULL,
                acknowledged_utc TEXT, UNIQUE(task,id),
                FOREIGN KEY(task,reply_to) REFERENCES task_messages(task,id))""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS message_delivery (
                task TEXT NOT NULL, message TEXT NOT NULL, state TEXT NOT NULL,
                attempt TEXT, receipt TEXT, error TEXT NOT NULL, updated_utc TEXT NOT NULL,
                PRIMARY KEY(task,message),
                FOREIGN KEY(task,message) REFERENCES task_messages(task,id))""")
            self.db.execute('CREATE INDEX IF NOT EXISTS unread_task_messages '
                            'ON task_messages(task,recipient,sequence) WHERE acknowledged_utc IS NULL')

    def participant(self, task_id, session, repo=None):
        task = self.box.get(task_id)
        identifier(session)
        if session not in (task['worker'], task['requester']):
            raise ValueError('session is not a participant in this task')
        if repo is not None and task['repo'] != str(Path(repo).resolve()):
            raise ValueError('message checkout does not match task')
        return task

    def get(self, task_id, message_id):
        task = self.box.get(task_id)
        identifier(message_id)
        row = self.db.execute('SELECT * FROM task_messages WHERE task=? AND id=?',
                              (task_id, message_id)).fetchone()
        if row is None:
            raise ValueError('unknown task message: ' + message_id)
        message = dict(row)
        if message_digest(message) != message['sha256']:
            raise ValueError('message hash mismatch')
        if {message['sender'], message['recipient']} != {task['worker'], task['requester']}:
            raise ValueError('message participants do not match task')
        delivery = self.db.execute('SELECT * FROM message_delivery WHERE task=? AND message=?',
                                  (task_id, message_id)).fetchone()
        message['delivery'] = dict(delivery) if delivery else None
        return message

    def post(self, task_id, message_id, session, body, reply_to=None, repo=None):
        identifier(message_id)
        if not body.strip() or len(body.encode('utf-8')) > MAX_MESSAGE:
            raise ValueError('message must be nonempty UTF-8, at most 16384 bytes')
        with self.box.transaction():
            task = self.participant(task_id, session, repo)
            if task['worker'] == task['requester']:
                raise ValueError('conversation requires two distinct participants')
            recipient = task['worker'] if session == task['requester'] else task['requester']
            existing = self.db.execute('SELECT id FROM task_messages WHERE task=? AND id=?',
                                       (task_id, message_id)).fetchone()
            if existing:
                message = self.get(task_id, message_id)
                if (message['sender'], message['body'], message['reply_to']) != (session, body, reply_to):
                    raise ValueError('message ID already exists with different sender, content or reply target')
                return message
            if task['state'] == 'created':
                raise ValueError('wait for the worker to claim the task before sending messages')
            if reply_to is not None:
                parent = self.get(task_id, reply_to)
                if parent['recipient'] != session:
                    raise ValueError('reply must reference a message from the other participant')
            self.db.execute('''INSERT INTO task_messages
                (task,id,sender,recipient,reply_to,body,sha256,created_utc) VALUES (?,?,?,?,?,?,?,?)''',
                (task_id, message_id, session, recipient, reply_to, body,
                 message_digest(dict(task=task_id, id=message_id, sender=session,
                                     recipient=recipient, reply_to=reply_to, body=body)), utc()))
            if recipient == task['worker']:
                self.db.execute("INSERT INTO message_delivery VALUES (?,?,'queued',NULL,NULL,'',?)",
                                (task_id, message_id, utc()))
            return self.get(task_id, message_id)

    def messages(self, task_id, session=None, unread=False):
        self.box.get(task_id)
        if session is not None:
            self.participant(task_id, session)
        if unread and session is None:
            raise ValueError('unread messages require a recipient session')
        query, params = 'SELECT id FROM task_messages WHERE task=?', (task_id,)
        if unread:
            query += ' AND recipient=? AND acknowledged_utc IS NULL'
            params += (session,)
        rows = self.db.execute(query + ' ORDER BY sequence', params).fetchall()
        return [self.get(task_id, row[0]) for row in rows]

    def acknowledge(self, task_id, message_id, session, sha256, repo=None):
        with self.box.transaction():
            self.participant(task_id, session, repo)
            message = self.get(task_id, message_id)
            if message['recipient'] != session or message['sha256'] != sha256:
                raise ValueError('message ack requires the recipient and exact consumed content hash')
            self.db.execute('UPDATE task_messages SET acknowledged_utc=COALESCE(acknowledged_utc,?) '
                            'WHERE task=? AND id=?', (utc(), task_id, message_id))
            return self.get(task_id, message_id)

    def delivered(self, task_id, message_id, attempt, receipt):
        if not receipt.strip() or len(receipt) > 512 or any(c in receipt for c in '\r\n'):
            raise ValueError('receipt must be a nonempty single line, at most 512 characters')
        with self.box.transaction():
            message = self.get(task_id, message_id)
            delivery = message['delivery']
            if not delivery or delivery['attempt'] != attempt or delivery['state'] not in ('sending', 'uncertain', 'delivered'):
                raise ValueError('receipt does not match the current message delivery attempt')
            if delivery['receipt'] and delivery['receipt'] != receipt:
                raise ValueError('message delivery receipt is immutable')
            self.db.execute("UPDATE message_delivery SET state='delivered',receipt=?,error='',updated_utc=? "
                            'WHERE task=? AND message=?', (receipt, utc(), task_id, message_id))
            return self.get(task_id, message_id)

    def receive(self, task_id, session, timeout):
        deadline, progress = time.monotonic() + timeout, time.monotonic() + 60
        while True:
            messages = self.messages(task_id, session, unread=True)
            if messages:
                emit(messages)
                return 0
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                emit([])
                return 124
            if time.monotonic() >= progress:
                print('Waiting for a task message.', file=sys.stderr, flush=True)
                progress = time.monotonic() + 60
            time.sleep(min(.25, remaining))


def worker_instructions(task, message, cli, store):
    command = shlex.join(['env', f'SECONDOPINION_DIR={store}', cli, 'task'])
    task_id, mid, session = map(shlex.quote, (task['id'], message['id'], task['worker']))
    return f'''Task conversation message {message['id']} for existing task {task['id']}.
You are the bound worker {task['worker']}. The sender is the task's lead.
Read the exact message and its retained conversation using:
  {command} message-read {task_id} {mid}
  {command} status {task_id}
If acknowledged_utc is already set, do not act on this message again.
Otherwise consume it within the original task's authority and repository policies,
then acknowledge the exact sha256 returned by message-read:
  {command} message-ack {task_id} {mid} --session {session} --sha256 HASH
A message is not another task claim. Do not rerun the original assignment or reopen
a terminal task. Reconcile actual work before continuing after interruption.
Send questions, updates or answers directly to the lead through the mailbox:
  {command} message {task_id} --id UNIQUE_REPLY_ID --session {session} --reply-to {mid} --file /absolute/reply.md
The reply file must contain your real response. Never reply to the temporary relay.
When waiting for an answer, end your turn; the lead's reply will notify this session.
Do not mark complete until the authorized work is finished. A reply is not completion.
'''


def deliver(conversation, task_id, message_id, session, cli, timeout, retry=False):
    """One bounded relay. Store before sending; never silently retry an uncertain send."""
    if timeout <= 0:
        raise ValueError('delivery timeout must be positive')
    box = conversation.box
    task = conversation.participant(task_id, session, Path.cwd())
    message = conversation.get(task_id, message_id)
    if session != task['requester'] or message['sender'] != session:
        raise ValueError('only the task lead can deliver its own message to the worker')
    # One lead-delivery owner per task, not per message: newer instructions must
    # not overtake an earlier queued/ambiguous send to this same worker.
    lock = box.store / ('.message-delivery-' + digest(task_id) + '.lock')
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError('unsafe message delivery lock')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError('another lead message delivery is active for this task; '
                             'wait for it to finish, inspect message-read, then retry the '
                             'original message command with the same ID and content') from error
        message = conversation.get(task_id, message_id)
        if message['acknowledged_utc'] or message['delivery']['state'] == 'delivered':
            return message
        if message['delivery']['state'] != 'queued' and not retry:
            raise ValueError('message delivery is ambiguous; inspect the worker and receipt before message-retry --confirm-not-delivered')
        for previous in conversation.messages(task_id, task['worker'], unread=True):
            if previous['sequence'] < message['sequence'] and previous['delivery']['state'] != 'delivered':
                raise ValueError('earlier lead message has unconfirmed delivery: ' + previous['id'] +
                                 '; deliver or reconcile it before sending this message')
        # A name can now belong to a replacement session. Check UUID and checkout
        # again for every new attempt, even though the original task route is fixed.
        from worker_directory import Directory
        rows = Directory(box).rows()
        matches = [r for r in rows if r['sessionId'] == task['worker']]
        if len(matches) != 1 or matches[0]['cwd'] != task['repo']:
            raise ValueError('bound worker is absent, ambiguous or in a different checkout')
        name = matches[0]['name']
        if (task['worker_name'] and name != task['worker_name']) or len([r for r in rows if r['name'] == name]) != 1:
            raise ValueError('bound worker name changed or became ambiguous')
        task = dict(task, worker_name=name)
        attempt = str(uuid.uuid4())
        with box.transaction():
            box.db.execute("UPDATE message_delivery SET state='sending',attempt=?,receipt=NULL,error='',updated_utc=? "
                           'WHERE task=? AND message=?', (attempt, utc(), task_id, message_id))
        command = shlex.join(['env', f'SECONDOPINION_DIR={box.store}', cli, 'task',
                             'message-delivered', task_id, message_id, '--attempt', attempt])
        from task_mailbox import relay_prompt
        prompt = relay_prompt(task, cli, box.store,
            content=worker_instructions(task, message, cli, box.store),
            receipt_command=command + " --receipt 'ACTUAL_MESSAGE_RECEIPT'")
        try:
            with tempfile.TemporaryDirectory(prefix='message-relay-', dir=box.store) as tmp:
                request = Path(tmp) / 'request.md'
                request.write_text(prompt, encoding='utf-8')
                env = dict(os.environ, SECONDOPINION_DIR=str(box.store), CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1')
                with tempfile.TemporaryFile(mode='w+', dir=tmp) as output:
                    subprocess.run([cli, 'ask', '--relay', '--topic', 'message ' + message_id[:100],
                                    '--file', str(request), '--timeout', str(timeout), '--grace', '0'],
                                   env=env, stdout=output)
                    output.seek(0)
                    header = output.readline().strip()
                    if header.startswith('Exchange-ID: '):
                        print('Relay exchange: ' + header[13:], file=sys.stderr)
        finally:
            # Also covers interruption and a relay dying after native acceptance.
            with box.transaction():
                box.db.execute("UPDATE message_delivery SET state='uncertain',error='relay ended without a receipt',updated_utc=? "
                               "WHERE task=? AND message=? AND state='sending' AND attempt=?",
                               (utc(), task_id, message_id, attempt))
        return conversation.get(task_id, message_id)
    finally:
        os.close(fd)


def add_commands(commands):
    post = commands.add_parser('message', help='send a durable message to the other task participant')
    post.add_argument('id')
    post.add_argument('--id', dest='message_id', required=True)
    post.add_argument('--session', required=True)
    post.add_argument('--file', required=True)
    post.add_argument('--reply-to')
    post.add_argument('--delivery-timeout', type=bounded, default=120)
    for name in ('message-read', 'message-ack', 'message-delivered', 'message-retry', 'messages', 'receive'):
        sub = commands.add_parser(name)
        sub.add_argument('id')
        if name.startswith('message-'):
            sub.add_argument('message_id')
        if name in ('message-ack', 'message-retry', 'receive'):
            sub.add_argument('--session', required=True)
        if name == 'messages':
            sub.add_argument('--session')
            sub.add_argument('--unread', action='store_true')
        if name == 'message-ack':
            sub.add_argument('--sha256', required=True)
        if name == 'message-delivered':
            sub.add_argument('--attempt', required=True)
            sub.add_argument('--receipt', required=True)
        if name == 'message-retry':
            sub.add_argument('--confirm-not-delivered', action='store_true', required=True)
            sub.add_argument('--delivery-timeout', type=bounded, default=120)
        if name == 'receive':
            sub.add_argument('--timeout', type=bounded, default=900)


def dispatch(box, args):
    conversation = Conversation(box)
    command = args.command
    if command in ('message', 'message-retry', 'message-ack', 'receive'):
        task = conversation.participant(args.id, args.session, Path.cwd())
        caller = os.environ.get('CODEX_THREAD_ID')
        if task['requester'] == args.session and caller and caller != args.session:
            raise ValueError('calling Codex thread does not match the task lead')
    if command == 'message':
        if args.delivery_timeout <= 0:
            raise ValueError('delivery timeout must be positive')
        message = conversation.post(args.id, args.message_id, args.session,
                                    read_text(args.file), args.reply_to, Path.cwd())
        if message['recipient'] == task['worker']:
            message = deliver(conversation, args.id, args.message_id, args.session, args.cli, args.delivery_timeout)
        emit(message)
        return 0 if not message['delivery'] or message['acknowledged_utc'] or message['delivery']['state'] == 'delivered' else 1
    if command == 'message-retry':
        message = deliver(conversation, args.id, args.message_id, args.session, args.cli, args.delivery_timeout, retry=True)
        emit(message)
        return 0 if message['acknowledged_utc'] or message['delivery']['state'] == 'delivered' else 1
    if command == 'message-read':
        emit(conversation.get(args.id, args.message_id))
    elif command == 'message-ack':
        emit(conversation.acknowledge(args.id, args.message_id, args.session, args.sha256, Path.cwd()))
    elif command == 'message-delivered':
        emit(conversation.delivered(args.id, args.message_id, args.attempt, args.receipt))
    elif command == 'messages':
        emit(conversation.messages(args.id, args.session, args.unread))
    elif command == 'receive':
        return conversation.receive(args.id, args.session, args.timeout)
    return 0
