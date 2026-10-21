# Network bundle и продуктовый образ Server

Server использует готовый Network bundle с Core. Компиляция Rust выполняется
поставщиком; отсутствие или несовместимость archive не вызывает source fallback.
Server самостоятельно собирает Ruby/NATS host и выпускает готовый Docker image.
Обычные клиентские build/CI не получают Server; отдельная совместимость использует
[продуктовый образ и локальное администрирование](interoperability.md).

## Точный выпуск Network

`product-native-lock.json` фиксирует URL, SHA256, version/target/profile и tuple:
Network0.7.0, API1, network6, Core5.0.0, helper0.6.0, Core ABI1/Network ABI1,
`x86_64-unknown-linux-gnu`, `linux-gnu-bookworm`.

```sh
bundle exec ruby bin/pin-network-release 'network-v0.7.0-<FULL40SHA>'
mkdir -p artifacts/native
bundle exec ruby bin/fetch-native product-native-lock.json artifacts/native/skvoz-network-0.7.0-x86_64-unknown-linux-gnu-current-identity.tar.gz
```

Обновление выбирает конкретный опубликованный tag и SHA256SUMS, скачивает архив,
проверяет его SHA256 и наличие нужных продуктовых файлов, затем атомарно заменяет
lock. `latest`, короткий SHA и неверный digest отклоняются; ошибка сохраняет
прежний lock. Опубликованные архивы не изменяются.

Transport принадлежит Server: HTTPS с конечными timeouts и не более3 redirects,
только HTTPS после redirect; локальный `file:` разрешается относительно lock.
Размер скачивания ограничен256MiB. После проверки **всего** SHA256 обычный `tar`
за конечное время извлекает runtime/helper, Core, ресурсы и лицензии в новое
временное дерево. Извлечённые файлы используются как данные сборки; executables
получают0755, данные0644. Ошибка не оставляет частичный результат и не заменяет
существующий каталог. Дополнительный установщик из архива не требуется.

```sh
bundle exec ruby bin/install-native product-native-lock.json native-check artifacts/native/skvoz-network-0.7.0-x86_64-unknown-linux-gnu-current-identity.tar.gz
```

Команда — собственная обвязка скачивания/проверки хеша/`tar`, без копии общего
supplier validator или Rust-компиляции. Manifest поставщика сохраняется как
provenance; target/ABI/closure квалифицирует поставщик, а Server проверяет свои
версии и работу продукта. Общий [manifest contract](https://github.com/skvoz-project/skvoz-docs/blob/main/docs/artifact-manifest.md)
описывает identity поставщика.

## Dockerfile и runtime closure

| Target | Назначение |
| --- | --- |
| `base` | Ruby4.0.7, locked production gems, libsodium, Server lib и только три runtime CLI. |
| `native` | Закреплённый Network archive, SHA256 и стандартная распаковка нужных файлов. |
| `ruby-tests` | Owning RSpec и инструменты без обязательного native archive. |
| `tests` | Owning integration: NATS, готовый Network, Pebble и RSpec. |
| `deploy` | Product Ruby/NATS, runtime/helper, Core, resources/licenses; без specs, fixture exporter и build tools. |

Runtime subset хранится под `/opt/skvoz-native`, сохраняя supplier RPATH
`$ORIGIN/../lib`. `supplier-manifest.json` — исходный manifest **полного**
проверенного supplier bundle как provenance; он не объявляет runtime subset
полным install inventory. `source-inputs.sha256` сохраняет source provenance.
Динамические зависимости остаются Bookworm glibc/libgcc/OpenSSL trust и pinned
libsodium/gems. Helper не загружает Core/NATS.

Ruby4.0.7 build/runtime images, Dockerfile frontend, NATS2.15.1, Pebble2.10.1 и
BuildKit закреплены immutable digests в Dockerfile/owning CI. Bundler4.0.22 и gems
закреплены в Gemfile.lock. NATS/Ruby/Pebble/gems/native dependencies сохраняют
свои upstream licenses; код Server — [MIT](../LICENSE).

## GitHub Actions

Workflow вызывает `bash bin/ci` из clean checkout выбранного commit. Сценарий
использует стандартный Docker и последовательно выполняет:

1. Сборку `ruby-tests` и собственные Ruby specs.
2. Получение закреплённого Network archive через собственный `bin/fetch-native`
   с проверкой SHA256.
3. Сборку `tests` и интеграционные specs с NATS и готовым Network.
4. Сборку `deploy` и экспорт образа, его точного image ID и SHA256SUMS для следующего job.

Сборка Core/Network из исходников и Server fixtures других репозиториев не
нужны. Ошибка тестов останавливает дальнейшую сборку и экспорт. Сценарий
удаляет свой временный context и оставшийся test/fetch container при ошибке
или отмене. Лимит времени45минут и concurrency задаёт workflow; проверки
физических дисков, cgroup ancestry и локальные I/O limits в GitHub CI отсутствуют.
Docker использует стандартный builder runner.

## Локальная сборка с ограничениями

Отдельный `bash bin/build-local` выбирает не более половины реально доступных
host CPU/RAM с учётом ancestors, максимум4CPU/3GiB, swap0/PID256, backing-device
read8MiB/s/write2MiB/s. Exact cgroup readbacks и живой25s RUN подтверждают ancestry
под ограниченным BuildKit daemon. BuildKit и test containers работают последовательно;
cache volume сохраняется между targets и удаляется после запуска. Настройки
Docker daemon и существующие builders не изменяются.

Нужны Linux cgroup v2 с полной host visibility, Docker, Bash, coreutils/util-linux,
Git и Ruby со стандартной библиотекой. Docker должен позволять чтение host
PID/cgroup и применение backing-device I/O limits. GitHub runner этих локальных
предпосылок не требует.

```sh
bash bin/build-local ruby-tests
bash bin/build-local tests
bash bin/build-local deploy artifacts/server-image/local
```

Без аргументов локальный сценарий выполняет все три этапа. `ruby-tests` не
требует Network bundle; режимы `tests` и `deploy` получают закреплённый архив.
Уже скачанный regular archive по пути из раздела выше используется повторно,
а его SHA256 проверяется при импорте. Missing input не вызывает source fallback.

Локальная команда создаёт уникальный pinned BuildKit container с private cgroup
namespace, `max-parallelism=1`, read-only public context и своим output/cache.
Docker socket и sibling source в builder не монтируются. Общий deadline —42минуты
работы и ещё не более2минут для cleanup. Проверяется отсутствие своих exact
container names/IDs, PID/start, cgroups и cache volume. При ошибке очистки evidence
сохраняется. Приватные локальные инструкции для запуска не нужны.

`bin/build-image` — внутренний helper только локального сценария: он использует
включённый `buildctl` уже подготовленного BuildKit. `bin/build-local` передаёт
ему `SKVOZ_BUILDKIT_CONTAINER` и `SKVOZ_BUILD_OUTPUT` и владеет ограничениями,
проверками и очисткой. Для маркировки clean локального commit задайте
`SOURCE_REVISION=<FULL40SHA>`; без него image остаётся локальным candidate.

Docker image import и получение pinned BuildKit image выполняет host Docker
service вне payload cgroup; это отдельная граница, не whole-host cap. Ошибки
локальных limits/ancestry/OOM/swap или cleanup завершают локальную команду ошибкой.

## Готовый Server image

После qualification trusted main workflow публикует тот же product image в
`ghcr.io/skvoz-project/skvoz-server` с тегами `sha-<FULL40SHA>` и `latest`.
Publisher получает проверенный архив и image ID из Actions artifact, проверяет
`SHA256SUMS`, выполняет `docker load`, затем `docker tag`/`docker push` без сборки.
Для GHCR используется штатный `GITHUB_TOKEN` с `packages: write`; pull request
не публикует образ. Метка `org.opencontainers.image.source` связывает пакет
с репозиторием Server.

Основной [Compose](../compose.yaml) получает готовый образ из GHCR. Тег `latest`
следует успешным сборкам `main`, `sha-<FULL40SHA>` выбирает исходный commit;
для фиксации точного содержимого укажите registry digest `@sha256:<digest>`.
При первой публикации GHCR создаёт пакет с видимостью Private. Для анонимного
`docker pull` выберите Public в настройках пакета, как описано в
[документации GitHub](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).

Отдельные [проверки совместимости](interoperability.md) используют готовый образ
из GHCR по закреплённому digest. Архив служит только для передачи между CI jobs
и явного локального экспорта; в GitHub Releases он не публикуется. PR выполняет
проверки и сохраняет Actions artifact без публикации в GHCR.

```sh
bash bin/build-local deploy <NEW_OUTPUT_DIRECTORY>
```

`bin/export-image` проверяет source/version/revision/platform labels выбранного
image. При заданном revision он также проверяет clean actual HEAD до
`docker image save` точного image ID. В GitHub CI архив сжимается обычным
`gzip -n` на runner. Локальный `bin/build-local` передаёт pinned BuildKit и
проверяемый writable `/output` mapping; в этом режиме сжатие выполняет BusyBox
в ограниченном container. Host Docker save/load остаётся вне payload cgroup.
В output находятся `server-image.tar.gz`, `image-id` и `SHA256SUMS`; checksum
покрывает архив и ID. Это внутренний формат передачи проверенного образа, а не
контракт зависимости клиентских репозиториев. Повторный output не заменяется.
`gzip` metadata детерминированы, но это не обещает равенства independently rebuilt
Docker archive/layers. Image ID, source scope и selected dependency lock
сохраняются отдельно; результат старого image не переносится на новую сборку.
