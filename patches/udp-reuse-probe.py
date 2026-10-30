#!/usr/bin/env python3
"""Probe the reused-UDP-socket leak: does a socket's first packet decide where its later ones go?

xray keys a transparent-proxy UDP session by the client's source address and port alone, so every
later packet of a socket rides the outbound its first packet chose. Each test opens a fresh socket,
sends one primer packet, then a STUN request from the same socket, and prints the address STUN saw.

  T0   fresh socket, STUN only: the tunnel's exit address, the baseline
  T1   QUIC Initial for a proxied name (www.example.com), then STUN: the baseline again
  T2…  QUIC Initial for each name given, then STUN. Give names that a direct domain rule of the
       shunt matches. The primer goes to --foreign, an address in none of passwall2's nft direct
       sets, so it reaches xray, whose sniffer reads the name and routes the session `direct`.
       Without passwall2-direct-udp-guard.sh STUN sees your ISP address: a leak.
       With it, `dropped`: the guard blocks the primer and the rest of that session.

Run it from a LAN client behind the router:
  python3 -I udp-reuse-probe.py www.direct-site.example [more names …] [--rounds 2] [--exit-ip IP]
Needs the `cryptography` package (for the QUIC Initial).
"""
import argparse, os, socket, struct, time

from cryptography.hazmat.primitives import hashes, hmac
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def hkdf_extract(salt, ikm):
    h = hmac.HMAC(salt, hashes.SHA256()); h.update(ikm); return h.finalize()


def hkdf_expand(prk, info, length):
    out, t, i = b"", b"", 1
    while len(out) < length:
        h = hmac.HMAC(prk, hashes.SHA256()); h.update(t + info + bytes([i])); t = h.finalize()
        out += t; i += 1
    return out[:length]


def expand_label(secret, label, length):
    full = b"tls13 " + label
    return hkdf_expand(secret, struct.pack("!HB", length, len(full)) + full + b"\x00", length)


def client_hello(sni, scid):
    def ext(t, body): return struct.pack("!HH", t, len(body)) + body
    name = sni.encode()
    exts = b"".join([
        ext(0x0000, struct.pack("!HBH", len(name) + 3, 0, len(name)) + name),
        ext(0x000a, struct.pack("!HH", 2, 0x001d)),
        ext(0x000d, struct.pack("!HHH", 4, 0x0403, 0x0804)),
        ext(0x0010, struct.pack("!HB", 3, 2) + b"h3"),
        ext(0x002b, struct.pack("!BH", 2, 0x0304)),
        ext(0x0033, struct.pack("!HHH", 36, 0x001d, 32) + os.urandom(32)),
        ext(0x0039, bytes([0x0f, len(scid)]) + scid),
    ])
    body = (b"\x03\x03" + os.urandom(32) + b"\x00" + struct.pack("!HHHH", 6, 0x1301, 0x1302, 0x1303)
            + b"\x01\x00" + struct.pack("!H", len(exts)) + exts)
    return b"\x01" + len(body).to_bytes(3, "big") + body


def quic_initial(sni):
    """A 1200-byte QUIC v1 Initial carrying a ClientHello for `sni` (RFC 9001 keys), enough for xray's sniffer."""
    dcid, scid = os.urandom(8), os.urandom(8)
    initial = hkdf_extract(bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a"), dcid)
    csec = expand_label(initial, b"client in", 32)
    key, iv, hp = (expand_label(csec, b"quic key", 16), expand_label(csec, b"quic iv", 12),
                   expand_label(csec, b"quic hp", 16))
    ch = client_hello(sni, scid)
    crypto = b"\x06\x00" + struct.pack("!H", 0x4000 | len(ch)) + ch
    hdr = b"\xc3" + struct.pack("!I", 1) + bytes([8]) + dcid + bytes([8]) + scid + b"\x00"
    payload = crypto.ljust(1200 - (len(hdr) + 2 + 4) - 16, b"\x00")
    pn = b"\x00\x00\x00\x00"
    header = hdr + struct.pack("!H", 0x4000 | (4 + len(payload) + 16)) + pn
    ct = AESGCM(key).encrypt(bytes(a ^ b for a, b in zip(iv, b"\x00" * 8 + pn)), payload, header)
    enc = Cipher(algorithms.AES(hp), modes.ECB()).encryptor()
    mask = enc.update(ct[:16]) + enc.finalize()
    h = bytearray(header)
    h[0] ^= mask[0] & 0x0F
    for i in range(4):
        h[len(h) - 4 + i] ^= mask[1 + i]
    return bytes(h) + ct


def stun(sock, server):
    txn = os.urandom(12)
    sock.sendto(struct.pack("!HHI", 1, 0, 0x2112A442) + txn, server)
    deadline = time.time() + 3
    while time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            break
        if len(data) < 20 or data[8:20] != txn:
            continue
        pos = 20
        while pos + 4 <= len(data):
            t, l = struct.unpack("!HH", data[pos:pos + 4]); v = data[pos + 4:pos + 4 + l]
            if t == 0x0020:
                return socket.inet_ntoa(bytes(b ^ m for b, m in zip(v[4:8], b"\x21\x12\xa4\x42")))
            if t == 0x0001:
                return socket.inet_ntoa(v[4:8])
            pos += 4 + l + (-l % 4)
    return None


def probe(primer, server):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", 0))
    if primer:
        s.sendto(*primer)
        time.sleep(0.8)
        s.settimeout(0.2)
        try:
            while True:
                s.recvfrom(4096)
        except OSError:
            pass
    ip = stun(s, server)
    s.close()
    return ip


def hostport(v, default_port):
    host, _, port = v.rpartition(":") if ":" in v else (v, "", default_port)
    return socket.gethostbyname(host), int(port)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Probe the reused-UDP-socket leak behind passwall2/xray.")
    ap.add_argument("direct_names", nargs="+", help="names a direct domain rule of the shunt matches")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--exit-ip", help="the tunnel's exit address (default: whatever T0 sees)")
    ap.add_argument("--foreign", default="1.0.0.1:443", help="primer destination, in no nft direct set")
    ap.add_argument("--stun", default="stun.l.google.com:19302")
    a = ap.parse_args()
    server, foreign = hostport(a.stun, 3478), hostport(a.foreign, 443)
    for r in range(a.rounds):
        print(f"--- round {r + 1}, STUN {server[0]}:{server[1]}, primers to {foreign[0]}:{foreign[1]}")
        base = probe(None, server)
        exit_ip = a.exit_ip or base
        print(f"{'T0 fresh socket, STUN only':<54} {base or '-':<16} {'baseline' if not a.exit_ip else ''}", flush=True)
        tests = [("T1 QUIC www.example.com (proxied), then STUN", "www.example.com")]
        tests += [(f"T{i} QUIC {n} (direct rule), then STUN", n) for i, n in enumerate(a.direct_names, 2)]
        for label, name in tests:
            ip = probe((quic_initial(name), foreign), server)
            verdict = "dropped" if ip is None else ("tunnel" if ip == exit_ip else "DIRECT: leak")
            print(f"{label:<54} {ip or '-':<16} {verdict}", flush=True)
