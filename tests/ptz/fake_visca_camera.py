#!/usr/bin/env python3
"""Fake VISCA camera for the HongMix PTZ tests.

Listens on
  * UDP 52381 — Sony VISCA over IP framing (8-byte header)
  * TCP 5678  — raw VISCA (PTZOptics style)
  * UDP 1259  — raw VISCA
and logs every received message as one line "<proto> <hex>" to the log file (flushed), then answers
ACK (90 41 FF) + Completion (90 51 FF). Sony control RESET (02 00 … 01) is answered with 02 01 … 01.

Test hooks:
  * preset recall 0x7E (81 01 04 3F 02 7E FF) → error 90 61 41 FF ("command not executable")
  * preset recall 0x7D on TCP → ACK, then the camera drops the TCP connection (reconnect test)

usage: fake_visca_camera.py LOGFILE [sony_udp_port tcp_port raw_udp_port]
"""
import socket
import select
import sys
import time

log_path = sys.argv[1]
sony_port, tcp_port, raw_port = (int(x) for x in (sys.argv[2:5] if len(sys.argv) >= 5 else (52381, 5678, 1259)))
log = open(log_path, "w")


def note(proto, data):
    log.write("%s %s\n" % (proto, data.hex(" ")))
    log.flush()


ACK = bytes([0x90, 0x41, 0xFF])
DONE = bytes([0x90, 0x51, 0xFF])
NOT_EXECUTABLE = bytes([0x90, 0x61, 0x41, 0xFF])
ERR_PRESET = bytes([0x81, 0x01, 0x04, 0x3F, 0x02, 0x7E, 0xFF])
DROP_PRESET = bytes([0x81, 0x01, 0x04, 0x3F, 0x02, 0x7D, 0xFF])


def replies(msg):
    """VISCA replies for one raw message."""
    if msg == ERR_PRESET:
        return [NOT_EXECUTABLE]
    if len(msg) > 1 and msg[1] == 0x09:      # inquiry → completion with data
        return [bytes([0x90, 0x50, 0x02, 0xFF])]
    return [ACK, DONE]


def split(buf):
    out = []
    while 0xFF in buf:
        i = buf.index(0xFF)
        out.append(bytes(buf[: i + 1]))
        del buf[: i + 1]
    return out


def sony_header(ptype, payload, seq):
    return ptype.to_bytes(2, "big") + len(payload).to_bytes(2, "big") + seq.to_bytes(4, "big") + payload


sony = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sony.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sony.bind(("127.0.0.1", sony_port))
raw_udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
raw_udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
raw_udp.bind(("127.0.0.1", raw_port))
tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
tcp.bind(("127.0.0.1", tcp_port))
tcp.listen(4)
clients = {}   # socket -> bytearray
note("READY", b"")

while True:
    socks = [sony, raw_udp, tcp] + list(clients)
    r, _, _ = select.select(socks, [], [], 1.0)
    for s in r:
        if s is sony:
            data, addr = s.recvfrom(2048)
            note("SONY", data)
            if len(data) < 8:
                continue
            ptype = int.from_bytes(data[0:2], "big")
            seq = int.from_bytes(data[4:8], "big")
            payload = data[8:]
            if ptype == 0x0200:          # control: RESET
                s.sendto(sony_header(0x0201, bytes([0x01]), seq), addr)
            elif ptype in (0x0100, 0x0110):
                for rep in replies(payload):
                    s.sendto(sony_header(0x0111, rep, seq), addr)
        elif s is raw_udp:
            data, addr = s.recvfrom(2048)
            note("RAWUDP", data)
            for rep in replies(data):
                s.sendto(rep, addr)
        elif s is tcp:
            c, _ = tcp.accept()
            clients[c] = bytearray()
            note("TCPCONNECT", b"")
        else:
            data = s.recv(2048)
            if not data:
                note("TCPCLOSE", b"")
                del clients[s]
                s.close()
                continue
            buf = clients[s]
            buf += data
            drop = False
            for msg in split(buf):
                note("TCP", msg)
                for rep in replies(msg):
                    s.sendall(rep)
                if msg == DROP_PRESET:
                    drop = True
            if drop:
                time.sleep(0.05)
                note("TCPDROP", b"")
                del clients[s]
                s.close()
