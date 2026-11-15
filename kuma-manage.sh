#!/usr/bin/env bash
# ============================================================
# kuma-manage.sh — gestion de monitores y notificacion de Kuma
# ============================================================
# Reemplaza a los 7 scripts de andamiaje (.setup*.js, .link.js,
# .fix-targets.js, .firetest.js) que se usaron durante el setup.
#
# Que hace:
#   list      — lista monitores y su ultimo heartbeat
#   add       — crea un monitor nuevo (interactivo por args)
#   link      — (re)asocia TODOS los monitores a la notificacion
#   unlink    — desasocia TODOS los monitores de la notificacion
#   edit      — cambia nombre/target/tipo de un monitor existente
#   test      — envia una notificacion de prueba a Telegram
#   cleanup   — borra los scripts de andamiaje viejos
#
# Donde esta todo (todo relativo a este script):
#   compose       ./docker-compose.yml
#   DB            ./data/kuma.db   (SQLite)
#   credenciales  ./.admin-credentials  (600)
#   token TG      ./.telegram-token     (600)
#
# COMO SE USA (desde el directorio donde vive el stack):
#   bash kuma-manage.sh list
#   bash kuma-manage.sh test
#   bash kuma-manage.sh link
#   bash kuma-manage.sh unlink
#   bash kuma-manage.sh edit <id> <nombre> <url> [codigos] [tipo]
#       codigos: "200-299" (default si se omite), "200-299,401-499", etc.
#   bash kuma-manage.sh add <nombre> <http|port> <url> [puerto]
#
#
# MODO "SENSOR PURO": la notificacion de Telegram esta DESASOCIADA de
# los monitores (unlink). Kuma solo sondea y decide; el aviso lo manda
# otro componente. Asi hay un solo camino de alerta y un solo token.
# Para volver al modo "Kuma avisa solo": bash kuma-manage.sh link
# NOTA sobre la API de Kuma: no es REST, es Socket.IO. Este script
# la usa via socket.io-client (incluido en la imagen). Los quirks que
# costaron sangre estan documentados en el JS embebido.
# ============================================================

set -eu

# El directorio del stack se deriva de la ubicacion del propio script,
# para que el stack sea relocalizable sin editar nada.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

case "${1:-list}" in
  list)   ACTION=list ;;
  add)    ACTION=add ;;
  link)   ACTION=link ;;
  unlink) ACTION=unlink ;;
  edit)   ACTION=edit ;;
  test)   ACTION=test ;;
  cleanup) ACTION=cleanup ;;
  *)      echo "uso: $0 {list|add|link|unlink|edit|test|cleanup}"; exit 1 ;;
esac

# --- los helpers JS viven en el container (node no esta en el host) ---

case "$ACTION" in
  cleanup)
    echo "=== borrando scripts de andamiaje ==="
    for f in .setup.js .setup2.js .setup3.js .setup5.js .setup6.js .setup7.js \
             .link.js .fix-targets.js .firetest.js; do
      [ -f "$f" ] && { rm -f "$f"; echo "  borrado: $f"; }
    done
    docker exec kuma sh -c 'rm -f /tmp/.setup*.js /tmp/.link.js /tmp/.fix-targets.js /tmp/.firetest.js 2>/dev/null || true'
    echo "  (los temporales del container tambien)"
    echo
    echo "=== queda en $DIR ==="
    ls -la
    exit 0
    ;;
  add)
    NAME="${2:?falta nombre}"; TYPE="${3:?falta tipo}"; URL="${4:?falta url}"
    PORT="${5:-}"
    ;;
  edit)
    ID="${2:?falta id}"
    NAME="${3:?falta nombre}"
    URL="${4:?falta url}"
    # 5to: codigos HTTP aceptados (opcional). 6to: tipo (opcional).
    CODES="${5:-}"
    TYPE="${6:-http}"
    ;;
esac

# --- subir los archivos al container y ejecutar el JS ---
docker cp "$DIR/.admin-credentials" kuma:/tmp/.admin-credentials >/dev/null
docker cp "$DIR/.telegram-token"    kuma:/tmp/.telegram-token    >/dev/null

cat > "$DIR/.kuma-action.js" << 'JSEOF'
// Accion de gestion de Kuma, ejecutada dentro del container.
//
// ---- QUIRKS DE LA API DE KUMA 2.5.11 (verificados leyendo el source) ----
//
// 1. No hay API REST: todo son eventos de socket.io. El cliente oficial
//    (socket.io-client) viene en la imagen.
//
// 2. addNotification(notification, notificationID, callback) -> 3 args.
//    Para crear, notificationID va en null.
//
// 3. getMonitorList(callback) responde solo {ok:true}; la lista real llega
//    por el evento "main" del socket, no en el ack.
//
// 4. notificationIDList debe ser un OBJETO {id: true}, NO un array.
//    El server hace for...in, que itera las CLAVES: un array [1] produce
//    la clave "0" y el INSERT falla con FOREIGN KEY constraint.
//
// 5. El payload solo puede traer columnas que existan en la tabla monitor
//    (PRAGMA table_info). Campos frontend-only como cache, enabled,
//    kumaNewTags o parent rompen el INSERT con "no such column".
//
// 6. El server reasigna a mano ~45 campos desde el payload con nombre
//    camelCase: retryInterval, ignoreTls, expiryNotification,
//    domainExpiryNotification, invertKeyword, saveResponse, etc.
//    Los que pasa directo a columna van en snake_case.
//
// 7. El model valida (monitor.js validate()):
//      this.interval >= MIN_INTERVAL_SECOND
//      this.retryInterval >= MIN_INTERVAL_SECOND
//
// 8. Un monitor tipo "port" (tcp.js) usa monitor.hostname, NO monitor.url:
//      tcping(monitor.hostname, monitor.port)
//
// 9. El provider de Telegram usa telegramChatID (con D mayuscula).
//    El nombre viejo telegramChatId queda ignorado y el envio falla con
//    "chat_id is empty".
//
// 10. editMonitor(monitor, callback) -> 2 args. Si falta
//     accepted_statuscodes, la validacion tira "Cannot read properties
//     of undefined (reading 'every')".
// ===========================================================

const fs = require("node:fs");
const { io } = require("socket.io-client");
const { DatabaseSync } = require("node:sqlite");

const CRED = "/tmp/.admin-credentials";
const TOKEN_FILE = "/tmp/.telegram-token";
const URL_BASE = "http://127.0.0.1:3001";

function readKV(file) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}
const cred = readKV(CRED);
const USER = cred.KUMA_ADMIN_USER;
const PASS = cred.KUMA_ADMIN_PASS;
// The alert destination is NOT hardcoded here. The notification already
// exists in Kuma's database with its own chat id; this script reads it
// back from there. Keeping a chat id in the source would leak where the
// alerts go to anyone who reads the repository.

function connect() {
  return new Promise((resolve, reject) => {
    const s = io(URL_BASE, { transports: ["websocket"], reconnection: false, timeout: 15000 });
    const t = setTimeout(() => reject(new Error("timeout conectando")), 20000);
    s.on("connect", () => { clearTimeout(t); resolve(s); });
    s.on("connect_error", (e) => { clearTimeout(t); reject(new Error("connect_error: " + e.message)); });
  });
}
function emit(s, ev, ...args) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve({ error: "timeout" }), 20000);
    s.emit(ev, ...args, (res) => { clearTimeout(timer); resolve(res); });
  });
}

const ACTION = process.env.KUMA_ACTION;
const NEW_NAME = process.env.KUMA_NEW_NAME || "";
const NEW_TYPE = process.env.KUMA_NEW_TYPE || "";
const NEW_URL = process.env.KUMA_NEW_URL || "";
const NEW_PORT = process.env.KUMA_NEW_PORT || "";

function loadDB(readonly = true) {
  return new DatabaseSync("/app/data/kuma.db", { readOnly: readonly });
}

// ---- defaults para columnas NOT NULL ----
const COL_DEFAULTS = {
  active: true, interval: 60, maxretries: 0, retry_interval: 60,
  maxredirects: 10, ignore_tls: false, upside_down: false, method: "GET",
  weight: 2000, expiry_notification: true, resend_times: 0, retry: 0,
  timeout: 20, accepted_statuscodes_json: '["200-299"]', conditions: "[]",
  kafka_producer_brokers: "[]", kafka_producer_sasl_options: "[]",
  rabbitmq_nodes: "[]", kuma_new_tags: "[]", follow_redirect: false,
  resend_notification_on_every_retry: false,
  retry_only_on_status_code_failure: false, dns_resolve_type: "",
  dns_resolve_server: "", hostname: "", keyword: "", body: null, headers: null,
  http_body: null, http_headers: null, http_method: "", basic_auth_user: null,
  basic_auth_pass: null, bearer_token: "", oauth_client_id: "",
  oauth_client_secret: "", oauth_auth_method: "", oauth_token_url: "",
  oauth_scopes: "", oauth_audience: "", docker_container: "",
  docker_host: null, proxy_id: null, mqtt_topic: "", mqtt_success_message: "",
  mqtt_username: "", mqtt_password: "", database_connection_string: "",
  database_query: "", auth_method: "", auth_domain: "", auth_workstation: "",
  grpc_url: "", grpc_protobuf: null, grpc_body: null, grpc_metadata: null,
  push_token: "", dns_last_result: "", description: "", location: "",
  protocol: "", game: "", packet_size: "", tls_ca: "", tls_cert: "", tls_key: "",
};

// ---- campos que el server reasigna (camelCase) ----
const SERVER_MAPPED = {
  interval: 60, retryInterval: 60, resendInterval: 0, maxretries: 0,
  timeout: 20, ignoreTls: false, upsideDown: false, expiryNotification: true,
  domainExpiryNotification: true, invertKeyword: false, maxredirects: 10,
  saveResponse: false, saveErrorResponse: false, responseMaxLength: 0,
  dns_resolve_type: "", dns_resolve_server: "", pushToken: "",
  docker_container: "", docker_host: null, method: "GET", body: null,
  headers: null, hostname: "", keyword: "", game: "", location: "",
  protocol: "", packetSize: "", ipFamily: "", basic_auth_user: "",
  basic_auth_pass: "", bearer_token: "", oauth_client_id: "",
  oauth_client_secret: "", oauth_auth_method: "", oauth_token_url: "",
  oauth_scopes: "", oauth_audience: "", tlsCa: "", tlsCert: "", tlsKey: "",
  mqttUsername: "", mqttPassword: "",
};

function buildMonitor(m, cols) {
  const p = {};
  for (const [name, col] of cols) {
    if (name === "id" || name === "created_date" || name === "user_id") continue;
    if (name in COL_DEFAULTS) p[name] = COL_DEFAULTS[name];
    else p[name] = col.notnull ? 0 : null;
  }
  Object.assign(p, SERVER_MAPPED);
  p.name = m.name;
  p.type = m.type;
  p.url = m.url || "";
  p.port = m.port || "";
  p.hostname = m.hostname || "";
  p.active = true;
  p.accepted_statuscodes = ["200-299"];
  p.kafkaProducerBrokers = [];
  p.kafkaProducerSaslOptions = [];
  p.conditions = [];
  p.rabbitmqNodes = [];
  // Kuma esta en modo SENSOR PURO: el dashboard (cluster-dashboard) es
  // el que avisa. Si un monitor nuevo se crea enlazado a la
  // notificacion de Telegram, cada caida genera DOS mensajes (uno de
  // Kuma y otro del dashboard).
  //
  // notificationIDList debe ser un OBJETO (el server lo recorre con
  // for...in sobre las claves), nunca un array.
  p.notificationIDList = {};
  return p;
}

(async () => {
  if (ACTION === "list") {
    const db = loadDB();
    const ms = db.prepare("SELECT id,name,type,url,port,hostname,active,interval FROM monitor ORDER BY id").all();
    console.log("monitores:", ms.length);
    let up = 0, down = 0;
    for (const m of ms) {
      const h = db.prepare("SELECT status,ping,msg,time FROM heartbeat WHERE monitor_id=? ORDER BY time DESC LIMIT 1").get(m.id);
      if (h && h.status === 1) up++; else down++;
      const target = m.type === "port" ? `${m.hostname || m.url}:${m.port}` : m.url;
      console.log(`  [${String(m.id).padStart(2)}] ${String(m.name).padEnd(24)} ${String(m.type).padEnd(5)} ${target}`);
      console.log(`       ${h ? (h.status === 1 ? "UP  " : "DOWN") + " " + String(h.ping).padStart(5) + "ms  " + String(h.msg || "").slice(0, 45) : "sin heartbeat"}`);
    }
    console.log(`\n  UP: ${up}  DOWN: ${down}`);
    const nn = db.prepare("SELECT id,name,config FROM notification").all();
    for (const n of nn) {
      const c = JSON.parse(n.config);
      console.log(`  notificacion id=${n.id} ${n.name} tipo=${c.type} chat=${c.telegramChatID || c.telegramChatId || "(sin chat)"}`);
    }
    const mn = db.prepare("SELECT COUNT(*) c FROM monitor_notification").get();
    console.log(`  monitor_notification: ${mn.c} filas`);
    return;
  }

  const s = await connect();
  const login = await emit(s, "login", { username: USER, password: PASS, token: "" });
  if (login && login.error) { console.error("LOGIN FALLO:", login.error); process.exit(2); }

  if (ACTION === "test") {
    const db = loadDB();
    const n = db.prepare("SELECT config FROM notification WHERE id=1").get();
    if (!n) { console.error("no hay notificacion id=1"); process.exit(3); }
    const cfg = JSON.parse(n.config);
    // Kuma 2.5.11 espera telegramChatID (con D mayuscula).
    if (cfg.telegramChatId && !cfg.telegramChatID) {
      cfg.telegramChatID = cfg.telegramChatId;
      delete cfg.telegramChatId;
    }
    // testNotification exige sesion autenticada (checkLogin mira
    // socket.userID). El evento "login" NO autentica el socket: solo
    // devuelve un JWT. Hay que canjear ese JWT con "loginByToken" en
    // el MISMO socket para que afterLogin setee socket.userID.
    const auth = await emit(s, "loginByToken", login.token);
    if (auth && auth.error) { console.error("loginByToken fallo:", auth.error); process.exit(6); }
    console.log("  loginByToken:", JSON.stringify(auth));
    const res = await emit(s, "testNotification", cfg);
    console.log("testNotification:", JSON.stringify(res));
    s.disconnect();
    return;
  }

  if (ACTION === "add") {
    const db = loadDB();
    const cols = new Map(db.prepare("PRAGMA table_info(monitor)").all().map((c) => [c.name, c]));
    const m = {
      name: NEW_NAME, type: NEW_TYPE, url: NEW_URL,
      port: NEW_PORT, hostname: NEW_TYPE === "port" ? NEW_URL : "",
    };
    const res = await emit(s, "add", buildMonitor(m, cols));
    console.log("add:", res && res.error ? "ERROR " + res.msg : `OK (id=${res.monitorID})`);
    if (!res || res.error) { s.disconnect(); process.exit(4); }
    // NO se enlaza la notificacion: Kuma es sensor puro y el dashboard
    // avisa (ver buildMonitor). Si se quisiera el modo "Kuma avisa
    // solo", se ejecuta despues: kuma-manage.sh link
    const full = db.prepare("SELECT * FROM monitor WHERE id=?").get(res.monitorID);
    console.log("creado:", JSON.stringify({ id: full.id, name: full.name, type: full.type, url: full.url }));
    const mn = db.prepare("SELECT COUNT(*) c FROM monitor_notification").get();
    console.log("monitor_notification:", mn.c, "filas (debe seguir en 0: sensor puro)");
    s.disconnect();
    return;
  }

  if (ACTION === "unlink") {
    // Desasocia todos los monitores de la notificacion.
    //
    // Kuma 2.5.11 no tiene "desvincular" en la API de Socket.IO: se
    // reenvia el monitor con notificationIDList vacio ({}), y el servidor
    // borra los links en monitor_notification.
    //
    // Se usa el mismo truco que link pero con el mapa vacio. El
    // notificationIDList debe ser un OBJETO (el servidor lo recorre con
    // for...in sobre las claves); un array [1] insertaria notification_id
    // = '0' y violaria el foreign key.
    const db = loadDB();
    const ms = db.prepare("SELECT * FROM monitor ORDER BY id").all();
    for (const m of ms) {
      let acc = ["200-299"];
      try { acc = JSON.parse(m.accepted_statuscodes_json || "[]"); } catch {}
      const payload = { ...m, notificationIDList: {}, accepted_statuscodes: acc };
      const res = await emit(s, "editMonitor", payload);
      console.log(`  unlink ${String(m.name).padEnd(24)} ->`, res && res.error ? "ERROR " + String(res.msg).slice(0, 120) : "OK");
    }
    s.disconnect();
    await new Promise((r) => setTimeout(r, 1500));
    const db2 = loadDB();
    console.log("monitor_notification:", db2.prepare("SELECT COUNT(*) c FROM monitor_notification").get().c, "filas");
    return;
  }

  if (ACTION === "edit") {
    // Edita un monitor existente: nombre, target y tipo.
    //
    // editMonitor(monitor, callback) NO lleva id como argumento — el id
    // va DENTRO del payload (monitor.id). El servidor busca la fila con
    // R.findOne("monitor", " id = ? ", [monitor.id]).
    //
    // Se reenvia el monitor COMPLETO desde la DB (spread de la fila) con
    // los campos que se quieren cambiar encima. editMonitor asigna
    // dozens de campos uno a uno desde el payload; mandar solo los
    // campos cambiados los pondria en undefined y los borraria.
    //
    // Los accepted_statuscodes van como ARRAY de strings (el server
    // llama .every() y exige typeof string), y el notificationIDList
    // como OBJETO (lo recorre con for...in). Kuma esta en modo sensor
    // puro (sin notificaciones), asi que se manda {} para no re-vincular.
    const db = loadDB();
    const mid = Number(process.env.KUMA_EDIT_ID);
    const m = db.prepare("SELECT * FROM monitor WHERE id=?").get(mid);
    if (!m) { console.error("no existe el monitor id=" + mid); s.disconnect(); process.exit(6); }

    // Los codigos aceptados se pueden sobreescribir con el 5to argumento
    // (ej: "200-299,401-499"). Si no se pasa, se conserva el actual.
    let acc = ["200-299"];
    try { acc = JSON.parse(m.accepted_statuscodes_json || "[]"); } catch {}
    const accArg = process.env.KUMA_EDIT_CODES;
    if (accArg) {
      acc = accArg.split(",").map(s => s.trim()).filter(Boolean);
      console.log("  accepted_statuscodes:", JSON.stringify(acc));
    }

    const newType = process.env.KUMA_EDIT_TYPE || m.type;
    const payload = {
      ...m,
      name: process.env.KUMA_EDIT_NAME,
      type: newType,
      url: process.env.KUMA_EDIT_URL,
      // Un monitor tipo "port" usa hostname+port; un "http" usa url.
      hostname: newType === "port" ? (process.env.KUMA_EDIT_URL || "") : (m.hostname || ""),
      port: newType === "port" ? (m.port || null) : null,
      notificationIDList: {},
      accepted_statuscodes: acc,
    };
    const res = await emit(s, "editMonitor", payload);
    console.log(`  edit ${mid} ->`, res && res.error ? "ERROR " + String(res.msg).slice(0, 160) : "OK");
    if (!res || res.error) { s.disconnect(); process.exit(7); }
    s.disconnect();
    await new Promise((r) => setTimeout(r, 1200));
    const db2 = loadDB();
    const after = db2.prepare("SELECT id,name,type,url,hostname,port,accepted_statuscodes_json FROM monitor WHERE id=?").get(mid);
    console.log("  resultado:", JSON.stringify(after));
    return;
  }

  if (ACTION === "link") {
    const db = loadDB();
    const notif = db.prepare("SELECT id FROM notification ORDER BY id LIMIT 1").get();
    if (!notif) { console.error("no hay notificacion"); s.disconnect(); process.exit(5); }
    const NOTIF_ID = notif.id;
    const ms = db.prepare("SELECT * FROM monitor ORDER BY id").all();
    for (const m of ms) {
      let acc = ["200-299"];
      try { acc = JSON.parse(m.accepted_statuscodes_json || "[]"); } catch {}
      const payload = { ...m, notificationIDList: { [NOTIF_ID]: true }, accepted_statuscodes: acc };
      const res = await emit(s, "editMonitor", payload);
      console.log(`  link ${String(m.name).padEnd(24)} ->`, res && res.error ? "ERROR " + String(res.msg).slice(0, 120) : "OK");
    }
    s.disconnect();
    await new Promise((r) => setTimeout(r, 1500));
    const db2 = loadDB();
    console.log("monitor_notification:", db2.prepare("SELECT COUNT(*) c FROM monitor_notification").get().c, "filas");
    return;
  }
})().catch((e) => { console.error("ERROR:", e.message); process.exit(1); });
JSEOF

# Copiar el JS al container.
#
# Se usa `docker cp` con timeout: sin el, un daemon lento deja el script
# colgado indefinidamente (sin una sola linea de output) y el comando
# del operador expira sin saber que paso. Con timeout, el script falla
# rapido y se puede reintentar.
# El docker cp se cuelga de forma intermitente cuando el daemon esta
# ocupado (un exec previo en vuelo). Se reintenta y se VERIFICA que el
# archivo llego comparando tamanios: un cp que "termina" sin copiar es
# peor que uno que falla visiblemente.
COPIED=0
for attempt in 1 2 3; do
  if timeout 25 docker cp "$DIR/.kuma-action.js" kuma:/tmp/.kuma-action.js >/dev/null 2>&1; then
    HOST_SZ=$(stat -c %s "$DIR/.kuma-action.js" 2>/dev/null || echo 0)
    CONT_SZ=$(timeout 15 docker exec kuma stat -c %s /tmp/.kuma-action.js 2>/dev/null | tr -d '\n' || echo 0)
    if [ "$HOST_SZ" = "$CONT_SZ" ]; then
      COPIED=1
      break
    fi
    echo "  aviso: docker cp no copio completo (host=$HOST_SZ container=$CONT_SZ), reintentando..." >&2
  fi
  sleep 2
done
if [ "$COPIED" -ne 1 ]; then
  echo "ERROR: no se pudo copiar el JS al container tras 3 intentos." >&2
  echo "       Diagnostico: el daemon docker esta ocupado o el container no responde." >&2
  echo "       Prueba manual: docker exec kuma ls -la /tmp/.kuma-action.js" >&2
  rm -f "$DIR/.kuma-action.js"
  exit 9
fi

case "$ACTION" in
  list) ENV_ARGS="KUMA_ACTION=list" ;;
  test) ENV_ARGS="KUMA_ACTION=test" ;;
  link) ENV_ARGS="KUMA_ACTION=link" ;;
  unlink) ENV_ARGS="KUMA_ACTION=unlink" ;;
  edit)  ENV_ARGS="KUMA_ACTION=edit KUMA_EDIT_ID=$ID KUMA_EDIT_NAME=$NAME KUMA_EDIT_URL=$URL KUMA_EDIT_TYPE=$TYPE KUMA_EDIT_CODES=$CODES" ;;
  add)  ENV_ARGS="KUMA_ACTION=add KUMA_NEW_NAME=$NAME KUMA_NEW_TYPE=$TYPE KUMA_NEW_URL=$URL KUMA_NEW_PORT=$PORT" ;;
esac

timeout 120 docker exec -w /app -e NODE_PATH=/app/node_modules \
  -e "$ENV_ARGS" kuma node /tmp/.kuma-action.js 2>&1 | grep -vE "ExperimentalWarning|trace-warnings"

# limpiar el JS temporal del host y del container
rm -f "$DIR/.kuma-action.js"
docker exec kuma rm -f /tmp/.kuma-action.js 2>/dev/null || true
