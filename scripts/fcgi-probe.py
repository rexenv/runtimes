#!/usr/bin/env python3
"""A minimal FastCGI responder for the OpenLiteSpeed build gate.

rexenv runs OpenLiteSpeed with NO PHP of its own: `.php` goes to the site's
existing php-fpm pool over FastCGI (`extProcessor … type fcgi … autoStart 0`).
A CI runner has no php-fpm, and a gate that skips the PHP path proves only that
static files work — the one path rexenv does not care about. This stands in for
the pool on the wire: it speaks the FastCGI responder role, echoes the params
OpenLiteSpeed sent, and answers with an `X-LiteSpeed-Cache-Control` header so the
cache module has something to cache.

    fcgi-probe.py <port>        # listens on 127.0.0.1:<port> until killed

Body lines: script=<SCRIPT_FILENAME> uri=<REQUEST_URI> query=<QUERY_STRING>
t=<time of THIS response>. A cache hit returns the same `t` twice; a miss does not.
"""
import socket
import struct
import sys
import threading
import time

BEGIN, END, PARAMS, STDIN, STDOUT = 1, 3, 4, 5, 6
HEADER = struct.Struct("!BBHHBB")


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_record(conn):
    _ver, kind, rid, clen, plen, _ = HEADER.unpack(recv_exact(conn, 8))
    body = recv_exact(conn, clen)
    if plen:
        recv_exact(conn, plen)
    return kind, rid, body


def decode_params(blob):
    out, i = {}, 0

    def length():
        nonlocal i
        n = blob[i]
        if n >> 7:
            n = struct.unpack("!I", blob[i:i + 4])[0] & 0x7FFFFFFF
            i += 4
        else:
            i += 1
        return n

    while i < len(blob):
        nlen = length()
        vlen = length()
        out[blob[i:i + nlen].decode("latin1")] = blob[i + nlen:i + nlen + vlen].decode("latin1")
        i += nlen + vlen
    return out


def send(conn, kind, rid, data):
    off = 0
    while True:
        chunk = data[off:off + 65535]
        conn.sendall(HEADER.pack(1, kind, rid, len(chunk), 0, 0) + chunk)
        off += len(chunk)
        if off >= len(data):
            return


def serve(conn):
    try:
        while True:
            params, keep, rid = b"", False, 0
            while True:
                kind, rid, body = read_record(conn)
                if kind == BEGIN:
                    keep = bool(body[2] & 1)
                elif kind == PARAMS:
                    params += body
                elif kind == STDIN and not body:
                    break
            env = decode_params(params)
            body = ("script=%s\nuri=%s\nquery=%s\nt=%.6f\n" % (
                env.get("SCRIPT_FILENAME"), env.get("REQUEST_URI"),
                env.get("QUERY_STRING"), time.time())).encode()
            head = (b"Status: 200 OK\r\nContent-Type: text/plain\r\n"
                    b"X-LiteSpeed-Cache-Control: public,max-age=120\r\n\r\n")
            send(conn, STDOUT, rid, head + body)
            send(conn, STDOUT, rid, b"")
            conn.sendall(HEADER.pack(1, END, rid, 8, 0, 0) + struct.pack("!IB3x", 0, 0))
            if not keep:
                return
    except (EOFError, ConnectionError):
        pass
    finally:
        conn.close()


def main():
    port = int(sys.argv[1])
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(16)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
