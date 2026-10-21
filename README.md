# Серверный коннектор SKVOZ

`skvoz-server` 9.0.0 управляет TLS, NATS, учётными данными, выделением устройств
и процессами. TCP-сокеты назначения, IPv4/IPv6, очередь пакетов и общий
сетевой контракт обслуживает Rust `skvoz-network-runtime` 0.7.0 с тем же
универсальным Core 5.0.0. Ruby передаёт только управляющие записи local API1;
network 6 не зависит от ОС и языка клиентского коннектора.

[Руководство сервера](docs/server-connector.md) — основной контракт
конфигурации, развёртывания, доступа, изоляции и проверок.
Настройки установки задаются непосредственно в `compose.yaml`.
Полный сервер управляет пользователями, устройствами, Auth Callout, общим
Core/network runtime и TCP/IP-выходом. Он работает самостоятельно; при наличии
входов инициирует к ним отдельные штатные NATS leaf connections для APP, AUTH
и SYS. Входы и промежуточные брокеры используют stock NATS, стандартный ACME
client и shell hooks, без Ruby/Core/helper. Служебные bootstrap credentials
отделены от пользовательской аутентификации и ограничены своим account.
Готовый образ и локальная сборка запускаются через Compose и используют
один Dockerfile. Репозиторий хранит Gemfile/lock-файл, Ruby-исходники,
исполняемые команды, Dockerfile, Compose и RSpec. В `deployment/` находятся
скрипты [автообновления образа](docs/server-connector.md#автообновление-готового-образа).

Образ содержит Ruby 4.0.7, gems, NATS, общий Rust runtime и ограниченный
`skvoz-network-helper`. Начальный процесс создаёт private socketpair и запускает
helper при включённом IP-выходе; затем тот же PID1 становится Ruby-процессом UID10001 без capabilities.
NATS и runtime также работают UID10001 без capabilities. Только helper сохраняет
NET_ADMIN; только runtime владеет его каналом. Ruby собирает статусы дочерних
процессов. Смерть runtime/helper требует нового запуска контейнера.

Состояние приложения хранится в `/var/lib/skvoz` с владельцем UID10001;
отдельное состояние helper и закреплённые за peer сетевые выдачи — в
root-owned `/var/lib/skvoz-network`. Каталоги имеют режим0700, файлы0600.
Сервер по умолчанию использует IPv4 NAT44 с пулом `10.203.0.0/16`;
`SKVOZ_NETWORK` необязательна и служит для изменения сетевой конфигурации.
IPv6 требует явно заданного routed `/64`, реальной обратной маршрутизации
и соответствующих namespace sysctls. TCP-only конфигурация задаёт пустые
семейства и не использует helper/TUN. Публикуемые оператором дополнительные
адреса и management endpoints должны присутствовать в доверенной конфигурации.

Зависимости приходят из immutable GitHub Releases поставщиков с exact URL/SHA256.
Готовый Docker-образ Server публикуется в `ghcr.io/skvoz-project/skvoz-server`.
Server закрепляет
[готовый Network bundle](docs/artifacts.md) с Core, затем обычный push в main
проверяет этот выпуск, собирает и публикует готовый продуктовый image Server.
Компиляция Core/Network выполняется отдельно в их репозиториях. Digest,
target, ABI и install closure проверяются до установки. Отсутствующий или
несовместимый bundle не вызывает сборку исходников.

GitHub Actions запускает `bash bin/ci`: собирает Docker targets, выполняет Ruby
и интеграционные тесты, затем экспортирует продуктовый образ. Для этого не нужны
доступ к физическому диску runner или специальные проверки cgroup. Следующий
job загружает тот же проверенный образ в GHCR с тегами `sha-<полный commit>` и
`latest`. Обычный запуск использует `docker pull` и готовый [Compose](compose.yaml).
Отдельные [проверки совместимости](docs/interoperability.md) получают этот же
образ из GHCR по явно закреплённому registry digest.

Для локальной сборки с ограничением нагрузки используется отдельная команда:

```sh
bash bin/build-local deploy artifacts/server-image/local
docker image tag skvoz-server:ci-deploy skvoz-server:9.0.0
```

Локальный сценарий требует Linux с Docker и полной видимостью host cgroup v2.
Он подготавливает ограниченный BuildKit, проверяет реальные лимиты и удаляет
свои временные containers/cache. Подробности — в [инструкции](docs/artifacts.md#локальная-сборка-с-ограничениями).
Основной Compose использует GHCR и `pull_policy: missing`. Для локальной сборки
предназначен overlay `compose.source.yaml` с локальным тегом и `pull_policy: never`.
[Проверки](docs/server-connector.md#регрессионные-проверки) запускаются напрямую
через RSpec; [отдельная совместимость клиентов](docs/interoperability.md) использует
готовый продуктовый image и существующее локальное администрирование.
[Совместимость транспорта](docs/server-connector.md#совместимость-транспорта)
задаёт необходимые версии. Лицензия — [MIT](LICENSE).
