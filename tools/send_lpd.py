#!/usr/bin/env python3
"""
send_lpd.py - Send a raw job file to an Epilog laser over LPD (port 515).

Implements the same handshake as LibLaserCut's EpilogCutter.sendPjlJob(),
so we can test driver output without CUPS, its sandbox, or a print dialog
in the way.

usage: send_lpd.py <job.prn> [--host ADDR] [--port 515]
                             [--user NAME] [--title Test] [--dry-run]

The laser address defaults to $EPILOG_HOST, or 192.168.3.4 (Epilog's factory
default) if that is unset.
"""
import argparse, socket, sys, os, getpass


def recv_ack(sock, what):
    sock.settimeout(20)
    try:
        r = sock.recv(1)
    except socket.timeout:
        raise SystemExit(f"FAIL: timed out waiting for ack after {what}")
    if not r:
        raise SystemExit(f"FAIL: connection closed after {what}")
    if r != b'\x00':
        raise SystemExit(f"FAIL: negative ack ({r!r}) after {what}")
    print(f"  ack ok  <- {what}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--host", default=os.environ.get("EPILOG_HOST", "192.168.3.4"))
    ap.add_argument("--port", type=int, default=515)
    ap.add_argument("--queue", default="")
    ap.add_argument("--user", default=getpass.getuser())
    ap.add_argument("--title", default="Test")
    ap.add_argument("--jobname", default="1")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be sent, connect to nothing")
    a = ap.parse_args()

    data = open(a.file, 'rb').read()
    host = socket.gethostname().split('.')[0]

    control = (
        f"H{host}\n"
        f"P{a.user}\n"
        f"J{a.title}\n"
        f"ldfA{a.jobname}{host}\n"
        f"UdfA{a.jobname}{host}\n"
        f"N{a.title}\n"
    ).encode('ascii')

    print(f"job file : {a.file} ({len(data):,} bytes)")
    print(f"target   : {a.host}:{a.port}  queue={a.queue!r}")
    print(f"control  : {control!r}")
    if not data.endswith(b'\x00'):
        print("NOTE: job does not end in NUL; LPD needs a trailing NUL "
              "(the Epilog footer's 4096 zero pad normally provides it)")

    if a.dry_run:
        print("\n--dry-run: nothing sent")
        return

    with socket.create_connection((a.host, a.port), timeout=20) as s:
        # 0x02 = receive a printer job
        s.sendall(b'\x02' + a.queue.encode('ascii') + b'\n')
        recv_ack(s, "receive-job")

        # 0x02 = receive control file
        s.sendall(b'\x02%d cfA%s%s\n' % (len(control), a.jobname.encode(), host.encode()))
        recv_ack(s, "control-file header")
        s.sendall(control + b'\x00')
        recv_ack(s, "control-file body")

        # 0x03 = receive data file
        s.sendall(b'\x03%d dfA%s%s\n' % (len(data), a.jobname.encode(), host.encode()))
        recv_ack(s, "data-file header")
        s.sendall(data)
        recv_ack(s, "data-file body")

    print("\nSent successfully - the laser has the job.")


if __name__ == "__main__":
    main()
