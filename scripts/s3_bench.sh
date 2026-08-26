#!/usr/bin/env bash
#
# s3_bench.sh — сравнение latency / upload / download для S3-бакетов
# с задаваемыми при запуске бакетами и набором размеров файлов.
#
# Требования: aws cli (настроенный), curl, dd, awk, bc
#
# ПРИМЕРЫ ЗАПУСКА:
#
#   Один бакет, несколько размеров:
#     ./s3_bench.sh --bucket my-bucket:eu-west-1 --sizes 1,10,100
#
#   Несколько бакетов (флаг --bucket можно повторять), несколько размеров:
#     ./s3_bench.sh \
#       --bucket bucket-us:us-east-1 \
#       --bucket bucket-eu:eu-west-1 \
#       --sizes 1,10,50,200 \
#       --label eu-client-1
#
#   Полный список опций: ./s3_bench.sh --help
#
set -euo pipefail

### ------------------- ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ ------------------- ###

HOST_LABEL="$(hostname)"
LATENCY_SAMPLES=15
BUCKETS=()      # элементы вида "bucket:region"
SIZES_MB=()     # список размеров файлов в МБ
OUTPUT_CSV=""

usage() {
  cat <<EOF
Использование: $0 --bucket NAME:REGION [--bucket NAME:REGION ...] --sizes SIZE1,SIZE2,...

Обязательные параметры:
  --bucket NAME:REGION   Бакет и его регион, например: my-bucket:eu-west-1
                         Можно указывать несколько раз для сравнения бакетов.
  --sizes LIST           Список размеров тестовых файлов в МБ через запятую,
                         например: 1,10,100,500

Опциональные параметры:
  --label LABEL          Метка текущего хоста для CSV (по умолчанию: hostname)
  --latency-samples N    Число HEAD-запросов для замера латентности (по умолчанию: 15)
  --output FILE          Имя выходного CSV (по умолчанию: генерируется автоматически)
  -h, --help             Показать эту справку

Пример:
  $0 --bucket my-bucket:eu-west-1 --bucket other-bucket:us-east-1 \\
     --sizes 1,10,100 --label eu-client-1
EOF
  exit 1
}

### ------------------- ПАРСИНГ АРГУМЕНТОВ ------------------- ###

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)
      [[ -n "${2:-}" ]] || { echo "Ошибка: --bucket требует значение NAME:REGION"; usage; }
      BUCKETS+=("$2")
      shift 2
      ;;
    --sizes)
      [[ -n "${2:-}" ]] || { echo "Ошибка: --sizes требует список чисел через запятую"; usage; }
      IFS=',' read -ra SIZES_MB <<< "$2"
      shift 2
      ;;
    --label)
      HOST_LABEL="$2"
      shift 2
      ;;
    --latency-samples)
      LATENCY_SAMPLES="$2"
      shift 2
      ;;
    --output)
      OUTPUT_CSV="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Неизвестный аргумент: $1"
      usage
      ;;
  esac
done

if [[ ${#BUCKETS[@]} -eq 0 ]]; then
  echo "Ошибка: нужно указать хотя бы один --bucket NAME:REGION"
  usage
fi

if [[ ${#SIZES_MB[@]} -eq 0 ]]; then
  echo "Ошибка: нужно указать --sizes с одним или несколькими размерами (МБ)"
  usage
fi

# Валидация формата bucket:region и размеров
for entry in "${BUCKETS[@]}"; do
  if [[ "$entry" != *:* ]]; then
    echo "Ошибка: '${entry}' не соответствует формату NAME:REGION"
    exit 1
  fi
done
for sz in "${SIZES_MB[@]}"; do
  if ! [[ "$sz" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: размер '${sz}' в --sizes должен быть целым числом (МБ)"
    exit 1
  fi
done

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
[[ -n "${OUTPUT_CSV}" ]] || OUTPUT_CSV="s3_bench_${HOST_LABEL}_${TIMESTAMP}.csv"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

### ------------------- ПРОВЕРКА ЗАВИСИМОСТЕЙ ------------------- ###

for cmd in aws curl bc dd awk; do
  command -v "$cmd" >/dev/null || { echo "Не найдена утилита: $cmd"; exit 1; }
done

### ------------------- ГЕНЕРАЦИЯ ТЕСТОВЫХ ФАЙЛОВ ------------------- ###

echo "== Генерирую тестовые файлы: ${SIZES_MB[*]} MB =="
declare -A TESTFILES
for sz in "${SIZES_MB[@]}"; do
  f="${WORKDIR}/testfile_${sz}mb.bin"
  dd if=/dev/urandom of="${f}" bs=1M count="${sz}" status=none
  TESTFILES["${sz}"]="${f}"
done

echo "host_label,bucket,bucket_region,size_mb,latency_avg_ms,latency_min_ms,latency_max_ms,upload_mbps,download_mbps,timestamp" > "${OUTPUT_CSV}"

### ------------------- ФУНКЦИИ ------------------- ###

measure_latency() {
  local bucket="$1" region="$2"
  local url="https://${bucket}.s3.${region}.amazonaws.com/"
  local samples=()

  for _ in $(seq 1 "${LATENCY_SAMPLES}"); do
    local t
    t=$(curl -s -o /dev/null -w "%{time_total}" \
        --request HEAD "${url}" --max-time 10 || echo "")
    [[ -n "$t" ]] && samples+=("$t")
  done

  if [[ ${#samples[@]} -eq 0 ]]; then
    echo "NA,NA,NA"
    return
  fi

  printf '%s\n' "${samples[@]}" | awk '
    { v=$1*1000; sum+=v; n++; if(min==""||v<min) min=v; if(v>max) max=v }
    END { if(n>0) printf "%.1f,%.1f,%.1f", sum/n, min, max; else print "NA,NA,NA" }'
}

measure_upload() {
  local bucket="$1" file="$2" size_mb="$3" key="$4"
  local start end elapsed mbps

  start=$(date +%s.%N)
  if ! aws s3 cp "${file}" "s3://${bucket}/${key}" --only-show-errors >/dev/null 2>&1; then
    echo "NA"
    return
  fi
  end=$(date +%s.%N)

  elapsed=$(echo "${end} - ${start}" | bc)
  mbps=$(echo "scale=2; (${size_mb} * 8) / ${elapsed}" | bc)
  echo "${mbps}"
}

measure_download() {
  local bucket="$1" size_mb="$2" key="$3"
  local dest="${WORKDIR}/downloaded_$(basename "${key}")"
  local start end elapsed mbps

  start=$(date +%s.%N)
  if ! aws s3 cp "s3://${bucket}/${key}" "${dest}" --only-show-errors >/dev/null 2>&1; then
    echo "NA"
    return
  fi
  end=$(date +%s.%N)

  elapsed=$(echo "${end} - ${start}" | bc)
  mbps=$(echo "scale=2; (${size_mb} * 8) / ${elapsed}" | bc)
  echo "${mbps}"
  rm -f "${dest}"
}

cleanup_remote() {
  local bucket="$1" key="$2"
  aws s3 rm "s3://${bucket}/${key}" --only-show-errors >/dev/null 2>&1 || true
}

### ------------------- ОСНОВНОЙ ЦИКЛ ------------------- ###

for entry in "${BUCKETS[@]}"; do
  bucket="${entry%%:*}"
  region="${entry##*:}"

  echo ""
  echo "=== Бакет: ${bucket} (регион: ${region}) ==="
  echo "  -> латентность (${LATENCY_SAMPLES} HEAD-запросов)..."
  IFS=',' read -r lat_avg lat_min lat_max <<< "$(measure_latency "${bucket}" "${region}")"
  echo "     avg=${lat_avg}ms min=${lat_min}ms max=${lat_max}ms"

  for sz in "${SIZES_MB[@]}"; do
    file="${TESTFILES[${sz}]}"
    key="bench/${HOST_LABEL}_${TIMESTAMP}_${sz}mb.bin"

    echo "  -- размер ${sz}MB --"
    echo "     upload..."
    upload_mbps=$(measure_upload "${bucket}" "${file}" "${sz}" "${key}")
    echo "        ${upload_mbps} Mbps"

    echo "     download..."
    download_mbps=$(measure_download "${bucket}" "${sz}" "${key}")
    echo "        ${download_mbps} Mbps"

    cleanup_remote "${bucket}" "${key}"

    echo "${HOST_LABEL},${bucket},${region},${sz},${lat_avg},${lat_min},${lat_max},${upload_mbps},${download_mbps},${TIMESTAMP}" >> "${OUTPUT_CSV}"
  done
done

echo ""
echo "== Готово. Результаты сохранены в ${OUTPUT_CSV} =="
echo ""
column -s, -t "${OUTPUT_CSV}"

### ------------------- СРАВНЕНИЕ РЕЗУЛЬТАТОВ С РАЗНЫХ ХОСТОВ -------------------
#
# 1. Запускайте с уникальным --label на каждом хосте:
#      ./s3_bench.sh --bucket my-bucket:eu-west-1 --sizes 1,10,100 --label us-client-1
#      ./s3_bench.sh --bucket my-bucket:eu-west-1 --sizes 1,10,100 --label eu-client-1
#
# 2. Объедините CSV с разных хостов:
#      head -1 s3_bench_us-client-1_*.csv > combined.csv
#      tail -n +2 -q s3_bench_*.csv >> combined.csv
#
# 3. Сравните throughput по размеру файла и хосту:
#      awk -F, 'NR>1 {printf "%-15s %-25s %6s MB  up=%-8s down=%-8s Mbps\n", \
#                $1,$2,$4,$8,$9}' combined.csv | sort
#
#    Обычно на маленьких файлах доминирует латентность (overhead запроса),
#    а на больших — реальная пропускная способность канала. Если Mbps
#    почти не растёт с увеличением размера файла — узкое место, скорее
#    всего, не в сети, а в самом клиенте/диске/троттлинге S3.
