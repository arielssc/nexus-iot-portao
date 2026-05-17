#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Nexus IoT Portao - Instalador / Removedor
# Autor: Nexus NVR / Ariel
# Sistema alvo: Ubuntu 22.04+ na VPS Oracle
# Versao: 1.2 - conflito de portas e exclusao inteligente
# ============================================================

APP_NAME="api-portao"
APP_DIR="/opt/nexus-iot-portao"
APP_FILE="$APP_DIR/api_portao.js"
MOSQ_DIR="/opt/mosquitto"
MOSQ_CONF="$MOSQ_DIR/config/mosquitto.conf"
MOSQ_CONTAINER="mosquitto"

DEFAULT_API_PORT="3000"
DEFAULT_MQTT_PORT="48912"
DEFAULT_TOPIC_CMD="casa/portao/comando"
DEFAULT_TOPIC_STATUS="casa/portao/status"
DEFAULT_TOPIC_CONEXAO="casa/portao/conexao"
DEFAULT_TOPIC_TRAVA="casa/portao/trava"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
reset='\033[0m'

log() { echo -e "${blue}==>${reset} $*"; }
ok() { echo -e "${green}OK:${reset} $*"; }
warn() { echo -e "${yellow}AVISO:${reset} $*"; }
err() { echo -e "${red}ERRO:${reset} $*"; }

need_root() {
  if [ "${EUID}" -ne 0 ]; then
    err "Execute com sudo: sudo bash nexus-iot-portao.sh"
    exit 1
  fi
}

get_default_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    echo "$SUDO_USER"
  elif id ubuntu >/dev/null 2>&1; then
    echo "ubuntu"
  else
    logname 2>/dev/null || echo "root"
  fi
}

ask() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value || true
  echo "${value:-$default}"
}

confirm_strong() {
  local msg="$1"
  echo
  warn "$msg"
  read -r -p "Digite SIM para confirmar: " resp || true
  [ "$resp" = "SIM" ]
}

yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local resp
  local hint="[s/N]"
  if [ "$default" = "S" ]; then
    hint="[S/n]"
  fi

  while true; do
    read -r -p "$prompt $hint: " resp || true
    resp="${resp:-$default}"
    case "$resp" in
      s|S|sim|SIM|Sim) return 0 ;;
      n|N|nao|NAO|não|NÃO|Nao|Não) return 1 ;;
      *) echo "Responda s ou n." ;;
    esac
  done
}

detect_api_port() {
  if [ -f "$APP_FILE" ]; then
    grep -oE "API_PORT \|\| '?[0-9]+'?" "$APP_FILE" | grep -oE "[0-9]+" | head -1 && return 0
  fi
  echo "$DEFAULT_API_PORT"
}

detect_mqtt_port() {
  if [ -f "$MOSQ_CONF" ]; then
    awk '/^[[:space:]]*listener[[:space:]]+[0-9]+/ {print $2; exit}' "$MOSQ_CONF" && return 0
  fi
  if [ -f "$APP_FILE" ]; then
    grep -oE "MQTT_PORT \|\| '?[0-9]+'?" "$APP_FILE" | grep -oE "[0-9]+" | head -1 && return 0
  fi
  echo "$DEFAULT_MQTT_PORT"
}

pm2_app_exists_for_user() {
  local user="$1"
  id "$user" >/dev/null 2>&1 || return 1
  run_as_user "$user" "pm2 list 2>/dev/null | grep -q '$APP_NAME'" >/dev/null 2>&1
}

public_ip() {
  curl -4 -s --max-time 4 ifconfig.me 2>/dev/null || \
  curl -4 -s --max-time 4 https://api.ipify.org 2>/dev/null || \
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

run_as_user() {
  local user="$1"
  shift
  if [ "$user" = "root" ]; then
    bash -lc "$*"
  else
    su - "$user" -c "$*"
  fi
}

install_dependencies() {
  log "Instalando dependencias base"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates gnupg lsb-release iptables-persistent

  if ! command -v docker >/dev/null 2>&1; then
    log "Instalando Docker pelo repositório do Ubuntu"
    apt-get install -y docker.io
  fi
  systemctl enable --now docker

  local node_major="0"
  if command -v node >/dev/null 2>&1; then
    node_major="$(node -v | sed 's/^v//' | cut -d. -f1)"
  fi

  if [ "${node_major:-0}" -lt 18 ]; then
    log "Instalando Node.js 20"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  else
    ok "Node.js já instalado: $(node -v)"
  fi

  if ! command -v pm2 >/dev/null 2>&1; then
    log "Instalando PM2"
    npm install -g pm2
  else
    ok "PM2 já instalado: $(pm2 -v)"
  fi
}

add_firewall_rule() {
  local port="$1"
  if iptables -C INPUT -p tcp -m tcp --dport "$port" -j ACCEPT 2>/dev/null; then
    ok "Firewall local já libera TCP $port"
  else
    log "Liberando TCP $port no firewall local iptables"
    iptables -I INPUT 1 -p tcp -m tcp --dport "$port" -j ACCEPT
  fi
}

remove_firewall_rule() {
  local port="$1"
  local removed=0
  while iptables -C INPUT -p tcp -m tcp --dport "$port" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp -m tcp --dport "$port" -j ACCEPT || break
    removed=1
  done
  if [ "$removed" = "1" ]; then
    ok "Regra TCP $port removida do iptables"
  fi
}

save_firewall_rules() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4 || true
  fi
}

port_is_listening() {
  local port="$1"
  ss -ltnp 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

show_port_users() {
  local port="$1"
  echo
  warn "A porta TCP $port ja esta em uso."
  echo "Processos usando a porta:"
  ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true

  echo
  echo "Containers Docker relacionados:"
  docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}" 2>/dev/null | grep -E "(:${port}->|0\.0\.0\.0:${port}|:::${port}|${port}/tcp|NAMES)" || true

  echo
  echo "Processos provaveis:"
  ps -eo pid,user,cmd 2>/dev/null | grep -Ei "mosquitto|docker-proxy|node|pm2|:${port}|${port}" | grep -v grep || true
}

try_stop_port_users() {
  local port="$1"

  log "Tentando liberar automaticamente a porta TCP $port"

  # Para containers que publicam a porta.
  local containers
  containers="$(docker ps -a --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk -v p=":$port" 'index($0,p){print $1}' || true)"
  if [ -n "$containers" ]; then
    echo "$containers" | while read -r c; do
      [ -n "$c" ] || continue
      warn "Removendo container que usa a porta $port: $c"
      docker rm -f "$c" >/dev/null 2>&1 || true
    done
  fi

  # Se a porta for da API padrao, tenta remover o processo PM2 conhecido.
  if [ "$port" = "${API_PORT:-}" ] || [ "$port" = "$DEFAULT_API_PORT" ]; then
    local app_user_tmp="${APP_USER:-$(get_default_user)}"
    if id "$app_user_tmp" >/dev/null 2>&1 && command -v pm2 >/dev/null 2>&1; then
      warn "Tentando remover PM2 $APP_NAME do usuario $app_user_tmp"
      run_as_user "$app_user_tmp" "pm2 delete '$APP_NAME' >/dev/null 2>&1 || true"
      run_as_user "$app_user_tmp" "pm2 save >/dev/null 2>&1 || true"
    fi
  fi

  sleep 2

  if port_is_listening "$port"; then
    warn "A porta $port ainda continua ocupada."
    show_port_users "$port"
    return 1
  fi

  ok "Porta $port liberada."
  return 0
}

resolve_port_conflict() {
  local var_name="$1"
  local current_port="$2"
  local label="$3"

  while port_is_listening "$current_port"; do
    show_port_users "$current_port"
    echo
    echo "O que deseja fazer com a porta $current_port usada por $label?"
    echo "1) Tentar encerrar/remover automaticamente quem esta usando a porta"
    echo "2) Escolher outra porta"
    echo "3) Cancelar instalacao"
    read -r -p "Escolha uma opcao [1/2/3]: " escolha || true

    case "${escolha:-}" in
      1)
        if try_stop_port_users "$current_port"; then
          break
        fi
        ;;
      2)
        read -r -p "Digite a nova porta para $label: " nova_porta || true
        if ! echo "$nova_porta" | grep -Eq '^[0-9]+$'; then
          warn "Porta invalida."
          continue
        fi
        if [ "$nova_porta" -lt 1 ] || [ "$nova_porta" -gt 65535 ]; then
          warn "Porta fora do intervalo 1-65535."
          continue
        fi
        current_port="$nova_porta"
        ;;
      3)
        err "Instalacao cancelada pelo usuario."
        exit 1
        ;;
      *)
        warn "Opcao invalida."
        ;;
    esac
  done

  printf -v "$var_name" '%s' "$current_port"
  ok "$label definido na porta $current_port"
}

create_mosquitto() {
  local mqtt_port="$1"

  log "Criando estrutura do Mosquitto em $MOSQ_DIR"
  mkdir -p "$MOSQ_DIR/config" "$MOSQ_DIR/data" "$MOSQ_DIR/log"
  chown -R 1883:1883 "$MOSQ_DIR/data" "$MOSQ_DIR/log" || true

  cat > "$MOSQ_CONF" <<EOF
# Configuracao base Nexus IoT Portao
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log

# Porta MQTT usada pelo ESP e pela API local
listener ${mqtt_port}
allow_anonymous true
EOF

  log "Removendo container Mosquitto anterior se existir"
  docker rm -f "$MOSQ_CONTAINER" >/dev/null 2>&1 || true

  log "Subindo Mosquitto na porta MQTT $mqtt_port"
  if ! docker run -d \
    --name "$MOSQ_CONTAINER" \
    --restart always \
    -p "${mqtt_port}:${mqtt_port}" \
    -v "$MOSQ_CONF:/mosquitto/config/mosquitto.conf" \
    -v "$MOSQ_DIR/data:/mosquitto/data" \
    -v "$MOSQ_DIR/log:/mosquitto/log" \
    eclipse-mosquitto:latest >/dev/null; then
      err "Falha ao subir o Mosquitto. Verifique se a porta $mqtt_port ficou ocupada por outro processo."
      show_port_users "$mqtt_port"
      exit 1
  fi

  sleep 2
  docker ps --filter "name=$MOSQ_CONTAINER" --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"
}

create_node_app() {
  local app_user="$1"
  local api_port="$2"
  local mqtt_port="$3"
  local topic_cmd="$4"
  local topic_status="$5"
  local topic_conexao="$6"
  local topic_trava="$7"

  log "Criando API Node em $APP_DIR"
  mkdir -p "$APP_DIR"

  cat > "$APP_DIR/package.json" <<'JSON'
{
  "name": "nexus-iot-portao",
  "version": "1.0.0",
  "private": true,
  "main": "api_portao.js",
  "dependencies": {
    "mqtt": "^5.15.1",
    "socket.io": "^4.8.3"
  }
}
JSON

  cat > "$APP_FILE" <<'NODE'
const http = require('http');
const mqtt = require('mqtt');
const { Server } = require('socket.io');

// ================== CONFIGURACAO ==================
const API_PORT = Number(process.env.API_PORT || '__API_PORT__');
const MQTT_PORT = Number(process.env.MQTT_PORT || '__MQTT_PORT__');
const MQTT_BROKER = `mqtt://127.0.0.1:${MQTT_PORT}`;

const TOPIC_CMD = '__TOPIC_CMD__';
const TOPIC_STATUS = '__TOPIC_STATUS__';
const TOPIC_CONEXAO = '__TOPIC_CONEXAO__';
const TOPIC_TRAVA = '__TOPIC_TRAVA__';

// ================== ESTADOS ==================
let estadoPortao = 'fechado';
let estadoConexao = 'Off';
let estadoTrava = 'Off';

// ================== MQTT ==================
const mqttClient = mqtt.connect(MQTT_BROKER, {
    reconnectPeriod: 1000,
    connectTimeout: 5000,
    clean: true
});

mqttClient.on('connect', () => {
    console.log('API conectada ao broker MQTT em ' + MQTT_BROKER);
    mqttClient.subscribe(TOPIC_STATUS);
    mqttClient.subscribe(TOPIC_CONEXAO);
    mqttClient.subscribe(TOPIC_TRAVA);
});

mqttClient.on('error', (err) => {
    console.error('Erro MQTT:', err.message);
});

mqttClient.on('message', (topic, message) => {
    const msg = message.toString().trim();
    console.log('MQTT -> Topico: ' + topic + ' | Mensagem: ' + msg);

    if (topic === TOPIC_STATUS || topic.includes('status')) {
        estadoPortao = msg;
    } else if (topic === TOPIC_CONEXAO || topic.includes('conexao')) {
        estadoConexao = msg;
    } else if (topic === TOPIC_TRAVA || topic.includes('trava')) {
        estadoTrava = msg;
    }

    emitirEstado();
});

function enviarJson(res, statusCode, obj) {
    res.writeHead(statusCode, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(obj));
}

function emitirEstado() {
    io.emit('atualizacao_portao', {
        status: estadoPortao,
        conexao: estadoConexao,
        trava: estadoTrava
    });
}

// ================== HTTP ==================
const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept, Authorization, X-Auth');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        return res.end();
    }

    if (req.method === 'GET' && (req.url === '/' || req.url === '/health')) {
        return enviarJson(res, 200, {
            ok: true,
            service: 'nexus-iot-portao',
            apiPort: API_PORT,
            mqttBroker: MQTT_BROKER,
            topics: {
                comando: TOPIC_CMD,
                status: TOPIC_STATUS,
                conexao: TOPIC_CONEXAO,
                trava: TOPIC_TRAVA
            }
        });
    }

    if (req.method === 'GET' && req.url === '/maestro/portao/status') {
        return enviarJson(res, 200, {
            status: estadoPortao,
            conexao: estadoConexao,
            trava: estadoTrava
        });
    }

    if (req.method === 'POST' && req.url === '/maestro/portao') {
        mqttClient.publish(TOPIC_CMD, 'PULSO');
        return enviarJson(res, 200, { msg: 'Pulso enviado!' });
    }

    if (req.method === 'POST' && req.url === '/maestro/portao/travar') {
        mqttClient.publish(TOPIC_CMD, 'TRAVAR', { retain: true });
        return enviarJson(res, 200, { msg: 'Trava acionada!' });
    }

    if (req.method === 'POST' && req.url === '/maestro/portao/destravar') {
        mqttClient.publish(TOPIC_CMD, 'DESTRAVAR', { retain: true });
        return enviarJson(res, 200, { msg: 'Trava liberada!' });
    }

    return enviarJson(res, 404, { error: 'rota nao encontrada' });
});

// ================== SOCKET.IO ==================
const io = new Server(server, {
    cors: { origin: '*', methods: ['GET', 'POST'] }
});

io.on('connection', (socket) => {
    console.log('Cliente conectado no Socket.IO: ' + socket.id);
    socket.emit('atualizacao_portao', {
        status: estadoPortao,
        conexao: estadoConexao,
        trava: estadoTrava
    });
});

server.listen(API_PORT, '0.0.0.0', () => {
    console.log('Nexus IoT Portao online na porta ' + API_PORT);
});
NODE

  sed -i \
    -e "s|__API_PORT__|$api_port|g" \
    -e "s|__MQTT_PORT__|$mqtt_port|g" \
    -e "s|__TOPIC_CMD__|$topic_cmd|g" \
    -e "s|__TOPIC_STATUS__|$topic_status|g" \
    -e "s|__TOPIC_CONEXAO__|$topic_conexao|g" \
    -e "s|__TOPIC_TRAVA__|$topic_trava|g" \
    "$APP_FILE"

  chown -R "$app_user:$app_user" "$APP_DIR"

  log "Instalando dependencias Node"
  run_as_user "$app_user" "cd '$APP_DIR' && npm install --omit=dev"
}

setup_pm2() {
  local app_user="$1"

  log "Configurando PM2 para $APP_NAME"
  run_as_user "$app_user" "pm2 delete '$APP_NAME' >/dev/null 2>&1 || true"
  run_as_user "$app_user" "cd '$APP_DIR' && pm2 start '$APP_FILE' --name '$APP_NAME'"
  run_as_user "$app_user" "pm2 save"

  log "Configurando PM2 para iniciar no boot"
  env PATH="$PATH:/usr/bin" pm2 startup systemd -u "$app_user" --hp "/home/$app_user" >/tmp/nexus_pm2_startup.log 2>&1 || true
  systemctl enable "pm2-$app_user" >/dev/null 2>&1 || true
  systemctl restart "pm2-$app_user" >/dev/null 2>&1 || true
}

show_summary() {
  local api_port="$1"
  local mqtt_port="$2"
  local topic_cmd="$3"
  local topic_status="$4"
  local topic_conexao="$5"
  local topic_trava="$6"
  local ip
  ip="$(public_ip)"

  echo
  echo "============================================================"
  echo " NEXUS IOT PORTAO - INSTALACAO CONCLUIDA"
  echo "============================================================"
  echo
  echo "Configurar no APK / Aba Conexao / Portao:"
  echo "  Protocolo do portao: http"
  echo "  Modo do portao: VPS ou Automatico"
  echo "  VPS Host: ${ip:-IP_PUBLICO_DA_VPS}"
  echo "  Porta VPS/API: $api_port"
  echo "  ESP local: 192.168.4.1"
  echo "  Porta local ESP: vazio"
  echo
  echo "Configurar no ESP:"
  echo "  Broker MQTT: ${ip:-IP_PUBLICO_DA_VPS}"
  echo "  Porta MQTT: $mqtt_port"
  echo "  Topico comando: $topic_cmd"
  echo "  Topico status: $topic_status"
  echo "  Topico conexao: $topic_conexao"
  echo "  Topico trava: $topic_trava"
  echo
  echo "Rotas HTTP da API:"
  echo "  GET  http://${ip:-IP_PUBLICO_DA_VPS}:$api_port/maestro/portao/status"
  echo "  POST http://${ip:-IP_PUBLICO_DA_VPS}:$api_port/maestro/portao"
  echo "  POST http://${ip:-IP_PUBLICO_DA_VPS}:$api_port/maestro/portao/travar"
  echo "  POST http://${ip:-IP_PUBLICO_DA_VPS}:$api_port/maestro/portao/destravar"
  echo "  Socket.IO: http://${ip:-IP_PUBLICO_DA_VPS}:$api_port/socket.io/"
  echo
  echo "Testes rapidos:"
  echo "  curl http://127.0.0.1:$api_port/maestro/portao/status"
  echo "  pm2 logs $APP_NAME --lines 50"
  echo "  docker logs --tail 50 $MOSQ_CONTAINER"
  echo
  echo "IMPORTANTE: na Oracle Cloud, libere tambem as portas $api_port e $mqtt_port na Security List/NSG."
  echo "============================================================"
}

install_system() {
  need_root

  echo
  echo "================ INSTALAR SISTEMA IOT PORTAO ================"
  local default_user
  default_user="$(get_default_user)"

  APP_USER="$(ask 'Usuario Linux que vai rodar a API via PM2' "$default_user")"
  API_PORT="$(ask 'Porta da API para o app/celular' "$DEFAULT_API_PORT")"
  MQTT_PORT="$(ask 'Porta MQTT para o ESP' "$DEFAULT_MQTT_PORT")"
  TOPIC_CMD="$(ask 'Topico MQTT de comando' "$DEFAULT_TOPIC_CMD")"
  TOPIC_STATUS="$(ask 'Topico MQTT de status do portao' "$DEFAULT_TOPIC_STATUS")"
  TOPIC_CONEXAO="$(ask 'Topico MQTT de conexao do ESP' "$DEFAULT_TOPIC_CONEXAO")"
  TOPIC_TRAVA="$(ask 'Topico MQTT de trava' "$DEFAULT_TOPIC_TRAVA")"

  if ! id "$APP_USER" >/dev/null 2>&1; then
    err "Usuario $APP_USER nao existe. Crie o usuario ou escolha outro."
    exit 1
  fi

  echo
  echo "Resumo que sera instalado:"
  echo "  Usuario PM2: $APP_USER"
  echo "  API: porta $API_PORT"
  echo "  MQTT: porta $MQTT_PORT"
  echo "  App dir: $APP_DIR"
  echo "  Mosquitto dir: $MOSQ_DIR"
  echo
  if ! confirm_strong "A instalacao pode substituir container Mosquitto e PM2 api-portao existentes."; then
    warn "Instalacao cancelada."
    exit 0
  fi

  install_dependencies

  # Verifica portas antes de subir os servicos.
  # Se alguma estiver ocupada, mostra quem usa e deixa o usuario decidir.
  resolve_port_conflict API_PORT "$API_PORT" "API do app/celular"
  resolve_port_conflict MQTT_PORT "$MQTT_PORT" "MQTT do ESP"

  create_mosquitto "$MQTT_PORT"
  create_node_app "$APP_USER" "$API_PORT" "$MQTT_PORT" "$TOPIC_CMD" "$TOPIC_STATUS" "$TOPIC_CONEXAO" "$TOPIC_TRAVA"
  setup_pm2 "$APP_USER"
  add_firewall_rule "$API_PORT"
  add_firewall_rule "$MQTT_PORT"
  save_firewall_rules

  log "Aguardando servicos subirem"
  sleep 4

  echo
  echo "===== TESTE API ====="
  curl -s -i "http://127.0.0.1:$API_PORT/maestro/portao/status" || true
  echo
  echo
  echo "===== TESTE SOCKET.IO ====="
  curl -s -i "http://127.0.0.1:$API_PORT/socket.io/?EIO=4&transport=polling" | head -20 || true
  echo
  echo
  echo "===== STATUS PM2 ====="
  run_as_user "$APP_USER" "pm2 list" || true
  echo
  echo "===== STATUS MOSQUITTO ====="
  docker ps --filter "name=$MOSQ_CONTAINER" --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}" || true

  show_summary "$API_PORT" "$MQTT_PORT" "$TOPIC_CMD" "$TOPIC_STATUS" "$TOPIC_CONEXAO" "$TOPIC_TRAVA"
}

is_installed() {
  local found=0
  local default_user
  default_user="$(get_default_user)"

  [ -d "$APP_DIR" ] && found=1
  [ -d "$MOSQ_DIR" ] && found=1
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MOSQ_CONTAINER" && found=1

  if command -v pm2 >/dev/null 2>&1; then
    pm2_app_exists_for_user "$default_user" && found=1
    [ "$default_user" != "ubuntu" ] && pm2_app_exists_for_user "ubuntu" && found=1
  fi

  return $((1 - found))
}

show_found_components() {
  local app_user="$1"
  local api_port="$2"
  local mqtt_port="$3"

  echo
  echo "===== ITENS ENCONTRADOS ====="

  if pm2_app_exists_for_user "$app_user"; then
    echo "PM2 API: encontrado ($APP_NAME no usuario $app_user)"
  else
    echo "PM2 API: nao encontrado no usuario $app_user"
  fi

  if [ -d "$APP_DIR" ]; then
    echo "Arquivos API: encontrado ($APP_DIR)"
  else
    echo "Arquivos API: nao encontrado ($APP_DIR)"
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MOSQ_CONTAINER"; then
    echo "Container Mosquitto: encontrado ($MOSQ_CONTAINER)"
  else
    echo "Container Mosquitto: nao encontrado"
  fi

  if [ -d "$MOSQ_DIR" ]; then
    echo "Dados Mosquitto: encontrado ($MOSQ_DIR)"
  else
    echo "Dados Mosquitto: nao encontrado ($MOSQ_DIR)"
  fi

  if iptables -C INPUT -p tcp -m tcp --dport "$api_port" -j ACCEPT 2>/dev/null; then
    echo "Firewall API: regra encontrada TCP $api_port"
  else
    echo "Firewall API: regra nao encontrada TCP $api_port"
  fi

  if iptables -C INPUT -p tcp -m tcp --dport "$mqtt_port" -j ACCEPT 2>/dev/null; then
    echo "Firewall MQTT: regra encontrada TCP $mqtt_port"
  else
    echo "Firewall MQTT: regra nao encontrada TCP $mqtt_port"
  fi

  echo
  echo "Dependencias globais instaladas:"
  command -v docker >/dev/null 2>&1 && echo "Docker: $(docker -v 2>/dev/null)" || echo "Docker: nao encontrado"
  command -v node >/dev/null 2>&1 && echo "Node.js: $(node -v 2>/dev/null)" || echo "Node.js: nao encontrado"
  command -v npm >/dev/null 2>&1 && echo "npm: $(npm -v 2>/dev/null)" || echo "npm: nao encontrado"
  command -v pm2 >/dev/null 2>&1 && echo "PM2: $(pm2 -v 2>/dev/null)" || echo "PM2: nao encontrado"
}

remove_pm2_app() {
  local app_user="$1"
  if id "$app_user" >/dev/null 2>&1 && command -v pm2 >/dev/null 2>&1; then
    log "Removendo PM2 $APP_NAME do usuario $app_user"
    run_as_user "$app_user" "pm2 delete '$APP_NAME' >/dev/null 2>&1 || true"
    run_as_user "$app_user" "pm2 save >/dev/null 2>&1 || true"
    ok "PM2 $APP_NAME removido se existia."
  fi
}

remove_app_files() {
  if [ -d "$APP_DIR" ]; then
    log "Removendo arquivos da API em $APP_DIR"
    rm -rf "$APP_DIR"
    ok "Arquivos da API removidos."
  else
    warn "Pasta $APP_DIR nao existe."
  fi
}

remove_mosquitto_container() {
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MOSQ_CONTAINER"; then
    log "Removendo container $MOSQ_CONTAINER"
    docker rm -f "$MOSQ_CONTAINER" >/dev/null 2>&1 || true
    ok "Container Mosquitto removido."
  else
    warn "Container $MOSQ_CONTAINER nao existe."
  fi
}

remove_mosquitto_files() {
  if [ -d "$MOSQ_DIR" ]; then
    log "Removendo dados/config/logs do Mosquitto em $MOSQ_DIR"
    rm -rf "$MOSQ_DIR"
    ok "Pasta Mosquitto removida."
  else
    warn "Pasta $MOSQ_DIR nao existe."
  fi
}

remove_global_dependencies() {
  echo
  warn "Remover dependencias globais pode quebrar outros projetos desta VPS."
  warn "Isso inclui Docker, Node.js, npm e PM2 instalados no sistema."

  if yes_no "Deseja remover PM2 global?" "N"; then
    npm uninstall -g pm2 || true
    ok "PM2 global removido se existia."
  fi

  if yes_no "Deseja remover Node.js/npm do sistema?" "N"; then
    apt-get purge -y nodejs npm || true
    apt-get autoremove -y || true
    ok "Node.js/npm removidos se existiam."
  fi

  if yes_no "Deseja remover Docker do sistema?" "N"; then
    systemctl stop docker >/dev/null 2>&1 || true
    apt-get purge -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true
    apt-get autoremove -y || true
    ok "Docker removido se existia."
  fi
}

uninstall_system() {
  need_root

  echo
  echo "================ EXCLUIR SISTEMA IOT PORTAO ================"

  if ! is_installed; then
    ok "Nao encontrei sistema IoT Portao instalado por este script. Nada para remover."
    exit 0
  fi

  local default_user
  default_user="$(get_default_user)"
  APP_USER="$(ask 'Usuario Linux usado pelo PM2 da API' "$default_user")"

  local detected_api
  local detected_mqtt
  detected_api="$(detect_api_port)"
  detected_mqtt="$(detect_mqtt_port)"

  API_PORT="$(ask 'Porta da API para verificar/remover regra local' "$detected_api")"
  MQTT_PORT="$(ask 'Porta MQTT para verificar/remover regra local' "$detected_mqtt")"

  show_found_components "$APP_USER" "$API_PORT" "$MQTT_PORT"

  echo "O que deseja excluir?"
  echo "1) Excluir sistema IoT completo padrao"
  echo "   - PM2 $APP_NAME"
  echo "   - arquivos $APP_DIR"
  echo "   - container $MOSQ_CONTAINER"
  echo "   - dados/config $MOSQ_DIR"
  echo "   - regras locais das portas $API_PORT e $MQTT_PORT"
  echo "   - NAO remove Docker/Node/PM2 globais automaticamente"
  echo "2) Escolher item por item"
  echo "3) Cancelar"
  read -r -p "Escolha uma opcao [1/2/3]: " modo || true

  case "${modo:-}" in
    1)
      if ! confirm_strong "Confirma excluir o sistema IoT padrao?"; then
        warn "Exclusao cancelada."
        exit 0
      fi

      remove_pm2_app "$APP_USER"
      remove_mosquitto_container
      remove_app_files
      remove_mosquitto_files
      remove_firewall_rule "$API_PORT"
      remove_firewall_rule "$MQTT_PORT"
      save_firewall_rules

      echo
      if yes_no "Deseja tambem avaliar/remover dependencias globais Docker/Node/PM2?" "N"; then
        remove_global_dependencies
      else
        warn "Docker, Node.js e PM2 globais foram mantidos por escolha do usuario."
      fi
      ;;

    2)
      if yes_no "Remover processo PM2 $APP_NAME?" "S"; then
        remove_pm2_app "$APP_USER"
      fi

      if yes_no "Remover arquivos da API em $APP_DIR?" "S"; then
        remove_app_files
      fi

      if yes_no "Remover container Mosquitto $MOSQ_CONTAINER?" "S"; then
        remove_mosquitto_container
      fi

      if yes_no "Remover dados/config/logs Mosquitto em $MOSQ_DIR?" "S"; then
        remove_mosquitto_files
      fi

      if yes_no "Remover regra local firewall da API TCP $API_PORT?" "S"; then
        remove_firewall_rule "$API_PORT"
      fi

      if yes_no "Remover regra local firewall MQTT TCP $MQTT_PORT?" "S"; then
        remove_firewall_rule "$MQTT_PORT"
      fi

      save_firewall_rules

      if yes_no "Deseja avaliar/remover dependencias globais Docker/Node/PM2?" "N"; then
        remove_global_dependencies
      fi
      ;;

    3)
      warn "Exclusao cancelada."
      exit 0
      ;;

    *)
      err "Opcao invalida."
      exit 1
      ;;
  esac

  echo
  ok "Rotina de exclusao finalizada."
}

main_menu() {
  clear || true
  echo "============================================================"
  echo " NEXUS IOT PORTAO - INSTALADOR"
  echo "============================================================"
  echo "1) Instalar sistema IoT"
  echo "2) Excluir sistema IoT"
  echo "3) Sair"
  echo "============================================================"
  read -r -p "Escolha uma opcao: " opt || true

  case "${opt:-}" in
    1) install_system ;;
    2) uninstall_system ;;
    3) exit 0 ;;
    *) err "Opcao invalida"; exit 1 ;;
  esac
}

main_menu
