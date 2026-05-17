#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Nexus IoT Portao - Instalador / Removedor
# Autor: Nexus NVR / Ariel
# Sistema alvo: Ubuntu 22.04+ na VPS Oracle
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
  docker run -d \
    --name "$MOSQ_CONTAINER" \
    --restart always \
    -p "${mqtt_port}:${mqtt_port}" \
    -v "$MOSQ_CONF:/mosquitto/config/mosquitto.conf" \
    -v "$MOSQ_DIR/data:/mosquitto/data" \
    -v "$MOSQ_DIR/log:/mosquitto/log" \
    eclipse-mosquitto:latest >/dev/null

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
  [ -d "$APP_DIR" ] && found=1
  [ -d "$MOSQ_DIR" ] && found=1
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MOSQ_CONTAINER" && found=1
  if command -v pm2 >/dev/null 2>&1; then
    pm2 list 2>/dev/null | grep -q "$APP_NAME" && found=1 || true
  fi
  return $((1 - found))
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
  API_PORT="$(ask 'Porta da API para remover regra local' "$DEFAULT_API_PORT")"
  MQTT_PORT="$(ask 'Porta MQTT para remover regra local' "$DEFAULT_MQTT_PORT")"

  if ! confirm_strong "Isto vai parar/remover api-portao, container mosquitto, $APP_DIR e $MOSQ_DIR."; then
    warn "Exclusao cancelada."
    exit 0
  fi

  log "Parando API PM2"
  if id "$APP_USER" >/dev/null 2>&1 && command -v pm2 >/dev/null 2>&1; then
    run_as_user "$APP_USER" "pm2 delete '$APP_NAME' >/dev/null 2>&1 || true"
    run_as_user "$APP_USER" "pm2 save >/dev/null 2>&1 || true"
  fi

  log "Removendo container Mosquitto"
  docker rm -f "$MOSQ_CONTAINER" >/dev/null 2>&1 || true

  log "Removendo arquivos do sistema IoT"
  rm -rf "$APP_DIR" "$MOSQ_DIR"

  log "Removendo regras locais de firewall das portas informadas"
  remove_firewall_rule "$API_PORT"
  remove_firewall_rule "$MQTT_PORT"
  save_firewall_rules

  ok "Sistema IoT Portao removido."
  warn "Docker, Node.js e PM2 globais foram mantidos para nao quebrar outros sistemas da VPS."
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
