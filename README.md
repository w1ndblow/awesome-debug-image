# awesome-debug-image

Docker-образ с набором инструментов для отладки рабочих нагрузок и узлов Kubernetes через
[`kubectl debug`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_debug/).

`kubectl debug` позволяет не менять манифесты и не пересоздавать под: отладочный контейнер
запускается рядом с приложением (ephemeral container) или на самом узле, и в нём сразу доступны
профилировщики, трассировка и сетевые утилиты — именно для этого предназначен этот образ.

Образ публикуется в Docker Hub (`windblow/awesome-debug`) и GitHub Container Registry
(`ghcr.io/<owner>/awesome-debug`), сборка релиза происходит автоматически по тегу `v*`.

## Что внутри

| Категория | Инструменты |
|---|---|
| Трассировка и профилирование | `bpftrace`, BCC-утилиты (`bpfcc-tools`), `perf` (linux-perf), FlameGraph (`flamegraph.pl` и др.), `pmc-cloud-tools` |
| Мониторинг системы | `sysstat` (`iostat`, `mpstat`, `pidstat`, …), `irqtop` |
| Прочее | `git`, `curl`, `bc`, `fish` (шелл по умолчанию), `systemtap-sdt-dev`, `libboost-all-dev` |
| Облако / S3 | AWS CLI v2, `s3_bench.sh` — бенчмарк латентности и throughput S3-бакетов |

## Сборка

Локальная сборка из исходников:

```bash
docker build -t awesome-debug:local .
```

Сборка мультиархитектурной версии и публикация (для ручной публикации; в CI это делает
`release.yml`):

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <registry>/awesome-debug:v0.1.0 \
  --push .
```

## Тестирование

Тесты написаны на [pytest](https://docs.pytest.org/) + [testinfra](https://testinfra.readthedocs.io/).
Они собирают образ из локального `Dockerfile`, поднимают из него контейнер и проверяют, что все
необходимые утилиты (`aws`, `curl`, `dd`, `awk`, `bc`) доступны в `$PATH`.

```bash
pip install pytest testinfra
pytest tests/ -v
```

> Требуется запущенный Docker на машине, где прогоняются тесты.

## Использование

### Отладка пода (ephemeral container)

Запускает отладочный контейнер в уже работающем поде — без рестарта приложения:

```bash
# Интерактивная отладочная сессия в поде mypod
kubectl debug mypod -it --image=windblow/awesome-debug:v0.1.0

# То же, но с явным именем отладочного контейнера
kubectl debug --image=windblow/awesome-debug:v0.1.0 -c debugger mypod

# Отладочный контейнер с общим process namespace с контейнером app
# (видны процессы приложения, работает perf/strace по PID)
kubectl debug mypod -it --image=windblow/awesome-debug:v0.1.0 --target=app -c debugger

# Передать переменные окружения (например, креды AWS)
kubectl debug mypod -it --image=windblow/awesome-debug:v0.1.0 \
  --env AWS_ACCESS_KEY_ID=... --env AWS_SECRET_ACCESS_KEY=... --env AWS_DEFAULT_REGION=...
```

> Ephemeral containers доступны в Kubernetes начиная с v1.23 (GA). На более старых кластерах
> используйте вариант с `--copy-to`.

### Отладка через копию пода

```bash
# Копия mypod с добавленным отладочным контейнером
kubectl debug mypod -it --image=windblow/awesome-debug:v0.1.0 --copy-to=my-debugger

# Копия mypod, в которой все контейнеры заменены на отладочный образ
kubectl debug mypod --copy-to=my-debugger --set-image=*=windblow/awesome-debug:v0.1.0

# Копия с добавленным отладочным контейнером и заменой образа конкретного контейнера
kubectl debug mypod -it --copy-to=my-debugger \
  --image=windblow/awesome-debug:v0.1.0 \
  --set-image=app=app:debug,sidecar=sidecar:debug
```

Полезные опции для `--copy-to`: `--same-node` (разместить копию на том же узле),
`--replace` (удалить исходный под), `--share-processes` (по умолчанию включён).

### Отладка узла

Контейнер запускается в host namespaces (network, pid), а файловая система узла монтируется
в `/host`:

```bash
kubectl debug node/mynode -it --image=windblow/awesome-debug:v0.1.0

# примеры внутри: посмотреть логи узла, нагрузку на CPU/IRQ
ls /host/var/log/pods
pidstat 1 10
irqtop
```

> Для доступа к ядру (`perf`, bpftrace и т.п.) может потребоваться расширенный профиль:
> `--profile=sysadmin` или `--profile=netadmin`. Доступные значения: `general` (по умолчанию),
> `baseline`, `restricted`, `netadmin`, `sysadmin`.

### Пример: CPU-флеймграф процесса

```bash
# 1. Запустить отладочный контейнер с общим process namespace
kubectl debug mypod -it --image=windblow/awesome-debug:v0.1.0 --target=app -c debugger

# 2. Внутри контейнера: снять профиль и построить флеймграф
PID=$(pgrep -f my-app)
perf record -F 99 -p "$PID" -g -- sleep 30
perf script | stackcollapse-perf.pl | flamegraph.pl > /tmp/flame.svg

# 3. Забрать файл на локальную машину
kubectl cp mypod:/tmp/flame.svg ./flame.svg -c debugger
```

### Пример: бенчмарк S3

Внутри отладочного контейнера (нужны настроенные креды AWS, см. `--env` выше):

```bash
s3_bench.sh --bucket my-bucket:eu-west-1 --bucket other-bucket:us-east-1 --sizes 1,10,100
```

Скрипт замеряет латентность (HEAD-запросы), скорость upload/download для каждого размера файла
и пишет результаты в CSV. Запуск с разных хостов с разными `--label` позволяет сравнить
регионы/клиентов (подробнее — `s3_bench.sh --help` и комментарии в `scripts/s3_bench.sh`).

## CI и релизы

В `.github/workflows` два workflow:

- `docker-image.yml` — сборка образа при пуше в `main` и в pull request'ах.
- `release.yml` — срабатывает при пуше тега `v*`: прогоняет тесты, собирает образ и публикует
  его с этим тегом и `latest` в Docker Hub и ghcr.io.

Выпуск новой версии:

```bash
git tag v0.2.0
git push --tags origin
```

Для публикации в Docker Hub в секретах репозитория должен быть настроен `DOCKERHUBPASS`
(публикация в ghcr.io выполняется автоматически через `GITHUB_TOKEN`).

## Лицензия

Материалы распространяются по лицензии [CC BY 4.0](./LICENSE).

Вы можете свободно использовать, изменять и распространять этот образ и его части, но при
использовании/распространении просьба указывать авторство и давать ссылку на исходный
репозиторий — это требование лицензии (раздел 3(a)), и это же является желательным поведением
со стороны автора.
