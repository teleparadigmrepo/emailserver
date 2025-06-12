#!/bin/bash

echo "Setting up Daily Limit Mails..."

touch /var/log/sender_quota_policy.log
chown www-data:www-data /var/log/sender_quota_policy.log
chmod 666 /var/log/sender_quota_policy.log

echo "Creating a directory..."

mkdir -p /opt/mail-policies

echo "Writing script into the file"

cat > /opt/mail-policies/sender_quota_policy.py <<EOF
# sender_quota_policy.py

#!/usr/bin/env python3
import sys
import sqlite3
import time
from datetime import datetime
import os

DB_PATH = "/home/user-data/mail/users.sqlite"
LOG_PATH = "/var/log/sender_quota_policy.log"
MAIL_ROOT = "/home/user-data"

def parse_quota(quota_str):
    try:
        quota_str = quota_str.strip().upper()
        if quota_str.endswith('M'):
            return int(float(quota_str[:-1]) * 1024 * 1024)
        elif quota_str.endswith('G'):
            return int(float(quota_str[:-1]) * 1024 * 1024 * 1024)
        elif quota_str.endswith('K'):
            return int(float(quota_str[:-1]) * 1024)
        else:
            return int(quota_str)  # Assume bytes
    except Exception as e:
        log(f"Failed to parse quota '{quota_str}': {e}")
        return None

def get_user_info(email):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT daily_limit, emails_sent, last_reset, quota FROM users WHERE email = ?", (email,))
    row = c.fetchone()
    conn.close()
    return row

def update_user_count(email, new_count, today):
    with open(LOG_PATH, "a") as f:
        f.write(f"[{time.ctime()}] Attempting update for {email} to count={new_count} at {today}\n")
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""UPDATE users SET emails_sent = ?, last_reset = ? WHERE email = ?""", (new_count, today, email))
        conn.commit()
        conn.close()
        with open(LOG_PATH, "a") as f:
            f.write(f"[{time.ctime()}] DB update SUCCESS for {email}\n")
    except Exception as e:
        with open(LOG_PATH, "a") as f:
            f.write(f"[{time.ctime()}] DB update FAILED for {email}: {str(e)}\n")

def get_maildir_usage(mail_root, user_email):
    try:
        user, domain = user_email.split('@')
        maildir_path = os.path.join(mail_root, "mail/mailboxes", domain, user, "maildirsize")
        with open(maildir_path, 'r') as f:
            first_line = f.readline().strip()
            box_quota = int(first_line.split('S')[0])
            box_size=0
            box_count=0
            for line in f:
                try:
                    size, count = line.split()
                    box_size += int(size)
                    box_count += int(count)
                except Exception as e:
                    log(f"Skipping malformed line in maildirsize: {line.strip()} ({e})")
        percent_used = (box_size / box_quota) * 100 if box_quota > 0 else 0
        return (box_size, box_quota, percent_used)
    except Exception as e:
        log(f"doveadm failed: {e}")
        return (None, None, None)

def log(msg):
    with open(LOG_PATH, "a") as f:
        f.write(f"[{time.ctime()}] {msg}\n")

# --- Main execution starts here ---

params = {}
while True:
        line = sys.stdin.readline().strip()
        if not line:
            break
        name, value = line.split("=", 1)
        params[name.lower()] = value

sender = params.get("sender", "").lower()

# Normalize angle-bracketed sender
if sender.startswith("<") and sender.endswith(">"):
    sender = sender[1:-1]

today = datetime.now().strftime('%Y-%m-%d')
action = "DUNNO"

log(f"UID={os.geteuid()}, sender={sender}")

# Debug logging
with open(LOG_PATH, "a") as f:
    f.write(f"[{time.ctime()}] UID={os.geteuid()}, sender={sender}\n")

# Check mailbox quota usage
user = get_user_info(sender)
if user:
    limit, sent, last_reset, quota_str = user
    quota_bytes = parse_quota(quota_str)
    estimated_size = int(params.get("size", "0"))
    box_size, _, _ = get_maildir_usage(MAIL_ROOT, sender)
    log(f"{sender}, boxsize: {box_size}, quota_bytes: {quota_bytes}, estimatedsize: {estimated_size}")
    if box_size is not None and quota_bytes is not None:
        if quota_bytes == 0:
            remaining = float('inf')  # unlimited quota
        else:
            remaining = quota_bytes - box_size
        if remaining < estimated_size:
            action = "REJECT Not enough mailbox space"
            log(f"{sender} blocked: {box_size} used of {quota_bytes}, needs {estimated_size}")

        if action == "DUNNO" and user:
            if last_reset != today:
                sent = 0  # reset count for new day

        if limit != 0 and sent >= limit:
            action = "REJECT Daily quota exceeded"
            log(f"{sender} blocked: daily limit {limit} reached")
        else:
            update_user_count(sender, sent + 1, today)
            log(f"{sender} email count updated to {sent + 1}")
else:
    with open(LOG_PATH, "a") as f:
        f.write(f"[{time.ctime()}] sender not found in DB: {sender}\n")

# Output action and flush!
try:
    print(f"action={action}\n")
    sys.stdout.flush()
except Exception as e:
    log(f"CRITICAL: Failed to respond to Postfix: {e}")
    print("action=DUNNO\n")
    sys.stdout.flush()
    sys.exit(0)

EOF

echo "Changing file permissions"

chown www-data:www-data /opt/mail-policies/sender_quota_policy.py
chmod 755 /opt/mail-policies/sender_quota_policy.py
chmod +x /opt/mail-policies/sender_quota_policy.py
