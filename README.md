# Стек мониторинга

Prometheus + Grafana в Docker: состояние VPS, скорость интернет-канала, ICMP/TCP-пробы,
метрики роутера Mikrotik. Внешний доступ через Cloudflare Tunnel с авторизацией Google,
уведомления в Telegram.

Все пути в документе — относительно корня проекта (`mymonitoring/`).

Домен Grafana, team domain Cloudflare и AUD-тег вынесены в `.env` — в
`docker-compose.yml` их нет. Остаётся заменить `VPS_IP` (публичный адрес VPS)
в `prometheus/prometheus.yml`, `docker-compose.yml` и дашборде, а также
`example.com` в настройках Cloudflare.

---

## 1. Архитектура

### Сервер мониторинга (LAN, `172.16.0.6`)

| Контейнер | Назначение | Порт (только на `172.16.0.6`) |
|---|---|---|
| `prometheus` | сбор и хранение метрик | 9090 |
| `grafana` | визуализация, алерты | 3000 |
| `blackbox` | ICMP- и TCP-пробы | 9115 |
| `pushgateway` | приём результатов iperf3 | 9091 |
| `iperf3-runner` | замер скорости раз в 10 минут | — |
| `mktxp` | метрики Mikrotik по RouterOS API | 49090 |
| `cloudflared` | туннель наружу | — |

### Внешние компоненты

- **VPS** (`VPS_IP`): `node_exporter` на `:46631`, `iperf3 -s` на `:46632`
- **`TEAM_DOMAIN`** — team domain Cloudflare Zero Trust
- **Mikrotik** (`172.16.0.1`): RouterOS API на `:8728`
- **Cloudflare**: туннель на `monitor.example.com`, Access с Google

### Почему стек в LAN, а не на VPS

Замеры скорости и ICMP должны идти **из локальной сети** — иначе меряется канал VPS.
Mikrotik доступен только изнутри.

### Принятые решения

- **«Средние за час»** — не отдельная метрика, а `avg_over_time(...[1h])` поверх тех же данных.
- **iperf3 через Pushgateway**, а не экспортёр: замер длится ~25 секунд и не может
  выполняться в момент скрейпа.
- **Порты привязаны к `172.16.0.6`**, а не к `0.0.0.0` — наружу ничего не торчит,
  из LAN доступно для отладки.

### Предполагается сделанным

На роутере заведён пользователь только для чтения с доступом к API, API-сервис включён
и ограничен адресом `172.16.0.6`. Настройка RouterOS в этот документ не входит.

---

## 2. Структура проекта

```
mymonitoring/
├── .env                  # не в git
├── .env.example
├── .gitignore
├── docker-compose.yml
├── prometheus/
│   └── prometheus.yml
├── blackbox/
│   └── blackbox.yml
├── iperf3/
│   ├── Dockerfile
│   └── run.sh
├── mktxp/
│   ├── _mktxp.conf
│   └── mktxp.conf
├── pushgateway/
│   └── data/
└── grafana/
    ├── dashboards/
    │   └── home-monitoring.json
    └── provisioning/
        ├── datasources/
        │   └── prometheus.yml
        ├── dashboards/
        │   └── dashboards.yml
        └── alerting/
            ├── alert-rules.yaml
            └── contact-points.yaml
```

Создать каркас:

```bash
mkdir -p prometheus blackbox iperf3 mktxp pushgateway/data \
         grafana/dashboards \
         grafana/provisioning/{datasources,dashboards,alerting}
```

---

## 3. Переменные окружения

Всё, что зависит от конкретной установки — учётные данные, токены, домены — лежит
в `.env` и подставляется в `docker-compose.yml` через `${VAR}`. Сам compose-файл
не содержит ни секретов, ни идентифицирующих значений и спокойно ложится в git.

### `.env`

```bash
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=длинный_пароль

CF_TUNNEL_TOKEN=eyJhIjoi...
GRAFANA_DOMAIN=monitor.example.com
CF_TEAM_DOMAIN=team
CF_ACCESS_AUD=aud_тег_приложения

TELEGRAM_BOT_TOKEN=1234567890:AAF...
TELEGRAM_CHAT_ID=-1001234567890
```

```bash
chmod 600 .env
```

| Переменная | Где взять |
|---|---|
| `CF_TUNNEL_TOKEN` | команда установки туннеля, значение после `--token` |
| `GRAFANA_DOMAIN` | полное имя, на котором опубликована Grafana |
| `CF_TEAM_DOMAIN` | Zero Trust → Settings → Custom Pages (без `.cloudflareaccess.com`) |
| `CF_ACCESS_AUD` | Access → Applications → Grafana → Overview → Application Audience Tag |
| `TELEGRAM_CHAT_ID` | `getUpdates`, поле `message.chat.id` |

Кавычки в `.env` **не снимаются** Docker Compose — они станут частью значения.
Писать без них. Символ `$` в значении экранируется удвоением (`$$`).

Для группы Telegram ID отрицательный, у супергруппы начинается с `-100`.

### `.env.example`

Шаблон для репозитория: структура без значений.

```bash
GRAFANA_ADMIN_USER=user
GRAFANA_ADMIN_PASSWORD=pass
CF_TUNNEL_TOKEN=token
TELEGRAM_BOT_TOKEN=token
TELEGRAM_CHAT_ID=chat_id
GRAFANA_DOMAIN=monitor.example.com
CF_TEAM_DOMAIN=domain
CF_ACCESS_AUD=aud_tag
```

`.env` — в `.gitignore`, `.env.example` — в git.

```bash
cat > .gitignore <<'EOF'
.env
mktxp/mktxp.conf
pushgateway/data/
*.tar.gz
EOF
```

Проверить подстановку перед запуском:

```bash
docker compose config | grep -E 'GF_SERVER|JWK_SET|aud'
```

В выводе должны стоять реальные значения, а не `${...}`.

## 4. Конфигурация сервисов

### `prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    monitor: home

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
        labels:
          host: monitoring

  - job_name: vps-node
    static_configs:
      - targets: ['VPS_IP:46631']
        labels:
          host: vps

  - job_name: pushgateway
    honor_labels: true
    static_configs:
      - targets: ['pushgateway:9091']

  - job_name: mikrotik
    scrape_interval: 60s
    scrape_timeout: 30s
    static_configs:
      - targets: ['mktxp:49090']

  - job_name: blackbox
    static_configs:
      - targets: ['blackbox:9115']

  - job_name: icmp
    metrics_path: /probe
    scrape_interval: 15s
    params:
      module: [icmp]
    static_configs:
      - targets:
          - 1.1.1.1
          - 8.8.8.8
          - VPS_IP
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  - job_name: tcp
    metrics_path: /probe
    scrape_interval: 30s
    params:
      module: [tcp_connect]
    static_configs:
      - targets:
          - VPS_IP:9003
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
```

**`honor_labels: true` для pushgateway обязателен.** Без него Prometheus перезапишет
метки `job` и `instance` из пуша своими, и метрики потеряют привязку к VPS.

**Три правила relabel** — стандартный паттерн multi-target exporter: Prometheus скрейпит
`blackbox`, а адрес цели передаёт параметром. Без второго правила все метрики слиплись
бы под одним `instance`.

**Интервал Mikrotik — 60 секунд**, таймаут 30. mktxp за один скрейп делает десятки
API-запросов к роутеру; дефолтных 10 секунд ему не хватает.

**Отдельный job `blackbox`** нужен для алерта на недоступность экспортёра. В job'ах
`icmp` и `tcp` метка `instance` относится к целям проб, а не к самому blackbox —
без self-scrape его падение дало бы четыре одинаковых алерта вместо одного.

---

### `blackbox/blackbox.yml`

```yaml
modules:
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4
      ip_protocol_fallback: false
      payload_size: 56

  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: ip4
      ip_protocol_fallback: false
```

---

### `iperf3/Dockerfile`

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache iperf3 curl jq bash coreutils
COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
```

### `iperf3/run.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail

IPERF_HOST="${IPERF_HOST:?not set}"
IPERF_PORT="${IPERF_PORT:-5201}"
IPERF_TIME="${IPERF_TIME:-10}"
IPERF_PARALLEL="${IPERF_PARALLEL:-4}"
INTERVAL="${INTERVAL:-600}"
PUSHGATEWAY="${PUSHGATEWAY:-http://pushgateway:9091}"
JOB="${JOB:-iperf3}"
INSTANCE="${INSTANCE:-vps}"

URL="${PUSHGATEWAY}/metrics/job/${JOB}/instance/${INSTANCE}"

log() { echo "[$(date -Is)] $*"; }

push() {
  curl -s --max-time 10 --data-binary @- "$URL" >/dev/null \
    && log "pushed ok" || log "push FAILED"
}

measure() {
  local direction="$1" extra="$2" out rc
  out=$(iperf3 -c "$IPERF_HOST" -p "$IPERF_PORT" -t "$IPERF_TIME" \
        -P "$IPERF_PARALLEL" -J --connect-timeout 5000 $extra 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    log "$direction: iperf3 failed (rc=$rc)"
    return 1
  fi
  if echo "$out" | jq -e '.error' >/dev/null 2>&1; then
    log "$direction: $(echo "$out" | jq -r '.error')"
    return 1
  fi
  echo "$out"
}

run_once() {
  local up_json down_json up_bps down_bps up_rtx down_rtx ok=1

  log "measuring upload..."
  if up_json=$(measure upload ""); then
    up_bps=$(echo "$up_json"   | jq -r '.end.sum_received.bits_per_second')
    up_rtx=$(echo "$up_json"   | jq -r '.end.sum_sent.retransmits // 0')
  else
    ok=0
  fi

  sleep 5

  log "measuring download..."
  if down_json=$(measure download "-R"); then
    down_bps=$(echo "$down_json" | jq -r '.end.sum_received.bits_per_second')
    down_rtx=$(echo "$down_json" | jq -r '.end.sum_sent.retransmits // 0')
  else
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    log "up=$(printf '%.1f' "$(echo "$up_bps/1000000" | bc -l)") Mbit/s  down=$(printf '%.1f' "$(echo "$down_bps/1000000" | bc -l)") Mbit/s"
    cat <<EOF | push
# TYPE iperf3_upload_bits_per_second gauge
# HELP iperf3_upload_bits_per_second Upload throughput measured by iperf3
iperf3_upload_bits_per_second $up_bps
# TYPE iperf3_download_bits_per_second gauge
# HELP iperf3_download_bits_per_second Download throughput measured by iperf3
iperf3_download_bits_per_second $down_bps
# TYPE iperf3_upload_retransmits gauge
iperf3_upload_retransmits $up_rtx
# TYPE iperf3_download_retransmits gauge
iperf3_download_retransmits $down_rtx
# TYPE iperf3_up gauge
# HELP iperf3_up 1 if last measurement succeeded
iperf3_up 1
# TYPE iperf3_last_run_timestamp_seconds gauge
iperf3_last_run_timestamp_seconds $(date +%s)
EOF
  else
    cat <<EOF | push
# TYPE iperf3_up gauge
iperf3_up 0
# TYPE iperf3_last_run_timestamp_seconds gauge
iperf3_last_run_timestamp_seconds $(date +%s)
EOF
  fi
}

log "started: host=$IPERF_HOST:$IPERF_PORT interval=${INTERVAL}s parallel=$IPERF_PARALLEL"

while true; do
  run_once
  now=$(date +%s)
  sleep $(( INTERVAL - (now % INTERVAL) ))
done
```

Решения внутри скрипта:

- **`sum_received`, а не `sum_sent`** — берётся то, что реально дошло. `sum_sent`
  завышает результат на объём ретрансмитов.
- **`-P 4`** — один TCP-поток на канале с задержкой не выбирает полосу, цифры получаются
  заниженными.
- **`sleep 5` между направлениями** — iperf3 server обслуживает одно подключение за раз.
- **Выравнивание по сетке** (`INTERVAL - now % INTERVAL`) — замеры попадают на 00, 10,
  20 минут, а не «плывут».
- **При неудаче пушится только `iperf3_up 0`.** POST заменяет лишь одноимённые метрики,
  поэтому последние известные скорости остаются на графике. Протухание ловится
  правилом на `iperf3_last_run_timestamp_seconds`.

---

### `mktxp/_mktxp.conf`

```ini
[MKTXP]
    listen = '0.0.0.0:49090'
    socket_timeout = 5

    initial_delay_on_failure = 120
    max_delay_on_failure = 900
    delay_inc_div = 5

    bandwidth = False
    bandwidth_test_interval = 600
    minimal_collect_interval = 5

    verbose_mode = False
    fetch_routers_in_parallel = False
    max_worker_threads = 5
    max_scrape_duration = 30
    total_max_scrape_duration = 90
```

`bandwidth = False` намеренно: встроенный btest нагружает канал и CPU роутера,
а скорость меряется через iperf3.

### `mktxp/mktxp.conf`

```ini
[Mikrotik]
    enabled = True
    hostname = 172.16.0.1
    port = 8728

    username = mktxp
    password = ПАРОЛЬ

    use_ssl = False
    no_ssl_certificate = False
    ssl_certificate_verify = False
    plaintext_login = True

    installed_packages = True
    dhcp = True
    dhcp_lease = True
    pool = True
    interface = True
    monitor = True
    route = True
    firewall = True
    ipv6_firewall = False
    ipv6_neighbor = False
    connections = True
    connection_stats = False
    poe = False
    netwatch = True
    public_ip = True
    wireless = False
    wireless_clients = False
    capsman = False
    capsman_clients = False
    lte = False
    ipsec = False
    switch_port = False
    user = True
    queue = True
    bgp = False
    check_for_updates = False

    use_comments_over_names = True
```

- **`plaintext_login = True`** обязателен для RouterOS 6.43+ — со старым
  челлендж-методом логин не пройдёт.
- **`use_comments_over_names = True`** — в метках будут комментарии интерфейсов
  вместо `ether3`.
- Коллекторы для отсутствующего железа (`wireless`, `capsman`, `poe`) выключены,
  иначе в логах будут ошибки на пустом месте.

**Права обязательны**, иначе контейнер упадёт с `PermissionError`:

```bash
docker run --rm --entrypoint sh ghcr.io/akpw/mktxp:latest -c 'id'   # узнать UID
chown -R 1000:1000 mktxp
chmod 700 mktxp
chmod 600 mktxp/*.conf
```

Каталог монтируется **без** `:ro` — mktxp при старте дописывает недостающие дефолты.

---

### `pushgateway/data`

```bash
chown -R 65534:65534 pushgateway/data
```

Pushgateway работает от `nobody`; без `chown` персистентность молча не работает.

---

## 5. Grafana: provisioning

### `grafana/provisioning/datasources/prometheus.yml`

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      timeInterval: 30s
    editable: false
```

`uid: prometheus` фиксирован — на него ссылаются панели дашборда и правила алертов.

Если Grafana уже запускалась без `uid` и падает с `data source not found`,
временно добавьте блок удаления перед `datasources:`, запустите, потом уберите:

```yaml
deleteDatasources:
  - name: Prometheus
    orgId: 1
```

### `grafana/provisioning/dashboards/dashboards.yml`

```yaml
apiVersion: 1

providers:
  - name: local
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

### `grafana/dashboards/home-monitoring.json`

Дашборд с пятью рядами:

1. **Интернет-канал** — текущие скорости, средние за час, возраст и статус замера,
   четыре графика, ретрансмиты TCP
2. **Доступность внешних узлов** — статусы трёх ICMP-целей и TCP-пробы, потери за час,
   графики RTT, потерь и времени TCP-подключения
3. **VPS** — доступность, uptime, bargauge загрузки, load average, графики CPU/память/сеть
4. **Mikrotik** — статус, uptime, загрузка, температуры платы и CPU, DHCP, соединения
5. **Трафик по интерфейсам** — отдельный график на каждый интерфейс, приём вверх,
   передача вниз (`custom.transform: negative-Y`), плюс общий график ошибок

Передача отражается через override, а не умножением на `-1` в запросе — иначе тултип
показывал бы отрицательные значения.

`allowUiUpdates: true` позволяет править панели в интерфейсе, но при рестарте правки
затрутся файлом. Чтобы сохранить: **Dashboard settings → JSON Model**, экспорт,
положить обратно в `grafana/dashboards/`.

---

## 6. `docker-compose.yml`

```yaml
name: monitoring

networks:
  monitor:
    driver: bridge

volumes:
  prometheus-data:
  grafana-data:

services:
  prometheus:
    image: prom/prometheus:v3.5.0
    container_name: prometheus
    restart: unless-stopped
    user: "65534:65534"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=90d
      - --web.enable-lifecycle
    volumes:
      - ./prometheus:/etc/prometheus:ro
      - prometheus-data:/prometheus
    ports:
      - "172.16.0.6:9090:9090"
    networks: [monitor]

  grafana:
    image: grafana/grafana:13.1.0
    container_name: grafana
    restart: unless-stopped
    depends_on: [prometheus]
    environment:
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_ANALYTICS_REPORTING_ENABLED: "false"

      GF_SERVER_ROOT_URL: "https://${GRAFANA_DOMAIN}"
      GF_SERVER_DOMAIN: "${GRAFANA_DOMAIN}"
      GF_SERVER_ENFORCE_DOMAIN: "false"

      GF_USERS_DEFAULT_THEME: "light"
      GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH: "/var/lib/grafana/dashboards/home-monitoring.json"

      GF_AUTH_JWT_ENABLED: "true"
      GF_AUTH_JWT_HEADER_NAME: "Cf-Access-Jwt-Assertion"
      GF_AUTH_JWT_EMAIL_CLAIM: "email"
      GF_AUTH_JWT_USERNAME_CLAIM: "email"
      GF_AUTH_JWT_JWK_SET_URL: "https://${CF_TEAM_DOMAIN}.cloudflareaccess.com/cdn-cgi/access/certs"
      GF_AUTH_JWT_EXPECT_CLAIMS: '{"aud":"${CF_ACCESS_AUD}"}'
      GF_AUTH_JWT_AUTO_SIGN_UP: "true"
      GF_AUTH_JWT_ROLE_ATTRIBUTE_PATH: "'Admin'"

      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN}
      TELEGRAM_CHAT_ID: ${TELEGRAM_CHAT_ID}
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    ports:
      - "172.16.0.6:3000:3000"
    networks: [monitor]

  blackbox:
    image: prom/blackbox-exporter:v0.27.0
    container_name: blackbox
    restart: unless-stopped
    command:
      - --config.file=/etc/blackbox/blackbox.yml
    volumes:
      - ./blackbox:/etc/blackbox:ro
    cap_add:
      - NET_RAW
    sysctls:
      net.ipv4.ping_group_range: "0 2147483647"
    ports:
      - "172.16.0.6:9115:9115"
    networks: [monitor]

  pushgateway:
    image: prom/pushgateway:v1.11.1
    container_name: pushgateway
    restart: unless-stopped
    command:
      - --persistence.file=/data/pushgateway.store
      - --persistence.interval=5m
    volumes:
      - ./pushgateway/data:/data
    ports:
      - "172.16.0.6:9091:9091"
    networks: [monitor]

  iperf3-runner:
    build: ./iperf3
    container_name: iperf3-runner
    restart: unless-stopped
    depends_on: [pushgateway]
    environment:
      IPERF_HOST: "VPS_IP"
      IPERF_PORT: "46632"
      IPERF_TIME: "10"
      IPERF_PARALLEL: "4"
      INTERVAL: "600"
      PUSHGATEWAY: "http://pushgateway:9091"
      JOB: "iperf3"
      INSTANCE: "vps"
    networks: [monitor]

  mktxp:
    image: ghcr.io/akpw/mktxp:latest
    container_name: mktxp
    restart: unless-stopped
    volumes:
      - ./mktxp:/home/mktxp/mktxp
    ports:
      - "172.16.0.6:49090:49090"
    networks: [monitor]

  cloudflared:
    image: cloudflare/cloudflared:2025.8.1
    container_name: cloudflared
    restart: unless-stopped
    depends_on: [grafana]
    command: tunnel --no-autoupdate --protocol http2 run --token ${CF_TUNNEL_TOKEN}
    networks: [monitor]
```

Все значения, зависящие от установки, приходят из `.env` через `${VAR}` — Compose
подставляет их и внутри одинарных кавычек, поэтому JSON в `GF_AUTH_JWT_EXPECT_CLAIMS`
не мешает.

`--protocol http2` обязателен — см. [раздел 9](#9-известные-проблемы).
Порядок аргументов важен: `--protocol` относится к `tunnel`, поэтому идёт **до** `run`.

Запуск:

```bash
docker compose up -d --build
docker compose ps
```

---

## 7. Cloudflare Tunnel и Access

### 7.1. Туннель

**Zero Trust → Networks → Tunnels → Create a tunnel**, тип Cloudflared.
Из показанной команды взять **только токен** (после `--token`) → в `.env`.

**Public Hostname:**

| Поле | Значение |
|---|---|
| Subdomain | `monitor` |
| Domain | `example.com` |
| Type | `HTTP` |
| URL | `grafana:3000` |

`grafana:3000` — имя контейнера в docker-сети. Тип `HTTP`, не HTTPS: TLS терминируется
на стороне Cloudflare.

DNS-запись создастся автоматически. Проверьте, что CNAME указывает на
`<tunnel-uuid>.cfargotunnel.com` и проксируется (оранжевое облако).

### 7.2. Google как провайдер

**Google Cloud Console → APIs & Services:**

1. **OAuth consent screen** — External, имя приложения, свой аккаунт в Test users
2. **Data Access → Add or remove scopes** — добавить `openid`,
   `.../auth/userinfo.email`, `.../auth/userinfo.profile`
3. **Library** — включить **Google People API**
4. **Credentials → Create OAuth client ID** → Web application
5. **Authorized redirect URI** (символ в символ):

```
https://TEAM_DOMAIN.cloudflareaccess.com/cdn-cgi/access/callback
```

**Zero Trust → Settings → Authentication → Login methods → Add new → Google**,
вставить Client ID и Secret, **Save** → **Test**.

Если Test возвращает `User email was not returned` — не добавлены scopes либо
не отозвано старое разрешение: `https://myaccount.google.com/permissions` → удалить
доступ приложения, затем войти заново. Если scopes добавлены уже после создания
провайдера — **провайдера нужно пересоздать**, он запоминает набор прав в момент
создания.

### 7.3. Приложение Access

**Access → Applications → Add an application → Self-hosted:**

| Поле | Значение |
|---|---|
| Application name | `Grafana` |
| Session Duration | `24 hours` |
| Subdomain / Domain | `monitor` / `example.com` |

В разделе Authentication:

- **выключить** `Authenticate with Cloudflare One Client` — иначе сохранение упадёт
  с ошибкой `allow_authenticate_via_warp cannot be set...`
- **выключить** `Accept all available identity providers`
- выбрать только **Google**, включить **Instant Auth**

Политика: Action `Allow`, Include → Selector `Emails`, Value — ваш адрес.

### 7.4. Единый вход (JWT)

Переменные `GF_AUTH_JWT_*` в compose убирают второй логин: Cloudflare подставляет
в каждый запрос заголовок `Cf-Access-Jwt-Assertion`, Grafana ему доверяет.

**AUD-тег** берётся в **Access → Applications → Grafana → Overview →
Application Audience (AUD) Tag** и кладётся в `.env` как `CF_ACCESS_AUD`.
Проверка `aud` обязательна — без неё Grafana примет
любой валидный токен организации, включая выданный другому приложению.

Локальный вход `http://172.16.0.6:3000` остаётся запасным: на этом пути заголовка нет,
показывается обычная форма с `admin`. Блок `ports` у grafana поэтому лучше не удалять.

---

## 8. Алерты в Telegram

### 8.1. Бот

`/newbot` у [@BotFather](https://t.me/BotFather) → токен. Написать боту (или добавить
в группу и написать там), затем:

```bash
curl -s "https://api.telegram.org/bot<ТОКЕН>/getUpdates" | python3 -m json.tool
```

Нужен `message.chat.id` — не `update_id` и не `message_id`.

### 8.2. `grafana/provisioning/alerting/contact-points.yaml`

Контактная точка типа `telegram` и политика маршрутизации. Токен и chat ID подставляются
из переменных окружения (`$TELEGRAM_BOT_TOKEN`, `$TELEGRAM_CHAT_ID`), поэтому файл можно
держать в git.

### 8.3. `grafana/provisioning/alerting/alert-rules.yaml`

| Правило | Условие | Задержка |
|---|---|---|
| Скорость канала ниже 30 Мбит/с | download или upload < 30 | 15 мин |
| Замеры скорости не обновляются | `time() - iperf3_last_run_timestamp_seconds > 1800` | 5 мин |
| Интерфейс Mikrotik не работает | `mktxp_interface_running == 0` | 2 мин |
| Потери пакетов выше 5% | за окно 10 минут | 5 мин |
| Узел недоступен по ICMP | `probe_success == 0` | 2 мин |
| Экспортёр недоступен | `up{job!~"icmp\|tcp"} == 0` | 3 мин |

**Про пороги потерь.** ICMP скрейпится раз в 15 секунд, значит за 5 минут — 20 проб,
и одна потерянная даёт ровно 5%. Порог «больше 2%» на таком окне бессмыслен. Поэтому
окно 10 минут: 40 проб, шаг 2.5%. Ниже 5% правило будет шуметь,
особенно до `8.8.8.8`, который депроритизирует ICMP.

**`noDataState: OK`** — если метрика исчезла, правило не сработает ложно.
Недоступность самих экспортёров при этом не теряется: её ловит отдельное правило
на `up == 0`.

**Правило «Экспортёр недоступен»** покрывает `vps-node`, `pushgateway`, `mikrotik`,
`blackbox` и сам `prometheus`. Job'ы `icmp` и `tcp` исключены фильтром `job!~"icmp|tcp"`:
их `up` относится к blackbox, который уже отслеживается своим job'ом.

`execErrState: Error` означает, что при недоступном Prometheus правила перейдут
в состояние ошибки и уведомление придёт — молчания не будет.

Правило скорости через `label_replace` разделяет download и upload на отдельные
экземпляры — в уведомлении видно, какое направление просело.

Правила из provisioning-файлов **только для чтения** в интерфейсе.

### 8.4. Проверка

**Alerting → Contact points → telegram → Test.**

Боевая проверка: добавить в `icmp` заведомо мёртвый адрес `192.0.2.1`
(RFC 5737, зарезервирован для примеров), `curl -X POST .../-/reload`,
через 2 минуты придёт алерт. Убрать обратно — придёт resolved.

---

## 9. Известные проблемы

### Cloudflare Tunnel не передаёт данные

**Симптомы:** на QUIC — `timeout: no recent network activity` через несколько секунд;
на HTTP/2 — `connection with edge closed` через несколько минут; туннель в дашборде
мигает Healthy → Degraded → Down; снаружи `502` с телом `error code: 1033`.
В логах коннектора при этом нет ни одной записи о входящем запросе.

Общий признак: соединение с edge устанавливается, но данные по нему не идут.

**Решение:** `--protocol http2` в команде запуска — QUIC поверх UDP 7844 работает
не на всех маршрутах. Если разрывы остаются и на HTTP/2, проблема в сетевом пути
до подсетей edge `198.41.192.0/24` и `198.41.200.0/24`.

**Диагностика.** Запрос снаружи и логи коннектора одновременно:

```bash
curl -sI https://monitor.example.com/login >/dev/null
docker compose logs --since 2m cloudflared | grep -iE 'err|origin|dial|lost'
```

Ошибка `dial tcp` указывает на проблему с origin; полное молчание означает,
что запрос до коннектора не дошёл.

### `ERR_CONNECTION_CLOSED` при работающем curl

Домен резолвится в том числе в AAAA, браузер по Happy Eyeballs предпочитает IPv6,
а он в сети нерабочий. Проверка: `curl.exe -6 ...` не отвечает, без `-6` — 200.

**Решение:** отключить IPv6 на клиенте. На бесплатном плане Cloudflare тумблер
IPv6 Compatibility заблокирован, AAAA-записи убрать нельзя.

### mktxp: `PermissionError`

Конфиг с правами `600` и владельцем root недоступен пользователю внутри контейнера.
См. `chown` в [разделе 4](#mktxpmktxpconf).

### Grafana: `Datasource provisioning error: data source not found`

Датасорс уже существует в базе без `uid`. См. блок `deleteDatasources`
в [разделе 5](#grafanaprovisioningdatasourcesprometheusyml).

### Светлая тема не применяется

`GF_USERS_DEFAULT_THEME` действует только на пользователей без собственной настройки.
Дополнительно: **Administration → Default preferences → UI Theme → Light** и
**Профиль → Preferences → UI Theme → Light**. Личная настройка перекрывает всё.

---

## 10. Проверки

```bash
# все таргеты
curl -s 'http://172.16.0.6:9090/api/v1/targets?state=active' \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['labels']['instance'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"

# ICMP и TCP напрямую через blackbox
curl -s 'http://172.16.0.6:9115/probe?target=1.1.1.1&module=icmp' | grep '^probe_success'
curl -s 'http://172.16.0.6:9115/probe?target=VPS_IP:9003&module=tcp_connect' \
  | grep -E '^probe_success|^probe_duration_seconds'

# результаты iperf3 в Pushgateway
curl -s http://172.16.0.6:9091/metrics | grep '^iperf3_'

# метрики Mikrotik
curl -s http://172.16.0.6:49090/metrics | grep -c '^mktxp_'

# внешний доступ
curl -sI https://monitor.example.com/login | head -3

# туннель без разрывов
docker compose logs --since 10m cloudflared | grep -c 'Lost connection'

# синтаксис конфига Prometheus
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

`probe_duration_seconds` ровно 5 секунд у TCP-пробы означает, что пакеты отбрасываются
файрволом. Закрытый порт без файрвола отвечает `connection refused` мгновенно.

---

## 11. Обслуживание

### Обновление образов

```bash
docker compose pull
docker compose up -d
```

Перед сменой мажорной версии Grafana — бэкап, миграция базы необратима:

```bash
docker compose stop grafana
docker run --rm -v monitoring_grafana-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/grafana-data-$(date +%F).tar.gz -C /data .
```

Имя тома уточнить через `docker volume ls | grep grafana`.

### Перезагрузка конфигов без рестарта

```bash
curl -X POST http://172.16.0.6:9090/-/reload   # Prometheus
```

Дашборды и алерты Grafana подхватывает сама в течение 30 секунд.

### Что не покрыто

- **Коннектор и стек на одном хосте.** Вынос `cloudflared` на VPS сделал бы внешний
  доступ независимым от доступности локального сегмента.
- **Grafana и cloudflared не мониторятся.** Grafana не может уведомить о собственном
  падении, а `cloudflared` не отдаёт метрик в стек. Внешняя проверка доступности
  `monitor.example.com` закрыла бы этот пробел.
- **Нет бэкапа метрик.** Том `prometheus-data` хранит 90 дней и никуда не копируется.
