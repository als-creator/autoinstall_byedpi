#!/bin/sh
# Самопроверка установщика ByeDPI.
#
# Проверяет то, что нельзя проверить глазами:
#   1) чистая установка (когда файлов ещё нет) создаёт рабочий набор;
#   2) повторная установка перезаписывает hosts/rule свежей версией из скрипта
#      и сохраняет предыдущую в .bak-<дата>;
#   3) --keep-files ничего не перезаписывает;
#   4) --off удаляет всё: каталог конфигов (вместе с .bak), launcher, юниты;
#   5) после --off установка снова работает с нуля.
#
# Ничего системного не трогает: sudo/systemctl/iptables подменяются заглушками,
# все пути перенаправляются в build/selftest (каталог репозитория, в .gitignore).
#
# Запуск:  sh tests/selftest.sh [путь-к-установщику]

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${1:-}" ]; then
    SCRIPT=$1
else
    SCRIPT=""
    for cand in "$HERE"/*byedpi*.sh; do
        [ -f "$cand" ] && { SCRIPT=$cand; break; }
    done
fi
[ -n "$SCRIPT" ] && [ -f "$SCRIPT" ] || { echo "не найден установщик: ${SCRIPT:-в $HERE}"; exit 1; }

WORK="$HERE/build/selftest"
ROOT="$WORK/root"
BIN="$WORK/bin"
rm -rf "$WORK"
mkdir -p "$ROOT/etc/systemd/system" "$ROOT/usr/local/bin" "$ROOT/home" "$BIN"

# --- заглушки системных команд -------------------------------------------
# sudo — просто выполняет команду от текущего пользователя;
# остальные — завершаются успешно, ничего не меняя в системе.
cat > "$BIN/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
for t in systemctl iptables ip6tables nft yay pacman dnf apt-get xbps-install zypper apk; do
    printf '#!/bin/sh\nexit 0\n' > "$BIN/$t"
done
chmod +x "$BIN"/*

# --- копия установщика с перенаправленными путями -------------------------
# /etc/byedpi -> build/selftest/root/etc/byedpi и т.д.
sed \
    -e "s|/etc/byedpi|$ROOT/etc/byedpi|g" \
    -e "s|/etc/systemd/system|$ROOT/etc/systemd/system|g" \
    -e "s|/etc/init.d|$ROOT/etc/init.d|g" \
    -e "s|/usr/local/bin/byedpi-start|$ROOT/usr/local/bin/byedpi-start|g" \
    -e "s|CIADPI=/usr/local/bin/ciadpi|CIADPI=/usr/bin/ciadpi|" \
    "$SCRIPT" > "$WORK/under-test.sh"

run_installer(){
    PATH="$BIN:$PATH" HOME="$ROOT/home" sh "$WORK/under-test.sh" "$@"
}

# Каталог, куда установщик реально положил конфиги (system или user scope).
find_dir(){
    for d in "$ROOT/etc/byedpi" "$ROOT/home/.config/byedpi"; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

pass=0; fail=0
ok(){   printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad(){  printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
check(){ # описание, условие(0)
    if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

echo "=== Самопроверка: $(basename "$SCRIPT") ==="

# --- 1. чистая установка --------------------------------------------------
echo "1) чистая установка (файлов нет)"
run_installer --no-test >"$WORK/t1.log" 2>&1
DIRA=$(find_dir) || true
check "каталог конфигов создан" "$([ -n "${DIRA:-}" ] && echo 0 || echo 1)"
if [ -n "${DIRA:-}" ]; then
    n=$(grep -vcE '^[[:space:]]*(#|$)' "$DIRA/hosts" 2>/dev/null || echo 0)
    check "hosts создан и содержит домены ($n)" "$([ "${n:-0}" -gt 50 ] && echo 0 || echo 1)"
    for d in rutracker.org nnmclub.to youtube.com rutor.info; do
        grep -qxF "$d" "$DIRA/hosts" 2>/dev/null
        check "в hosts есть $d" "$?"
    done
    check "rule непустой" "$([ -s "$DIRA/rule" ] && echo 0 || echo 1)"
    check "port непустой" "$([ -s "$DIRA/port" ] && echo 0 || echo 1)"
    check "conf непустой" "$([ -s "$DIRA/conf" ] && echo 0 || echo 1)"
    check "launcher создан" "$([ -x "$ROOT/usr/local/bin/byedpi-start" ] && echo 0 || echo 1)"
    check "юнит создан" "$(ls "$ROOT/etc/systemd/system/" | grep -q byedpi && echo 0 || echo 1)"
fi

# --- 2. повторная установка перезаписывает файлы -------------------------
echo "2) повторная установка: перезапись + бэкап"
if [ -n "${DIRA:-}" ]; then
    printf 'СТАРЫЙ-HOSTS\n' > "$DIRA/hosts"
    printf 'СТАРОЕ-ПРАВИЛО\n' > "$DIRA/rule"
    run_installer --update --no-test >"$WORK/t2.log" 2>&1
    check "hosts перезаписан свежим списком" "$(grep -qxF 'rutracker.org' "$DIRA/hosts" && ! grep -qxF 'СТАРЫЙ-HOSTS' "$DIRA/hosts" && echo 0 || echo 1)"
    check "rule перезаписан" "$(! grep -qxF 'СТАРОЕ-ПРАВИЛО' "$DIRA/rule" && echo 0 || echo 1)"
    check "бэкап hosts создан" "$(ls "$DIRA"/hosts.bak-* >/dev/null 2>&1 && echo 0 || echo 1)"
    check "в бэкапе прежнее содержимое" "$(grep -qxF 'СТАРЫЙ-HOSTS' "$DIRA"/hosts.bak-* 2>/dev/null && echo 0 || echo 1)"
    check "бэкап rule создан" "$(ls "$DIRA"/rule.bak-* >/dev/null 2>&1 && echo 0 || echo 1)"

    # --- 3. --keep-files ---------------------------------------------------
    echo "3) --keep-files: файлы не трогаются"
    before_hosts=$(cat "$DIRA/hosts")
    before_baks=$(ls "$DIRA"/*.bak-* 2>/dev/null | wc -l)
    printf 'МОЙ-СПИСОК\n' > "$DIRA/hosts"
    run_installer --update --no-test --keep-files >"$WORK/t3.log" 2>&1
    check "hosts не перезаписан" "$(grep -qxF 'МОЙ-СПИСОК' "$DIRA/hosts" && echo 0 || echo 1)"
    check "новых бэкапов не появилось" "$([ "$(ls "$DIRA"/*.bak-* 2>/dev/null | wc -l)" -eq "$before_baks" ] && echo 0 || echo 1)"

    # --- 4. удаление -------------------------------------------------------
    echo "4) --off: удаление"
    run_installer --off >"$WORK/t4.log" 2>&1
    check "каталог конфигов удалён целиком (вместе с .bak)" "$([ ! -d "$DIRA" ] && echo 0 || echo 1)"
    check "launcher удалён" "$([ ! -e "$ROOT/usr/local/bin/byedpi-start" ] && echo 0 || echo 1)"
    check "юниты удалены" "$(ls "$ROOT/etc/systemd/system/" 2>/dev/null | grep -q byedpi && echo 1 || echo 0)"

    # --- 5. установка после удаления --------------------------------------
    echo "5) установка после удаления (с нуля)"
    run_installer --no-test >"$WORK/t5.log" 2>&1
    DIRA2=$(find_dir) || true
    check "каталог создан заново" "$([ -n "${DIRA2:-}" ] && echo 0 || echo 1)"
    if [ -n "${DIRA2:-}" ]; then
        check "hosts снова с доменами" "$(grep -qxF 'youtube.com' "$DIRA2/hosts" && echo 0 || echo 1)"
        check "после --off нет хвоста .bak" "$(ls "$DIRA2"/*.bak-* >/dev/null 2>&1 && echo 1 || echo 0)"
    fi
else
    bad "каталог конфигов не найден — дальше проверять нечего"
fi

echo
echo "Итог: PASS=$pass FAIL=$fail"
echo "Логи: $WORK/t*.log"
[ "$fail" -eq 0 ]
