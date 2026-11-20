#!/usr/bin/env python3
"""One local QMP command; no shell interpolation and no target execution fallback."""
import json
import socket
import sys

with socket.socket(socket.AF_UNIX) as sock:
    sock.settimeout(10)
    sock.connect(sys.argv[1])
    stream = sock.makefile('rwb', buffering=0)
    greeting = json.loads(stream.readline())
    if 'QMP' not in greeting:
        raise RuntimeError('Missing QMP greeting')
    for command in [{'execute': 'qmp_capabilities'},
                    {'execute': sys.argv[2], 'arguments': json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}}]:
        stream.write((json.dumps(command) + '\r\n').encode())
        while True:
            response = json.loads(stream.readline())
            if 'return' in response or 'error' in response:
                break
        if 'error' in response:
            raise RuntimeError(response['error'])
    print(json.dumps(response, indent=2))
