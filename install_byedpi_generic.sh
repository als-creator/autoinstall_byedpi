#!/bin/sh
#
# ByeDPI generic installer — для ЛЮБОГО дистрибутива Linux.
#
# В отличие от autoinstall_byedpi_archlinux, НЕ требует пакетного менеджера:
# скачивает готовый бинарник ciadpi с GitHub (hufrea/byedpi releases),
# сам определяет разрядность/архитектуру и ставит в /usr/local/bin/ciadpi.
# Структура конфигов та же, что в Arch-установщике:
#
#   /etc/byedpi/conf   — управляющий конфиг (переменные-указатели)
#   /etc/byedpi/rule   — стратегия desync (отдельный файл)
#   /etc/byedpi/port   — порт (отдельный файл)
#   /etc/byedpi/hosts  — список доменов
#   /usr/local/bin/byedpi-start — launcher, собирающий опции ciadpi из файлов
#
# Автотест стратегий: при первой установке (и по команде --test) скрипт
# прогоняет список доменов через кандидатов правил desync и записывает
# лучшее правило в /etc/byedpi/rule (отключить: --no-test).
#
# Права root: определяется автоматически — от root напрямую, иначе sudo,
# иначе su (например, ALT Linux, где sudo нет, но есть su -).
#
# Демон: через systemd, если он используется (проверка /run/systemd/system),
# иначе через /etc/init.d/byedpi (start/stop).
#
set -u

usage(){
  cat <<EOF
Использование: $0 [--ipset|--extension] [--off|--status|--test|--check|--update] [--port N] [--no-test] [--keep-files] [--block-quic|--allow-quic]
  --ipset         метод ipset: весь TCP 80/443 через ByeDPI, фильтр по SNI
  --extension     метод extension: SOCKS-прокси для браузерного расширения
  --block-quic    блокировать UDP 443 (QUIC): браузер сразу идёт по TCP через
                  ByeDPI, без чёрного экрана на время таймаута HTTP/3
                  (по умолчанию включено для --ipset)
  --allow-quic    не блокировать QUIC (вернуть прежнее поведение)
  --test          перезапустить автотест стратегий и обновить /etc/byedpi/rule
  --check         проверить минимальный набор доменов (rutracker/nnm-club/
                  youtube/discord) и сказать, что именно не открывается
  --no-test       пропустить автотест стратегий при установке
  --keep-files    не трогать существующие hosts/rule (по умолчанию они
                  перезаписываются версией из скрипта, старое -> .bak-<дата>)
  --update        обновить hosts/rule/launcher/юнит из скрипта и перезапустить
  --off | --remove  отключить и удалить всё
  --status|--info   показать текущее состояние
  --port N        изменить порт
EOF
  exit 0
}

log_ok(){ echo "[OK] $*"; }
log_warn(){ echo "[WARN] $*"; }
log_err(){ echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Аргументы
# ---------------------------------------------------------------------------
METHOD=""          # ipset | extension
ACTION="install"   # install | update | off | status | test | check
KEEP_FILES=""      # --keep-files: не перезаписывать существующие hosts/rule
BLOCK_QUIC=""      # yes|no; пусто — взять из conf или по умолчанию (ipset: yes)
ARG_PORT=""
NO_TEST=""

for a in "$@"; do
  case "$a" in
    --ipset)     METHOD=ipset ;;
    --extension) METHOD=extension ;;
    --off|--remove) ACTION=off ;;
    --status|--info) ACTION=status ;;
    --test|--retest) ACTION=test ;;
    --check)    ACTION=check ;;
    --update|--upgrade) ACTION=update ;;
    --keep-files) KEEP_FILES=1 ;;
    --block-quic) BLOCK_QUIC=yes ;;
    --allow-quic) BLOCK_QUIC=no ;;
    --no-test)   NO_TEST=1 ;;
    --help|-h)   usage ;;
    --port=*)    ARG_PORT="${a#*=}" ;;
    *) log_err "Неизвестный аргумент: $a (см. $0 --help)" ;;
  esac
done
[ -z "$METHOD" ] && METHOD=extension
PORT="${ARG_PORT:-14228}"

CIADPI=/usr/local/bin/ciadpi
DIR=/etc/byedpi
CFG="$DIR/conf"
PORT_FILE="$DIR/port"
RULE_FILE="$DIR/rule"
HOSTS_FILE="$DIR/hosts"
LAUNCHER=/usr/local/bin/byedpi-start
IHOSTS="BYEDPI_HOSTS"
DESYNC_ACTIVE="-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -r1+s -S -a1 -As -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -S -a1"
DESYNC_FALLBACK=""
RULE="$DESYNC_ACTIVE $DESYNC_FALLBACK"

# ---------------------------------------------------------------------------
# Подъём прав: root → sudo → su
# ---------------------------------------------------------------------------
run_root(){ # строка-команда
  if [ "$(id -u)" -eq 0 ]; then
    /bin/sh -c "$1"
  elif command -v sudo >/dev/null 2>&1; then
    sudo /bin/sh -c "$1"
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/sh -c "$1" root
  else
    log_err "Нужны права root (нет ни sudo, ни su)."
  fi
}

# ---------------------------------------------------------------------------
# Скачивание ciadpi с GitHub (hufrea/byedpi releases).
# Адрес НЕ собирается из версии: файл под нашу архитектуру ищется в списке
# файлов последнего релиза, поэтому смена версии или имени файла его не
# ломает (в релизах byedpi файлы идут как byedpi-17.3-x86_64.tar.gz при
# теге v0.17.3 — собирать такой адрес из тега нельзя).
# ---------------------------------------------------------------------------
install_binary(){
  if [ -x "$CIADPI" ] && [ "$ACTION" = "install" ] && [ -z "$ARG_PORT" ]; then
    log_ok "ciadpi уже есть: $CIADPI"
    return 0
  fi
  case "$(uname -m)" in
    x86_64)             ARCH=x86_64;  TOKS="x86_64 amd64" ;;
    aarch64|arm64)      ARCH=aarch64; TOKS="aarch64 arm64" ;;
    armv7*|armhf)       ARCH=armv7l;  TOKS="armv7l armv7 armhf" ;;
    armv6*|arm)         ARCH=armv6;   TOKS="armv6" ;;
    i686|x86|i586|i486) ARCH=i686;    TOKS="i686 386" ;;
    mips)               ARCH=mips;    TOKS="mips" ;;
    mipsel)             ARCH=mipsel;  TOKS="mipsel" ;;
    powerpc|ppc*)       ARCH=powerpc; TOKS="powerpc ppc" ;;
    *) log_err "Незнакомая архитектура: $(uname -m)" ;;
  esac

  log_ok "Архитектура: $ARCH. Узнаю последний релиз byedpi..."
  api=$(curl -fsSL --max-time 30 https://api.github.com/repos/hufrea/byedpi/releases/latest 2>/dev/null || true)
  latest=$(printf '%s' "$api" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$latest" ] || latest=v0.17.3

  urls=""
  # 1) Ищем файл для нашей архитектуры в списке файлов последнего релиза
  for tok in $TOKS; do
    u=$(printf '%s' "$api" \
        | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*"\(https[^"]*\)".*/\1/' \
        | grep -i -- "$tok" | grep -Ei '\.(tar\.gz|tgz)$' | head -1)
    [ -n "$u" ] && { urls="$u"; break; }
  done
  # 2) Резерв: если список релиза недоступен (лимит API и т.п.), пробуем
  #    известные варианты имени — с полной версией и без ведущего "0."
  if [ -z "$urls" ]; then
    ver=$(printf '%s' "$latest" | tr -d 'v')
    urls="https://github.com/hufrea/byedpi/releases/download/$latest/byedpi-${ver#0.}-$ARCH.tar.gz
          https://github.com/hufrea/byedpi/releases/download/$latest/byedpi-$ver-$ARCH.tar.gz"
  fi

  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
  ok=
  for u in $urls; do
    log_ok "Скачиваю: $u"
    if curl -fsSL --max-time 120 -o "$tmpdir/byedpi.tgz" "$u"; then ok=1; break; fi
  done
  [ -n "$ok" ] || log_err "Не удалось скачать ciadpi (пробовал: $urls)"
  tar -xzf "$tmpdir/byedpi.tgz" -C "$tmpdir" || log_err "Не удалось распаковать архив"
  bin=$(find "$tmpdir" -maxdepth 1 -type f -name 'ciadpi*' | head -1)
  [ -n "$bin" ] || log_err "В архиве нет ciadpi"
  run_root "install -m 755 '$bin' $CIADPI"
  trap - EXIT HUP INT TERM
  rm -rf "$tmpdir"
  [ -x "$CIADPI" ] || log_err "ciadpi не установился: $CIADPI"
  log_ok "Установлен: $CIADPI"
}

# ---------------------------------------------------------------------------
# Автотест стратегий
# ---------------------------------------------------------------------------
probe_direct(){ # домен -> 0, если открывается "как есть" (без прокси).
    # 3 попытки: часть блокировок статистическая (DPI смотрит не все потоки),
    # одиночный запрос не показателен.
    i=0
    while [ $i -lt 3 ]; do
        code=$(curl -k -sS -m 8 -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && return 0
        i=$((i+1)); sleep 0.5
    done
    return 1
}

# Минимальный набор доменов, который обязан открываться:
#   rutor / rutracker / nnm-club / youtube
# Именно по нему выбирается правило desync.
TEST_PROBES="rutracker.org nnmclub.to www.youtube.com redirector.googlevideo.com i.ytimg.com yt3.googleusercontent.com discord.com"

TEST_RULES="\
long-strategy|-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -r1+s -S -a1 -As -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -S -a1
multisplit-d1|-Kt,h -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -s25+s -s30+s -s35+s -r1+s -S -a1 -As
disorder-sni|-Kt,h --disorder 1 -s0 -r1+s -f-1 -a5 -An
tlsrec-disorder|-Kt,h --tlsrec 1+s --disorder 1 --auto=torst --timeout 3
fake-found|-Kt,h --fake -1 --md5sig --auto=torst --timeout 3
disorder-1|-Kt,h --disorder 1 --auto=torst --timeout 3
split-1|-Kt,h --split 1+s --disorder 3+s --auto=torst --timeout 3
tlsrec-3|-Kt,h --tlsrec 3+s --auto=torst --timeout 3
base-long|-Kt,h -s0 -o1 -Ar -o1 -At -f-1 --md5sig -r1+s -As,n -Ku -a5 -An"

test_strategies(){ # hostlist-файл -> on stdout лучшее правило; прогресс в stderr
    hosts="$1"
    [ -f "$hosts" ] || log_err "Нет hostlist: $hosts"
    command -v curl >/dev/null 2>&1 || log_err "Для автотеста нужно curl"
    [ -x "$CIADPI" ] || log_err "Нет ciadpi: $CIADPI"

    tport=$(( 14600 + ($$ % 250) ))
    resfile="/tmp/byedpi-test-$$.res"
    rawdir="/tmp/byedpi-probes-$$"
    mkdir -p "$rawdir"
    > "$resfile"

    echo "=== Автотест стратегий desync ===" >&2
    echo "Минимальный набор: $TEST_PROBES" >&2
    printf '%b\n' "$TEST_RULES" | while IFS='|' read -r name rule; do
      [ -n "$rule" ] || continue
      "$CIADPI" -H "$hosts" -i 127.0.0.1 --port "$tport" $rule >/dev/null 2>&1 &
      cpid=$!
      sleep 0.6
      pdir="$rawdir/$name"
      rm -rf "$pdir"; mkdir -p "$pdir"
      i=0
      curls=""
      for h in $TEST_PROBES; do
        i=$((i+1))
        ( code=$(curl -k -sS -m 6 --socks5-hostname 127.0.0.1:"$tport" -o /dev/null -w "%{http_code}" "https://$h/" 2>/dev/null)
          echo "$code" > "$pdir/$i" ) &
        curls="$curls $!"
      done
      wait $curls
      kill "$cpid" 2>/dev/null
      wait "$cpid" 2>/dev/null
      ok=0; total=0; line=""
      for h in $TEST_PROBES; do
        total=$((total+1))
        code=$(cat "$pdir/$total" 2>/dev/null)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
          ok=$((ok+1)); line="$line $h=OK"
        else
          line="$line $h=FAIL"
        fi
      done
      printf '  [%-16s] %s\n' "$name" "$line" >&2
      echo "$name|$ok|$total|$rule" >> "$resfile"
    done

    # Домены, не открывшиеся НИ ОДНИМ правилом: скорее всего заблокированы по IP
    # либо по TLS-отпечатку (JA3). desync по SNI такие блокировки не снимает.
    unreachable=""
    for h in $TEST_PROBES; do
      opened=0
      for d in "$rawdir"/*; do
        [ -d "$d" ] || continue
        idx=0
        for h2 in $TEST_PROBES; do
          idx=$((idx+1))
          [ "$h2" = "$h" ] || continue
          code=$(cat "$d/$idx" 2>/dev/null)
          [ -n "$code" ] && [ "$code" != "000" ] && opened=1
        done
      done
      [ "$opened" -eq 0 ] && unreachable="$unreachable $h"
    done
    if [ -n "$unreachable" ]; then
      log_warn "Не открылись ни одним правилом:$unreachable" >&2
      for h in $unreachable; do
        probe_direct "$h" && log_warn "  $h: напрямую открывается — домен не в списке desync ($HOSTS_FILE)" >&2 \
          || log_warn "  $h: напрямую тоже не открывается — блок по IP или по отпечатку ClientHello (JA3)" >&2
      done
    fi

    best=""; bname=""; bscore=-1; btotal=0
    while IFS='|' read -r name score total rule; do
      if [ "${score:-0}" -gt "$bscore" ]; then
        bscore=$score; btotal=$total; bname=$name; best=$rule
      fi
    done < "$resfile"
    rm -rf "$rawdir"
    rm -f "$resfile"

    if [ -z "$best" ]; then
      log_warn "Ни одно правило не открыло ни одного домена (проверьте сеть/DNS)." >&2
      echo "$DESYNC_ACTIVE $DESYNC_FALLBACK"
      return 0
    fi
    echo "=== Лучшая стратегия: [$bname] → открылось $bscore из $btotal ===" >&2
    echo "$best"
}

# ---------------------------------------------------------------------------
# Запись файлов
# ---------------------------------------------------------------------------
wroot(){ # строка команды (root)
  run_root "$1"
}

wfile_root(){ # путь, содержимое
  run_root "mkdir -p '$(dirname "$1")'; printf '%s\\n' '$2' > '$1'"
}

# Копия файла перед перезаписью: имя.bak-YYYYmmdd-HHMMSS.
# Если копировать не удалось — предупреждаем и продолжаем.
backup_file(){ # путь -> путь к копии (stdout), код 1 если копии нет
    f="$1"
    [ -f "$f" ] || return 0
    b="$f.bak-$(date +%Y%m%d-%H%M%S)"
    case "$f" in
        "$HOME"/*) cp -p "$f" "$b" 2>/dev/null || cp "$f" "$b" 2>/dev/null || true ;;
        *)         run_root "cp -p '$f' '$b' 2>/dev/null || cp '$f' '$b' 2>/dev/null || true" ;;
    esac
    if [ -f "$b" ]; then
        echo "$b"; return 0
    fi
    log_warn "Не удалось создать резервную копию $f (нет прав?) — будет перезаписано без бэкапа" >&2
    echo ""
    return 1
}

write_port(){
  if [ -f "$PORT_FILE" ]; then
    if [ -n "$ARG_PORT" ]; then
      wfile_root "$PORT_FILE" "$PORT"
      log_warn "Порт обновлён: $PORT_FILE → $PORT"
    else
      PORT=$(grep -E '^[0-9]+$' "$PORT_FILE" | head -1)
      [ -z "$PORT" ] && { PORT=14228; wfile_root "$PORT_FILE" "$PORT"; }
      log_ok "Порт (из файла): $PORT"
    fi
  else
    wfile_root "$PORT_FILE" "$PORT"
    log_ok "Порт: $PORT_FILE → $PORT"
  fi
}

write_hostlist(){
  # По умолчанию список всегда перезаписывается тем, что зашито в скрипт
  # (скрипт качается с сервера — значит список всегда актуальный).
  # Старая версия сохраняется рядом: hosts.bak-<дата>.
  # Флаг --keep-files возвращает прежнее поведение «не трогать, если есть».
  if [ -f "$HOSTS_FILE" ]; then
    if [ -n "$KEEP_FILES" ]; then
      log_warn "Hostlist уже есть и --keep-files задан, не перезаписан: $HOSTS_FILE"
      return 0
    fi
    bak=$(backup_file "$HOSTS_FILE")
    [ -n "$bak" ] && log_warn "Hostlist обновляется из скрипта, предыдущий сохранён: $bak"
  fi
  run_root "mkdir -p '$DIR'"
  cat > /tmp/byedpi-hosts.$$ <<'EOL'
# ByeDPI hostlist — домены, к которым применяется desync.
# Формат: один домен на строку, строки с # игнорируются.
# Правка: отредактируйте и перезапустите сервисы (см. README).
#
# --- МИНИМУМ (проверяется командой `скрипт --check`) -----------------------
# Rutor
rutor.info
rutor.is
# Rutracker
rutracker.org
rutracker.cc
# NNM-Club
nnmclub.to
nnmclub.me
# YouTube (включая CDN-поддомены)
youtube.com
googlevideo.com
ytimg.com
ggpht.com
youtu.be
yt.be
play.google.com
youtubei.googleapis.com
youtube.googleapis.com
yt3.googleusercontent.com
news.google.com
# CDN и служебные домены (проверено резолвом)
# YouTube: apex-ы часто без A-записи, но нужны для матчинга поддоменов
gstatic.com
googleusercontent.com
l.google.com
1e100.net
m.youtube.com
img.youtube.com
yt3.ggpht.com
yt4.ggpht.com
youtube.ru
# ---------------------------------------------------------------------------
# Остальные домены (Discord, соцсети, архивы, обход блокировок)
cdnbunny.org
habr.com
instagram.com
archlinuxgui.in
sourceforge.net
scontent-hel3-1.cdninstagram.com
cdninstagram.com
ntc.party
discord.com
discord.gg
opera.com
discordapp.com
discordapp.net
discord.media
discord-attachments-uploads-prd.storage.googleapis.com
dis.gd
discord.co
discordcdn.com
discordstatus.com
proton.me
twimg.com
torproject.org
archive.org
web.archive.org
soundcloud.com
mullvad.net
roskomsvoboda.org
medium.com
hybrid-analysis.com
4pda.to
chatgpt.com
facebook.com
bbc.com
addons.opera.com
twitter.com
holod.media
flibusta.lib
flibusta.is
flibusta.info
linkedin.com
t.co
# --- Заблокированные сервисы и медиа ---------------------------------------
# Проверено на живом провайдере: без desync соединение не устанавливается
# (curl = 000), с текущим правилом открываются.
signal.org
meduza.io
te-st.org
svoboda.org
currenttime.tv
novayagazeta.eu
ovdinfo.org
EOL
  run_root "tee '$HOSTS_FILE' > /dev/null < /tmp/byedpi-hosts.$$"
  rm -f /tmp/byedpi-hosts.$$
  log_ok "Hostlist записан: $HOSTS_FILE"
}

write_rule(){
  # Как и hostlist: по умолчанию перезаписываем, старое — в .bak
  if [ -f "$RULE_FILE" ]; then
    if [ -n "$KEEP_FILES" ]; then
      log_ok "Правило уже есть и --keep-files задан, не перезаписано: $RULE_FILE"
      return 0
    fi
    bak=$(backup_file "$RULE_FILE")
    [ -n "$bak" ] && log_warn "Правило обновляется, предыдущее сохранено: $bak"
  fi
  if [ -z "$NO_TEST" ]; then
    best=$(test_strategies "$HOSTS_FILE")
    [ -n "$best" ] && RULE="$best"
  fi
  wfile_root "$RULE_FILE" "$RULE"
  log_ok "Правило desync: $RULE_FILE"
}

write_conf(){
  if [ "$METHOD" = "ipset" ]; then MODE=transparent; else MODE=socks; fi
  if [ -f "$CFG" ]; then
    if grep -Fq "BYEDPI_MODE=\"$MODE\"" "$CFG"; then
      log_ok "Конфиг уже есть, не перезаписан: $CFG"
      return 0
    fi
  fi
  wfile_root "$CFG" "BYEDPI_MODE=\"$MODE\"
# ByeDPI — управляющий конфиг. Порт/правило/список доменов лежат в файлах,
# на которые указывают переменные ниже.
BYEDPI_BIND=\"127.0.0.1\"
BYEDPI_PORT_FILE=\"$PORT_FILE\"
BYEDPI_RULE_FILE=\"$RULE_FILE\"
BYEDPI_HOSTS_FILE=\"$HOSTS_FILE\"
# Блокировка QUIC (UDP 443): браузер сразу идёт по TCP через ByeDPI.
BYEDPI_BLOCK_QUIC=\"$BLOCK_QUIC\""
  log_ok "Конфиг: $CFG"
}

# ---------------------------------------------------------------------------
# QUIC (UDP 443)
#
# ByeDPI перехватывает только TCP (REDIRECT -p tcp). UDP 443 идёт мимо, и если
# провайдер его режет, браузер висит на HTTP/3 до таймаута: YouTube показывает
# чёрный экран/крутилку, хотя TCP через ByeDPI работает. Быстрый REJECT
# заставляет браузер сразу переключиться на TCP.
# ---------------------------------------------------------------------------
quic_flag_from_conf(){
  [ -f "$CFG" ] || return 1
  v=$(sed -n 's/^BYEDPI_BLOCK_QUIC="\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' "$CFG" | head -1)
  [ -n "$v" ] || return 1
  echo "$v"
}

# Итоговое значение: флаг из аргументов > значение из conf > по умолчанию.
# По умолчанию блокируем только в transparent (ipset): в socks-режиме браузер
# и так ходит через прокси, а QUIC при прокси не используется.
resolve_quic_flag(){
  if [ -z "$BLOCK_QUIC" ]; then
    # При явной установке берём значение по умолчанию для выбранного метода;
    # при --update сохраняем то, что пользователь выбрал раньше.
    if [ "$ACTION" != "install" ] && v=$(quic_flag_from_conf); then
      BLOCK_QUIC=$v
    elif [ "$METHOD" = "ipset" ]; then
      BLOCK_QUIC=yes
    else
      BLOCK_QUIC=no
    fi
  fi
  if [ "$BLOCK_QUIC" = "yes" ] && [ "$METHOD" != "ipset" ]; then
    log_warn "QUIC блокируется только в --ipset (transparent); в --extension правило не нужно"
    BLOCK_QUIC=no
  fi
}

# Сохранить выбор в conf, чтобы --status/--check/--update его видели.
write_quic_flag(){
  [ -f "$CFG" ] || return 0
  cur=$(quic_flag_from_conf) || cur=""
  [ "$cur" = "$BLOCK_QUIC" ] && return 0
  if [ -n "$cur" ]; then
    run_root "sed -i 's|^BYEDPI_BLOCK_QUIC=.*|BYEDPI_BLOCK_QUIC=\"$BLOCK_QUIC\"|' '$CFG'"
  else
    run_root "printf '%s\\n' 'BYEDPI_BLOCK_QUIC=\"$BLOCK_QUIC\"' >> '$CFG'"
  fi
}

write_launcher(){
  run_root "mkdir -p /usr/local/bin"
  cat > /tmp/byedpi-launcher.$$ <<'EOF'
#!/bin/sh
# ByeDPI launcher: собирает опции ciadpi из отдельных файлов конфига.
# Использование: byedpi-start [путь/conf]   (по умолчанию /etc/byedpi/conf)
set -u
CFG="${1:-/etc/byedpi/conf}"
[ -f "$CFG" ] || { echo "byedpi-start: нет конфига $CFG" >&2; exit 1; }
. "$CFG"

for v in BYEDPI_PORT_FILE BYEDPI_RULE_FILE BYEDPI_HOSTS_FILE; do
  eval "f=\${$v:-}"
  [ -n "$f" ] || { echo "byedpi-start: в $CFG не задано $v" >&2; exit 1; }
  [ -r "$f" ] || { echo "byedpi-start: нет файла $v = $f" >&2; exit 1; }
done

CIADPI_BIN="${BYEDPI_BIN:-}"
[ -n "$CIADPI_BIN" ] || CIADPI_BIN=$(command -v ciadpi 2>/dev/null || echo /usr/local/bin/ciadpi)
[ -x "$CIADPI_BIN" ] || { echo "byedpi-start: нет ciadpi ($CIADPI_BIN)" >&2; exit 1; }

BIND="${BYEDPI_BIND:-127.0.0.1}"
PORT="$(cat "$BYEDPI_PORT_FILE")"
RULE="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$BYEDPI_RULE_FILE")"
case "${BYEDPI_MODE:-socks}" in
  transparent) exec "$CIADPI_BIN" -E -H "$BYEDPI_HOSTS_FILE" -i "$BIND" --port "$PORT" $RULE ;;
  socks)       exec "$CIADPI_BIN" -i "$BIND" --port "$PORT" $RULE ;;
  *) echo "byedpi-start: неизвестный BYEDPI_MODE=$BYEDPI_MODE" >&2; exit 1 ;;
esac
EOF
  run_root "install -m 755 /tmp/byedpi-launcher.$$ $LAUNCHER"
  rm -f /tmp/byedpi-launcher.$$
  log_ok "Launcher: $LAUNCHER"
}

# ---------------------------------------------------------------------------
# Демон: systemd (если используется) или /etc/init.d/byedpi
# ---------------------------------------------------------------------------
SYSTEMD=no
command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && SYSTEMD=yes

service_ctl(){ # действие (start|stop|restart|enable|disable)
  if [ "$SYSTEMD" = "yes" ]; then
    run_root "systemctl $1 byedpi"
  else
    run_root "/etc/init.d/byedpi $1"
  fi
}

write_units(){
  if [ "$SYSTEMD" = "yes" ]; then
    run_root "mkdir -p /etc/systemd/system"
    cat > /tmp/byedpi-unit.$$ <<EOF
[Unit]
Description=ByeDPI
Documentation=https://github.com/hufrea/byedpi
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LAUNCHER $CFG
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    run_root "install -m 644 /tmp/byedpi-unit.$$ /etc/systemd/system/byedpi.service"
    rm -f /tmp/byedpi-unit.$$
    run_root "systemctl daemon-reload"

    if [ "$METHOD" = "ipset" ]; then
      cat > /tmp/byedpi-redirect.$$ <<EOF
[Unit]
Description=ByeDPI transparent redirect rules (SNI через --hosts)
Wants=byedpi.service
After=byedpi.service
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
. $CFG; \
P="\$(cat "\$BYEDPI_PORT_FILE")"; \
iptables -t nat -N $IHOSTS 2>/dev/null || true; \
iptables -t nat -F $IHOSTS; \
iptables -t nat -A $IHOSTS -d 0.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -d 10.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -d 172.16.0.0/12 -j RETURN; \
iptables -t nat -A $IHOSTS -d 192.168.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -d 169.254.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -p tcp -m owner ! --uid-owner 0 -m multiport --dports 80,443 -j REDIRECT --to-ports "\$P"; \
while iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null; do :; done; \
iptables -t nat -A OUTPUT -j $IHOSTS'
ExecStop=/bin/sh -c '\
while iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null; do :; done; \
iptables -t nat -F $IHOSTS 2>/dev/null || true; \
iptables -t nat -X $IHOSTS 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
      run_root "install -m 644 /tmp/byedpi-redirect.$$ /etc/systemd/system/byedpi-redirect.service"
      rm -f /tmp/byedpi-redirect.$$
      run_root "systemctl daemon-reload"
      run_root "systemctl enable --now byedpi-redirect >/dev/null 2>&1 || true"

      if [ "$BLOCK_QUIC" = "yes" ]; then
        cat > /tmp/byedpi-quic.$$ <<'EOF'
[Unit]
Description=Block QUIC (UDP 443) so browsers use TCP through ByeDPI
Documentation=https://github.com/hufrea/byedpi
After=network-online.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
iptables -t filter -N BYEDPI_QUIC 2>/dev/null || true; \
iptables -t filter -F BYEDPI_QUIC; \
iptables -t filter -A BYEDPI_QUIC -p udp --dport 443 -m owner ! --uid-owner 0 -j REJECT --reject-with icmp-port-unreachable; \
while iptables -t filter -D OUTPUT -j BYEDPI_QUIC 2>/dev/null; do :; done; iptables -t filter -A OUTPUT -j BYEDPI_QUIC'
ExecStop=/bin/sh -c '\
while iptables -t filter -D OUTPUT -j BYEDPI_QUIC 2>/dev/null; do :; done; \
iptables -t filter -F BYEDPI_QUIC 2>/dev/null || true; \
iptables -t filter -X BYEDPI_QUIC 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
        run_root "install -m 644 /tmp/byedpi-quic.$$ /etc/systemd/system/byedpi-quic.service"
        rm -f /tmp/byedpi-quic.$$
        run_root "systemctl daemon-reload"
        run_root "systemctl enable --now byedpi-quic >/dev/null 2>&1 || true"
      fi
    fi
    # Юнит живёт только в transparent-режиме с включённой блокировкой:
    # в socks-режиме и при --allow-quic его нужно убрать (и почистить iptables).
    if { [ "$BLOCK_QUIC" != "yes" ] || [ "$METHOD" != "ipset" ]; } && \
       [ -f /etc/systemd/system/byedpi-quic.service ]; then
      run_root "systemctl disable --now byedpi-quic 2>/dev/null || true"
      run_root "rm -f /etc/systemd/system/byedpi-quic.service"
      run_root "systemctl daemon-reload"
      run_root "while iptables -t filter -D OUTPUT -j BYEDPI_QUIC 2>/dev/null; do :; done"
      run_root "iptables -t filter -F BYEDPI_QUIC 2>/dev/null || true"
      run_root "iptables -t filter -X BYEDPI_QUIC 2>/dev/null || true"
    fi
    log_ok "systemd-юниты: byedpi.service${METHOD:+ (+ redirect — ipset)}"
  else
    QUIC_START=""
    QUIC_STOP=""
    if [ "$BLOCK_QUIC" = "yes" ]; then
      QUIC_START='    iptables -t filter -N BYEDPI_QUIC 2>/dev/null || true; iptables -t filter -F BYEDPI_QUIC; iptables -t filter -A BYEDPI_QUIC -p udp --dport 443 -m owner ! --uid-owner 0 -j REJECT --reject-with icmp-port-unreachable; while iptables -t filter -D OUTPUT -j BYEDPI_QUIC 2>/dev/null; do :; done; iptables -t filter -A OUTPUT -j BYEDPI_QUIC'
      QUIC_STOP='  while iptables -t filter -D OUTPUT -j BYEDPI_QUIC 2>/dev/null; do :; done; iptables -t filter -F BYEDPI_QUIC 2>/dev/null || true; iptables -t filter -X BYEDPI_QUIC 2>/dev/null || true'
    fi
    cat > /tmp/byedpi-initd.$$ <<EOF
#!/bin/sh
# ByeDPI init-скрипт (без systemd). Запускает launcher и настраивает iptables.
CFG=$CFG
LAUNCHER=$LAUNCHER
IHOSTS=$IHOSTS
start(){
  [ -f /run/byedpi.pid ] && { echo "ByeDPI уже работает"; return 0; }
  "$LAUNCHER" "\$CFG" > /var/log/byedpi.log 2>&1 &
  echo \$! > /run/byedpi.pid
  if grep -q 'transparent' "\$CFG"; then
    P="\$(cat "\$(sed -n 's/^BYEDPI_PORT_FILE="\([^"]*\)".*/\1/p' "\$CFG")")"
    iptables -t nat -N "\$IHOSTS" 2>/dev/null || true
    iptables -t nat -F "\$IHOSTS"
    iptables -t nat -A "\$IHOSTS" -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A "\$IHOSTS" -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A "\$IHOSTS" -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A "\$IHOSTS" -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A "\$IHOSTS" -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A "\$IHOSTS" -p tcp -m owner ! --uid-owner 0 -m multiport --dports 80,443 -j REDIRECT --to-ports "\$P"
    while iptables -t nat -D OUTPUT -j "\$IHOSTS" 2>/dev/null; do :; done
    iptables -t nat -A OUTPUT -j "\$IHOSTS"
$QUIC_START
  fi
  echo "ByeDPI запущен (pid \$(cat /run/byedpi.pid))"
}
stop(){
  [ -f /run/byedpi.pid ] && kill \$(cat /run/byedpi.pid) 2>/dev/null
  rm -f /run/byedpi.pid
  while iptables -t nat -D OUTPUT -j "\$IHOSTS" 2>/dev/null; do :; done
  iptables -t nat -F "\$IHOSTS" 2>/dev/null || true
  iptables -t nat -X "\$IHOSTS" 2>/dev/null || true
$QUIC_STOP
  echo "ByeDPI остановлен"
}
case "\$1" in
  start) start ;;
  stop)  stop ;;
  restart|force-reload) stop; sleep 1; start ;;
  status) pgrep -f "ciadpi.*--port" >/dev/null && echo "ByeDPI: работает" || echo "ByeDPI: не работает" ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
    run_root "install -m 755 /tmp/byedpi-initd.$$ /etc/init.d/byedpi"
    rm -f /tmp/byedpi-initd.$$
    log_ok "init-скрипт: /etc/init.d/byedpi (systemd не используется)"
  fi
}

# ---------------------------------------------------------------------------
# status / off / test
# ---------------------------------------------------------------------------
cmd_status(){
  echo "=== ByeDPI: статус ==="
  if [ "$SYSTEMD" = "yes" ]; then
    run_root "systemctl --no-pager status byedpi 2>/dev/null | head -8 || true" || true
    [ -f /etc/systemd/system/byedpi-redirect.service ] && \
      run_root "systemctl --no-pager status byedpi-redirect 2>/dev/null | head -4 || true" || true
  elif [ -f /etc/init.d/byedpi ]; then
    /etc/init.d/byedpi status 2>/dev/null || true
  else
    echo "ByeDPI не установлен (нет юнита/init-скрипта)"
  fi
  [ -f /etc/byedpi/conf ] && { echo "system config: /etc/byedpi/conf";    [ -f /etc/byedpi/rule ] && echo "rule: $(cat /etc/byedpi/rule)";   [ -f /etc/byedpi/port ] && echo "port: $(cat /etc/byedpi/port)"; }
  if [ -f "$CFG" ]; then
    m=$(current_mode)
    echo "режим:   $m"
    if [ "$m" = "transparent" ]; then
      if systemctl is-active --quiet byedpi-redirect 2>/dev/null; then
        echo "перехват: активен (byedpi-redirect)"
      else
        echo "перехват: [WARN] НЕ активен (byedpi-redirect) — трафик идёт мимо byedpi"
      fi
      if [ "$(quic_flag_from_conf 2>/dev/null || echo no)" = "yes" ]; then
        echo "QUIC:     UDP 443 блокируется (byedpi-quic) — браузер пойдёт по TCP"
      else
        echo "QUIC:     не блокируется (UDP 443 идёт мимо byedpi)"
      fi
      echo "браузер:  напрямую; socks5 $PORT в transparent не работает (расширение выключить)"
    else
      echo "браузер:  через socks5 127.0.0.1:$PORT"
    fi
  fi
  exit 0
}

cmd_off(){
  echo "=== Отключение ByeDPI ==="
  if [ "$SYSTEMD" = "yes" ]; then
    for n in byedpi byedpi-redirect byedpi-quic; do
      run_root "systemctl disable --now $n 2>/dev/null || true"
    done
    run_root "rm -f /etc/systemd/system/byedpi.service /etc/systemd/system/byedpi-redirect.service /etc/systemd/system/byedpi-quic.service; systemctl daemon-reload 2>/dev/null || true"
  fi
  run_root "rm -f /etc/init.d/byedpi"
  # Снять ВСЕ ссылки на цепочки: за время работы юнит мог добавить их
  # несколько раз (каждый restart), а -D удаляет только одно вхождение.
  # Если оставить хоть одну, REDIRECT уведёт трафик в мёртвый порт.
  for c in $IHOSTS BYEDPI BYEDPI_HOSTS BYEDPI_$(id -u) BYEDPI_HOSTS_$(id -u); do
    run_root "while iptables -t nat -D OUTPUT -j $c 2>/dev/null; do :; done; iptables -t nat -F $c 2>/dev/null || true; iptables -t nat -X $c 2>/dev/null || true"
  done
  for c in BYEDPI_QUIC BYEDPI_QUIC_$(id -u); do
    run_root "while iptables -t filter -D OUTPUT -j $c 2>/dev/null; do :; done; iptables -t filter -F $c 2>/dev/null || true; iptables -t filter -X $c 2>/dev/null || true"
  done
  run_root "rm -rf $DIR $LAUNCHER /usr/local/bin/ciadpi"
  echo "ByeDPI отключён. Конфиги и бинарник удалены."
  exit 0
}

cmd_test(){
  [ -f "$HOSTS_FILE" ] || log_err "Нет hostlist: $HOSTS_FILE (сначала установите ByeDPI)."
  best=$(test_strategies "$HOSTS_FILE")
  wfile_root "$RULE_FILE" "$best"
  log_ok "Правило записано: $RULE_FILE"
  service_ctl restart
  log_ok "Демон перезапущен."
}

# Проверка минимального набора доменов через работающий демон.
# Для каждого домена: OK / статистическая фильтрация / нет-в-списке /
# блок по IP или по отпечатку ClientHello.
# Режим работы из конфига: transparent | socks
current_mode(){
  m=""
  if [ -f "$CFG" ]; then
    m=$(sed -n 's/^BYEDPI_MODE="\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' "$CFG" | head -1)
  fi
  echo "${m:-socks}"
}

# Одна проба домена тем путём, которым реально ходит трафик:
# transparent — напрямую (перехватывает iptables), socks — через SOCKS5.
probe_via_mode(){ # домен -> http_code
  if [ "$(current_mode)" = "transparent" ]; then
    curl -k -sS -m 8 -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null
  else
    curl -k -sS -m 8 --socks5-hostname 127.0.0.1:"$PORT" -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null
  fi
}

# Проверка минимального набора доменов тем путём, которым ходит браузер.
cmd_check(){
  command -v curl >/dev/null 2>&1 || log_err "Для проверки нужен curl"
  mode=$(current_mode)
  echo "=== Проверка минимального набора доменов ==="
  echo "Режим: $mode"
  [ -f "$RULE_FILE" ] && echo "Правило: $(cat "$RULE_FILE")"
  if [ "$mode" = "transparent" ]; then
    echo "  Трафик TCP 80/443 перехватывает iptables (REDIRECT) — браузер ходит напрямую."
    if systemctl is-active --quiet byedpi-redirect 2>/dev/null; then
      echo "  Перехват: активен (byedpi-redirect)"
    else
      echo "  [WARN] Перехват не активен: systemctl status byedpi-redirect"
    fi
    sc=$(curl -k -sS -m 4 --socks5-hostname 127.0.0.1:"$PORT" -o /dev/null -w '%{http_code}' https://www.youtube.com/ 2>/dev/null)
    if [ "$sc" = "000" ]; then
      echo "  [WARN] Порт $PORT не принимает SOCKS5 — в transparent так и должно быть."
      echo "         Если браузер/ZeroOmega настроен на socks5 127.0.0.1:$PORT,"
      echo "         выключите расширение (или профиль 'прямое соединение'), иначе"
      echo "         сайты не откроются: SOCKS-запросы уходят в никуда."
    fi
  else
    echo "  Браузер должен ходить через SOCKS5 127.0.0.1:$PORT."
    echo "  Перехвата iptables нет: без прокси в браузере трафик идёт напрямую."
  fi
  echo
  for h in $TEST_PROBES; do
    # 3 попытки: DPI бывает статистическим и открывает не каждый поток
    i=0; code=""
    while [ $i -lt 3 ]; do
      code=$(probe_via_mode "$h")
      [ -n "$code" ] && [ "$code" != "000" ] && break
      i=$((i+1)); sleep 0.5
    done
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      if [ $i -gt 0 ]; then
        printf '  %-30s OK с %d-й попытки (%s) — фильтрация статистическая\n' "$h" "$((i+1))" "$code"
      else
        printf '  %-30s OK (%s)\n' "$h" "$code"
      fi
      continue
    fi
    inlist=no
    if [ -f "$HOSTS_FILE" ]; then
      re=$(printf '%s' "$h" | sed 's/\./\\./g')
      grep -qE "^[[:space:]]*${re}([[:space:]]*\$|[[:space:]]*#)" "$HOSTS_FILE" 2>/dev/null && inlist=yes
    fi
    if [ "$inlist" = yes ]; then
      printf '  %-30s FAIL 3/3 (домен есть в hosts) — desync не помогает\n' "$h"
    elif probe_direct "$h"; then
      printf '  %-30s FAIL (напрямую открывается, но домена нет в hosts)\n' "$h"
    else
      printf '  %-30s FAIL 3/3 — блок по IP или по отпечатку ClientHello (JA3)\n' "$h"
    fi
  done
  echo
  echo "Подсказка: если домен открывается напрямую (curl без прокси) — добавьте его"
  echo "в $HOSTS_FILE и перезапустите демон. Если FAIL 3/3 и напрямую, то"
  echo "блокируют либо по IP, либо по TLS-отпечатку (JA3) — desync/SNI не поможет."
  if [ "$mode" = "transparent" ]; then
    # QUIC (UDP 443) ByeDPI не перехватывает: REDIRECT только для TCP. Если
    # провайдер режет UDP 443, браузер висит на HTTP/3 до таймаута — это и есть
    # чёрный экран/крутилка YouTube при рабочем TCP. Проверяем фактически.
    qflag=$(quic_flag_from_conf 2>/dev/null || echo no)
    if [ "$qflag" = "yes" ]; then
      echo "QUIC:     UDP 443 блокируется (byedpi-quic) — браузер идёт по TCP, ок"
    elif curl --version 2>/dev/null | grep -qi 'HTTP3'; then
      q_ok=0
      for i in 1 2 3; do
        c=$(curl -sS --http3-only -m 5 -o /dev/null -w '%{http_code}' https://www.youtube.com/ 2>/dev/null)
        [ -n "$c" ] && [ "$c" != "000" ] && q_ok=$((q_ok+1))
      done
      if [ "$q_ok" -eq 0 ]; then
        echo "QUIC:     [WARN] 0/3 — UDP 443 не проходит, а блокировка выключена."
        echo "          Браузер может висеть на HTTP/3 (чёрный экран YouTube)."
        echo "          Лечится: $0 --update --block-quic"
      else
        echo "QUIC:     $q_ok/3 проходит — блокировка не требуется"
      fi
    else
      echo "QUIC:     curl без поддержки HTTP/3 — проверить нельзя"
    fi
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Главный запуск
# ---------------------------------------------------------------------------
case "$ACTION" in
  status) cmd_status ;;
  off)    cmd_off ;;
  test)   cmd_test ;;
  check)  cmd_check ;;
  update)
    # Обновление из скрипта: hostlist, правило, launcher и юниты берутся
    # из загруженного скрипта, старое сохраняется в .bak. Порт не трогаем.
    install_binary
    write_hostlist
    write_rule
    resolve_quic_flag
    write_conf
    write_quic_flag
    write_launcher
    write_units
    service_ctl restart
    if [ -n "$KEEP_FILES" ]; then
      log_ok "Launcher и юниты обновлены. Hostlist/rule оставлены как были (--keep-files)."
    else
      log_ok "Обновлено: hostlist, правило desync, launcher и юниты."
    fi
    echo "Проверить результат: $0 --check"
    ;;
  install)
    install_binary
    write_port
    write_hostlist
    write_rule
    resolve_quic_flag
    write_conf
    write_quic_flag
    write_launcher
    write_units
    service_ctl restart
    log_ok "ByeDPI запущен."
    echo "═══════════════════════════════════════════════════════════"
    echo "  ByeDPI: метод=$METHOD порт=$PORT ($CIADPI)"
    echo "═══════════════════════════════════════════════════════════"
    echo "Каталог:  $DIR"
    echo "Правка:   nano /etc/byedpi/hosts (или rule/port); перезапуск: $0 --status"
    echo "          после правки любых файлов повторите $0 --status / restart."
    if [ "$METHOD" = "ipset" ]; then
      echo "  Прозрачный режим: весь TCP 80/443 -> ByeDPI, фильтр по SNI."
      if [ "$BLOCK_QUIC" = "yes" ]; then
        echo "  QUIC (UDP 443): заблокирован (byedpi-quic) — браузер идёт по TCP."
      else
        echo "  QUIC (UDP 443): не заблокирован — возможен чёрный экран YouTube."
      fi
    else
      echo "  SOCKS-прокси: 127.0.0.1:$PORT (расширения FoxyProxy/SwitchyOmega 3)."
    fi
    echo "Пересборка правила: $0 --test"
    echo "Обновить конфиги из свежего скрипта: $0 --update"
    echo "Не трогать существующие hosts/rule: добавьте --keep-files"
    ;;
esac