#!/usr/bin/env python3
"""Obtain the AMD web installer's authentication token without prompting.

Runs `xsetup -b AuthTokenGen` on a pseudo-terminal and answers its two
prompts with AMD_EMAIL and AMD_PASSWORD, taken from the environment or else
from an env-style file (default ~/.env). Neither value is printed: the
installer's echo of the e-mail line and everything after the password prompt
up to the next line are replaced by placeholders.

With --ensure nothing happens while the token has more than a day left.
"""
import argparse
import os
import pty
import re
import select
import signal
import sys
import time

DEFAULT_ENV = os.path.expanduser("~/.env")
TOKEN = os.path.expanduser("~/.Xilinx/wi_authentication_key")
KEYS = ("AMD_EMAIL", "AMD_PASSWORD")

# AMD tokens are valid for 7 days. Renewing with a day to spare keeps a long
# install from outliving the token it started with.
TOKEN_VALID_S = 7 * 24 * 3600
RENEW_MARGIN_S = 24 * 3600

EMAIL_PROMPT = re.compile(r"E-?mail Address:\s*$", re.I)
PASSWORD_PROMPT = re.compile(r"Password:\s*$", re.I)


def read_env(path):
    """KEY=VALUE lines, optionally prefixed by `export`, values optionally quoted.

    An unquoted value ends at ` #`, as in shell and python-dotenv.
    """
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", line)
            if not m:
                continue
            key, val = m.group(1), m.group(2)
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
                val = val[1:-1]
            else:
                val = re.sub(r"\s+#.*$", "", val)
            values[key] = val
    return values


def credentials(env_file):
    env = read_env(env_file) if os.path.exists(env_file) else {}
    creds = {k: os.environ.get(k) or env.get(k) for k in KEYS}
    missing = [k for k, v in creds.items() if not v]
    if missing:
        sys.exit(f"[auth] {' and '.join(missing)} not set in the environment or {env_file}")
    return creds["AMD_EMAIL"], creds["AMD_PASSWORD"]


def token_age():
    try:
        if os.path.getsize(TOKEN) == 0:
            return None
        return time.time() - os.path.getmtime(TOKEN)
    except OSError:
        return None


def token_is_fresh():
    age = token_age()
    return age is not None and age < TOKEN_VALID_S - RENEW_MARGIN_S


class Redactor:
    """Passes installer output through, hiding what the terminal echoes back."""

    def __init__(self, secrets):
        self.secrets = [s for s in secrets if s]
        self.hide_line = False

    def write(self, text):
        if self.hide_line:
            nl = text.find("\n")
            if nl < 0:
                return
            text, self.hide_line = text[nl:], False
        for s in self.secrets:
            text = text.replace(s, "<hidden>")
        sys.stdout.write(text)
        sys.stdout.flush()


def generate(xsetup, email, password, timeout):
    if not os.access(xsetup, os.X_OK):
        sys.exit(f"[auth] {xsetup} not found; extract the installer first")
    before = os.path.getmtime(TOKEN) if os.path.exists(TOKEN) else None
    if before is not None:
        # The client leaves the token mode 0400; a rewrite in place would fail.
        os.chmod(TOKEN, 0o600)

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execv(xsetup, [xsetup, "-b", "AuthTokenGen"])
        finally:
            os._exit(127)

    out = Redactor([email, password])
    buf = ""
    sent = []
    deadline = time.time() + timeout
    failure = None
    while True:
        if time.time() > deadline:
            failure = f"timed out after {timeout} s"
            break
        r, _, _ = select.select([fd], [], [], 1.0)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096).decode(errors="replace")
        except OSError:
            break
        if not chunk:
            break
        out.write(chunk)
        buf = (buf + chunk)[-256:]
        if EMAIL_PROMPT.search(buf):
            if "email" in sent:
                failure = "AMD rejected the login (the installer asked again)"
                break
            os.write(fd, (email + "\n").encode())
            sent.append("email")
            buf = ""
        elif PASSWORD_PROMPT.search(buf):
            if "password" in sent:
                failure = "AMD rejected the login (the installer asked again)"
                break
            os.write(fd, (password + "\n").encode())
            sent.append("password")
            out.hide_line = True
            out.write("<hidden>")
            buf = ""
    if failure:
        os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    os.close(fd)
    if failure:
        sys.exit(f"\n[auth] {failure}")
    after = os.path.getmtime(TOKEN) if os.path.exists(TOKEN) else None
    if after is None or after == before:
        sys.exit(f"\n[auth] no new token at {TOKEN} "
                 f"(xsetup exit {os.waitstatus_to_exitcode(status)})")
    print(f"\n[auth] token written: {TOKEN}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--xsetup", required=True, help="the extracted installer's xsetup")
    ap.add_argument("--env-file", default=DEFAULT_ENV)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--ensure", action="store_true",
                    help="do nothing while the token has more than a day left")
    args = ap.parse_args()

    if args.ensure and token_is_fresh():
        left_h = (TOKEN_VALID_S - token_age()) / 3600
        print(f"[auth] token valid for about {left_h:.0f} more hours")
        return 0
    email, password = credentials(args.env_file)
    generate(args.xsetup, email, password, args.timeout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
