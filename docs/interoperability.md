# Отдельная проверка совместимости клиентов

Обычные build, CI и package клиентского приложения не требуют Server.
Проверка совместимости запускается отдельно с готовым продуктовым образом
Server, собственным клиентом и его производственными Core/Network зависимостями.
Тесты, targets и сценарии остаются в клиентском репозитории. Исходники Server,
`spec/support`, Ruby/gems Server и Docker socket клиенту не передаются.

## Готовый продукт

Server8.0.1 публикует Linux x86_64 image в immutable GitHub Release:

- tag `server-v8.0.1-<FULL40SHA>` с реальным owning commit Server;
- `skvoz-server-8.0.1-x86_64-unknown-linux-gnu.docker.tar.gz`;
- `SHA256SUMS`;
- `server-image.json`.

Receipt `server-image.json` имеет точные поля:

```json
{
  "schema": 1,
  "component": "skvoz-server",
  "version": "8.0.1",
  "target": "x86_64-unknown-linux-gnu",
  "source": {
    "repository": "https://github.com/skvoz-project/skvoz-server",
    "revision": "<FULL40SHA>"
  },
  "image_id": "sha256:<64 lowercase hexadecimal digits>",
  "tag": "server-v8.0.1-<FULL40SHA>"
}
```

Потребитель явно закрепляет точный release, SHA256 archive и receipt, image ID
и source identity. Он проверяет metadata и checksum до `docker image load`,
после загрузки — точный image ID, Linux/amd64 и image labels
`org.opencontainers.image.source`, `org.opencontainers.image.version`,
`org.opencontainers.image.revision`. Запуск использует image ID; mutable tag,
`latest`, короткий SHA и source rebuild fallback не допускаются. Образ содержит
NATS, Ruby, locked gems и готовый Network/Core; отдельная установка Server
зависимостей на стороне клиента не нужна. Новый pin создаётся после реального
выпуска, а не по предполагаемому будущему digest.

## Запуск и ресурсы

Внешний контроллер проверки владеет lifecycle контейнеров. Он заранее выбирает
различные свободные broker, monitor и target порты и передаёт target порты
своим тестам. Подмена точных портов диапазоном или широким allow не допускается.
Следующий config использует существующий TCP-only режим и локальный CA:

```json
{
  "v": 5,
  "state_dir": "/var/lib/skvoz",
  "address": "localhost",
  "bind": "127.0.0.1",
  "port": 31422,
  "monitor_port": 31423,
  "network": {},
  "allow": [
    {"cidr":"127.0.0.1/32","protocols":[6],"ports":[18080,18081]},
    {"cidr":"::1/128","protocols":[6],"ports":[18080,18081]}
  ],
  "tls": {"mode":"local"}
}
```

Порты в примере заменяются выбранными портами конкретного запуска. Пустой allow
запрещает назначения. Management endpoints сохраняют собственный запрет.
Конфигурация и состояние принадлежат UID/GID10001: каталог0700, файлы0600.
Контроллер запускает точный образ с `serve --config /var/lib/skvoz/server.json`,
UID/GID10001, пустыми capabilities, no-new-privileges, read-only rootfs,
ограниченным tmpfs и отдельным временным state volume. TCP-only режим не требует
TUN или NET_ADMIN. Linux host networking позволяет обоим участникам использовать
те же точные IPv4/IPv6 loopback targets; bind остаётся `127.0.0.1`.

До запуска задаются конечный общий deadline и совокупные CPU/RAM/swap/PID/I/O
лимиты Server, клиента и targets. Проверяются реальные cgroups и ancestry,
включая дочерние процессы; конфигурационные flags сами по себе этого не доказывают.
Контроллер проверяет `skvoz-server health` до старта тестов, затем всегда
завершает/reap процессы, удаляет только свои контейнеры/volume и подтверждает
их отсутствие в пределах исходного deadline. Локальный CA/credentials не
публикуются в логах или CI artifacts. Этот маршрут не квалифицирует VPN/TUN,
Windows или выполнение на Android.

## CLI и локальное администрирование

Внешний контроллер может использовать обычный [Server CLI](server-connector.md):
`health`, `user add`, `user device-add`, `user reset-password`, `user remove`.
CLI возвращает JSON; секретный пароль передаётся через `--password-stdin`.
`user add` и `device-add` возвращают текущий enrollment bundle v4 с CA.

Для операций во время сценария непривилегированный тест получает **только
существующий inode admin.sock**, смонтированный read-only в приватный каталог.
Контроллер разрешает точный container ID и host `State.Pid` после readiness,
получает `Mountpoint` своего уникального volume командой
`docker volume inspect --format '{{.Mountpoint}}' <OWNED_VOLUME>` и передаёт
Docker daemon только `<Mountpoint>/admin.sock` как file bind. Проверяются
абсолютный путь, принадлежность точному volume и одинаковые `dev/inode` сокета
в Server и payload до/после запроса. Путь через `/proc/<pid>/root` использовать
не следует: runtime может отклонить такой mount. Полный Server state volume
и Docker socket не монтируются в клиентский payload.

Сокет принадлежит Server UID10001, режим0600. Server проверяет реальный peer UID
через `SO_PEERCRED`; он должен совпадать с UID Server. User namespace mapping
обоих контейнеров должен сохранять это равенство. Это локальная привилегированная
административная возможность; она выдаётся только участнику конкретной проверки.

Одно соединение передаёт один JSON object с завершающим `\n` и получает один
ответ с `\n`, затем Server закрывает соединение. Допустимые поля запроса —
только `operation`, `login`, `password`. Полный запрос/ответ ограничен65536 bytes.
Потребитель проверяет типы, framing, размер и конечное время ожидания своим
обычным Unix socket API; никакой модуль Server не импортируется.

| operation | Поля и результат |
| --- | --- |
| `health` | Без login/password; `healthy`, revision и текущее состояние readiness. |
| `auth-public` | Без login/password; открытые ключи authority и namespace. |
| `list` | Без login/password; список login, devices и capacity. |
| `show` | `login`; адрес/trust и назначенные devices пользователя. |
| `add` | Новый `login`, необязательный `password`; bundle v4. |
| `device-add` | `login` и действующий `password`; новый device bundle v4. |
| `reset-password` | `login`, необязательный новый `password`; адрес, порт, login, пароль и результат retirement. |
| `remove` | `login`; removed и результат retirement. |

Login —1–64 ASCII letters/digits/underscore/hyphen, без префикса `__skvoz_`.
Пароль —12–72 bytes UTF-8 без NUL; при отсутствии у add/reset-password Server
генерирует случайный пароль. CLI ограничивает прочитанный stdin1024 bytes,
но это не расширяет допустимый размер пароля.
Device-add требует действующий пароль; проверка исчерпания device pool и
revision/revocation guarantees остаётся штатной. Add/device-add возвращают
`ca_pem` для managed CA. Reset-password не возвращает новый enrollment bundle.

```json
{"operation":"remove","login":"client"}
```

Успех: `{"ok":true,"result":<обычный результат CLI>}`.
Ошибка: `{"ok":false,"error":"Administration request failed"}`.
Неуспех не считается выполненной мутацией или подтверждённым физическим revoke.
Ingress использует настроенный `admin_timeout` (по умолчанию5s), выполнение
мутации ограничено15s, запись ответа2s; клиент задаёт собственный общий deadline.
Одновременно обслуживается не более8 административных соединений.

Bind отдельного файла удерживает inode: после рестарта Server сокет создаётся
заново. Контроллер должен подтвердить readiness и пересоздать mount/payload;
старое соединение или старый inode не являются новым endpoint. Сценарии,
которые перезапускают только клиент, используют тот же живой Server endpoint.
