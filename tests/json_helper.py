"""Small jshn test double for hosts without OpenWrt's libubox.

The production shell still builds and parses JSON through its real jshn calls.
This double implements that public API; it is never packaged on the router.
"""
import json
import os
import shlex
import sys
from pathlib import Path

path = Path(os.environ['JSON_STATE'])
op, *args = sys.argv[1:]
state = json.loads(path.read_text()) if path.exists() else {'data': {}, 'path': []}

def current():
    value = state['data']
    for key in state['path']:
        value = value[key]
    return value

def key_for(value, key):
    return int(key) - 1 if isinstance(value, list) else key

if op == 'init':
    state = {'data': {}, 'path': []}
elif op == 'load':
    state = {'data': json.loads(args[0]), 'path': []}
elif op == 'dump':
    print(json.dumps(state['data']))
elif op == 'add':
    kind, key, *rest = args
    value = {'object': {}, 'array': []}.get(kind)
    if kind == 'string': value = rest[0] if rest else ''
    if kind == 'int': value = int(rest[0])
    if kind == 'boolean': value = bool(int(rest[0]))
    parent = current()
    if isinstance(parent, list):
        key = len(parent)
        parent.append(value)
    else:
        parent[key] = value
    if kind in ('object', 'array'): state['path'].append(key)
elif op == 'close':
    if state['path']: state['path'].pop()
elif op == 'select':
    if args[0] == '..':
        state['path'].pop()
    else:
        parent = current()
        key = key_for(parent, args[0])
        parent[key]
        state['path'].append(key)
elif op in ('get', 'type', 'assign', 'assign_type'):
    variable = args.pop(0) if op.startswith('assign') else None
    parent = current()
    try: value = parent[key_for(parent, args[0])]
    except (KeyError, IndexError): value = None
    if op in ('type', 'assign_type'):
        value = {str: 'string', dict: 'object', list: 'array', int: 'int', type(None): 'null'}.get(type(value), 'boolean')
    value = '' if value is None else str(value)
    print(variable + '=' + shlex.quote(value) if variable else value, end='')
path.write_text(json.dumps(state))
