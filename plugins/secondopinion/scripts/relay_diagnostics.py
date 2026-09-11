"""Bounded observations of a relay log. Diagnostics never constitute a receipt."""
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

from task_mailbox import utc

LIMIT = 16 * 1024 * 1024


def run_relay(cli, prompt, store, topic, timeout):
    env = dict(os.environ, SECONDOPINION_DIR=str(store), CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1')
    exchange = None
    # ask prints its exchange ID on stderr before waiting, including on failure.
    # Forward progress while capturing that machine line; stdout contains a
    # validated answer only on success and cannot identify a failed relay.
    with tempfile.TemporaryFile(mode='w+', dir=prompt.parent) as output:
        with subprocess.Popen([cli, 'ask', '--relay', '--topic', topic, '--file', str(prompt),
                '--timeout', str(timeout), '--grace', '0'], env=env, stdout=output,
                stderr=subprocess.PIPE, text=True) as child:
            try:
                for line in iter(lambda: child.stderr.readline(8192), ''):
                    print(line, end='', file=sys.stderr, flush=True)
                    match = re.fullmatch(r'exchange_id=([A-Za-z0-9][A-Za-z0-9_.-]{0,180})\n?', line)
                    if match:
                        exchange = match[1]
                code = child.wait()
            except BaseException:
                child.terminate()
                raise
        if exchange is None:
            output.seek(0)
            header = output.readline(256).strip()
            if header.startswith('Exchange-ID: '):
                exchange = header[13:]
    return exchange, code


def read_regular(path, limit):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('not a regular diagnostic file')
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('diagnostic file exceeds limit')
    return data.decode('utf-8')


def observe(store, exchange, exit_code):
    result = dict(transport='relay', exchange=exchange, relay_exit_code=exit_code,
                  stage='relay_unknown', reason='relay_ended_without_receipt',
                  tools_called=None, tools_available=None, api_retries=0, log_complete=False)
    if not exchange or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,180}', exchange):
        return result
    try:
        meta = dict(line.split('=', 1) for line in
                    read_regular(Path(store) / 'exchanges' / exchange / 'meta', 65536).splitlines()
                    if '=' in line)
        path = Path(meta['responder_log'])
        if path.parent != Path(store) / 'responder-logs':
            return result
        data = read_regular(path, LIMIT)
    except (OSError, ValueError, KeyError, UnicodeError):
        return result
    tools, calls, returns, available = [], {}, {}, None
    complete, initialized = True, False
    for line in data.splitlines():
        if line.startswith('[secondopinion] '):
            # The supervisor appends its own bounded-termination footer to the
            # JSON event log. It is not a missing/truncated Claude event.
            continue
        try:
            event = json.loads(line)
        except ValueError:
            complete = False
            continue
        if not isinstance(event, dict):
            complete = False
            continue
        if event.get('type') == 'system' and event.get('subtype') == 'init':
            initialized = True
            if isinstance(event.get('tools'), list):
                available = [name for name in event['tools'] if name in ('ListAgents', 'SendMessage')]
        if event.get('type') == 'system' and event.get('subtype') == 'api_retry':
            result['api_retries'] += 1
        message = event.get('message')
        content = message.get('content', []) if isinstance(message, dict) else []
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            if event.get('type') == 'assistant' and item.get('type') == 'tool_use':
                name, key = item.get('name'), item.get('id')
                if isinstance(name, str) and len(name) <= 100:
                    if name not in tools:
                        tools.append(name)
                    if isinstance(key, str):
                        calls[key] = name
            if event.get('type') == 'user' and item.get('type') == 'tool_result':
                key = item.get('tool_use_id')
                if isinstance(key, str):
                    returns[key] = item.get('is_error', False)
    result.update(tools_called=tools if complete else None, tools_available=available,
                  log_complete=complete)
    send_results = [returns[key] for key, name in calls.items()
                    if name == 'SendMessage' and key in returns]
    if send_results:
        # A non-error tool result still does not prove acceptance from its text.
        result.update(stage='native_send', reason='send_message_rejected' if all(send_results)
                      else 'send_result_observed_without_receipt')
    elif 'SendMessage' in tools:
        result.update(stage='native_send', reason='send_message_outcome_unknown')
    elif complete and initialized and available is not None and 'ListAgents' not in available:
        result.update(stage='relay_capability', reason='list_agents_unavailable')
    elif complete and initialized and available is not None and 'SendMessage' not in available:
        result.update(stage='relay_capability', reason='send_message_unavailable')
    elif 'ListAgents' in tools:
        result.update(stage='worker_resolution', reason='list_agents_called_without_send')
    elif complete and initialized and not tools:
        result.update(stage='relay_inference', reason='claude_api_retries_before_tool_use'
                      if result['api_retries'] else 'relay_ended_before_tool_use')
    return result


def record(box, task_id, details):
    with box.transaction():
        box.db.execute('''CREATE TABLE IF NOT EXISTS task_delivery_diagnostics (
            sequence INTEGER PRIMARY KEY, task TEXT NOT NULL REFERENCES tasks(id),
            observed_utc TEXT NOT NULL, details TEXT NOT NULL)''')
        box.db.execute('INSERT INTO task_delivery_diagnostics(task,observed_utc,details) VALUES (?,?,?)',
                       (task_id, utc(), json.dumps(details, sort_keys=True)))


def latest(box, task_id):
    if not box.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='task_delivery_diagnostics'").fetchone():
        return None
    row = box.db.execute('SELECT observed_utc,details FROM task_delivery_diagnostics '
                         'WHERE task=? ORDER BY sequence DESC LIMIT 1', (task_id,)).fetchone()
    return dict(json.loads(row['details']), observed_utc=row['observed_utc']) if row else None
