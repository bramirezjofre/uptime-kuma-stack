# uptime-kuma-stack

Un stack de Docker para [Uptime Kuma](https://github.com/louislam/uptime-kuma)
junto con un script único de gestión.

Kuma sondea endpoints HTTP/TCP y decide qué está arriba y qué está abajo.
En la configuración "sensor puro" **Kuma no avisa**: solo sondea y expone
su estado. El aviso lo manda otro componente que consume el endpoint
Prometheus de Kuma. Así hay un solo camino de alerta y un solo token de
bot.

## El endpoint de lectura

Kuma expone sus monitores en formato Prometheus:

```
GET http://<host>:<puerto>/metrics
Authorization: Basic base64(":" + <api key>)
```

El usuario Basic es **vacío** y la API key va como contraseña. Con
`Bearer` la respuesta es 401.

Los nombres de métrica que interesan:

| Métrica | Qué es |
|---|---|
| `monitor_status` | 1 = arriba, 0 = caído |
| `monitor_response_time` | latencia en milisegundos |
| `monitor_uptime_ratio` | Ratio de uptime (30 días) |
| `monitor_cert_days_remaining` | Días hasta que expire el certificado TLS |
| `monitor_cert_is_valid` | Validez del certificado TLS |

Los certificados TLS salen gratis de este endpoint: no hace falta un
cliente TLS extra.

## Estructura

```
.
├── docker-compose.yml      # la instancia
├── kuma-manage.sh          # gestión (único punto de entrada)
├── data/                   # kuma.db + uploads   (fuera de git)
├── .admin-credentials      # admin + API key     (fuera de git)
└── .telegram-token         # token del bot        (fuera de git)
```

Los secretos **no están en git**. La API key solo existe en texto plano
en `.admin-credentials`: Kuma guarda un hash bcrypt, así que **no se
puede recuperar de la base**. Si se pierden ambos archivos, hay que
generar una key nueva desde la UI.

El chat de destino de las alertas se guarda en `.admin-credentials` con la
clave `KUMA_CHAT_ID`.

## Comandos

```bash
bash kuma-manage.sh list
bash kuma-manage.sh add <nombre> <http|port> <url> [puerto]
bash kuma-manage.sh edit <id> <nombre> <url> [codigos] [tipo]
bash kuma-manage.sh link      # (re)asocia la notificación
bash kuma-manage.sh unlink    # desasocia (modo sensor puro)
bash kuma-manage.sh test      # alerta de prueba
bash kuma-manage.sh cleanup   # borra el andamiaje
```

`edit` acepta un quinto argumento opcional con los códigos HTTP
aceptados: `"200-299"` (por defecto), `"200-299,401-499"`, etc.

## Por qué hay un solo script

La API de Kuma **no es REST**: la maneja por Socket.IO, y esa superficie
no está documentada ni es estable entre versiones. Sembrar una instancia
a mano deja una pila de scripts de andamiaje (`.setup.js`, `.link.js`,
`.fix-targets.js`…) y nadie sabe cuál es el vigente.

`kuma-manage.sh` consolida la secuencia que funciona y **documenta
dentro los quirks descubiertos**: el `notificationIDList` es un objeto
(el server lo recorre con `for...in`), `login` no autentica el socket
(hay que llamar `loginByToken` en el mismo socket), el hash bcrypt es
la verdad, los monitores tipo `port` usan `hostname` y no `url`, y
`editMonitor` reasigna decenas de campos (hay que reenviar la fila
entera).

## Gotchas que cuestan horas

- **El puerto publicado es a propósito.** Kuma escucha en 3001 dentro
  del container y el host lo publica en otro puerto, porque el 3001 del
  host puede estar ocupado por otro stack. No lo muevas sin revisar los
  puertos publicados de los demás servicios del host.

- **Un monitor puede apuntar al servicio equivocado y seguir reportando
  UP.** Si dos stacks del host publican puertos que se solapan, el
  monitor puede estar sondeando otra aplicación y aun así verse
  perfecto. **La prueba de que un monitor apunta al servicio correcto
  es que el *body* del endpoint lo nombre**, no que devuelva 200.

- **Un monitor que acepta 4xx no es un monitor.** Solo detecta cortes
  de red, no aplicaciones rotas. Dale una **ruta de API real** que
  devuelva JSON y acepta solo 2xx.

- **`docker cp` dentro de un script puede colgarse en silencio.** Llévale
  timeout y verifica que el archivo llegó comparando tamaños; un `cp`
  que "termina" sin copiar es peor que uno que falla visiblemente.

- **Un `docker exec` que se cuelga es un problema de tubería, no de
  API.** Para averiguar si la operación en sí funciona, ejecuta el JS
  directamente contra el container y saltate el paso de copia.
