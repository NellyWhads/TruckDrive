#!/usr/bin/env bash
# Compatible with bash 3.2+ (macOS default), bash 4+, and zsh (run directly or via bash).
set -eu
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

BASE_URL="https://d3ehgyu1hepsur.cloudfront.net"
PREFIX="TruckDrive/"
OUT_DIR="./TruckDrive_download"

JOBS=4
DOWNLOADER="auto"          # auto, aria2c, curl
ARIA2_CONNECTIONS=8
YES=false
UNZIP=false

download_radar=false
download_camera=false
download_lidar=false
download_poses=false
download_calibration=false
download_annotations=false
download_accumulated_gt_depth=false

SCENES=()
ALL_SCENES=false

SCRIPT_NAME="${0##*/}"

print_help() {
  cat <<EOF
Usage:
  ./${SCRIPT_NAME} [options]

Options:
  --out DIR                     Dataset root directory (scene folders are written here).
                                Default: ./TruckDrive_download
  --jobs N                      Parallel file downloads. Default: 4
  --downloader auto|aria2c|curl Downloader. Default: auto
  --aria2-connections N         Connections per file for aria2c. Default: 8
  -y, --yes                     Do not ask before downloading
  --unzip                       Extract downloaded .zip files into the scene layout
                                expected by the dataset viewer (see dataset_viewer/README.md)

  --scene scene_28_1            Download one scene. Can be repeated.
  --all-scenes                  Download all scenes under TruckDrive/.

  --radar                       Download radar.zip
  --camera                      Download camera.zip
  --lidar                       Download lidar.zip
  --poses                       Download poses.zip
  --calibration                 Download calibrations.zip
  --annotations                 Download annotations.zip
  --accumulated-gt-depth        Download accumulated_gt_depth.zip
  --all-modalities              Download all modality zip files

  -h, --help                    Show this help message

Examples:
  ./${SCRIPT_NAME} --out ./TruckDrive_download --all-modalities --scene scene_28_1 --unzip -y

  ./${SCRIPT_NAME} --out ./TruckDrive_download --all-modalities --scene scene_28_1 --jobs 4 --downloader auto

  ./${SCRIPT_NAME} --all-scenes --all-modalities --jobs 4 --downloader aria2c --aria2-connections 8 --unzip -y
EOF
}

# Extract one modality archive into its scene directory (viewer layout).
unzip_modality_archive() {
  local _zip_path="$1"
  python3 - "${_zip_path}" <<'PY'
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

zip_path = Path(sys.argv[1]).resolve()
scene_dir = zip_path.parent
modality = zip_path.stem
scene_name = scene_dir.name
dest = scene_dir / modality

if dest.is_dir() and any(dest.iterdir()):
    print(f"[unzip] skip (exists): {dest}")
    raise SystemExit(0)

if not zip_path.is_file():
    print(f"[unzip] skip (missing): {zip_path}")
    raise SystemExit(0)

def move_into_dest(src: Path, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    shutil.move(str(src), str(dest))


def merge_tree_into_dest(src_dir: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    for child in sorted(src_dir.iterdir()):
        target = dest / child.name
        if target.exists():
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
        shutil.move(str(child), str(target))


print(f"[unzip] {zip_path}")
with tempfile.TemporaryDirectory(prefix="truckdrive_unzip_") as tmp:
    tmp_path = Path(tmp)
    with zipfile.ZipFile(zip_path) as zf:
        if not zf.namelist():
            raise SystemExit(0)
        zf.extractall(tmp_path)

    # Some archives wrap content in <modality>/ or <scene>/<modality>/.
    matches = [
        p for p in tmp_path.rglob(modality) if p.is_dir() and p.name == modality
    ]
    scoped = [p for p in matches if scene_name in p.parts]
    if scoped:
        matches = scoped
    if len(matches) == 1:
        move_into_dest(matches[0], dest)
        raise SystemExit(0)

    direct = tmp_path / modality
    if direct.is_dir():
        move_into_dest(direct, dest)
        raise SystemExit(0)

    # Public TruckDrive zips usually place modality contents at the archive root
    # (e.g. radar.zip -> conti542/..., calibrations.zip -> calib_*.json).
    if any(tmp_path.iterdir()):
        merge_tree_into_dest(tmp_path, dest)
        raise SystemExit(0)

print(f"[unzip] warning: archive is empty: {zip_path}", file=sys.stderr)
raise SystemExit(1)
PY
}

unzip_downloaded_archives() {
  local _key
  local _zip_path
  local _status=0

  echo
  echo "Extracting archives for dataset viewer layout..."

  for _key in "$@"; do
    case "${_key}" in
      *.zip) ;;
      *) continue ;;
    esac

    _zip_path="$(local_path_for_key "${_key}")"
    if ! unzip_modality_archive "${_zip_path}"; then
      _status=1
    fi
  done

  return "${_status}"
}

# Map an S3 object key to a local path under OUT_DIR (strip the remote TruckDrive/ prefix).
local_path_for_key() {
  local _key="$1"
  local _relative="${_key}"

  case "${_relative}" in
    "${PREFIX}"*) _relative="${_relative#${PREFIX}}" ;;
    TruckDrive/*) _relative="${_relative#TruckDrive/}" ;;
  esac

  printf "%s/%s" "${OUT_DIR}" "${_relative}"
}

# Portable replacement for bash 4+ mapfile / readarray (reads newline-delimited lines into an array).
read_lines_into() {
  local _arr_name="$1"
  local _line
  eval "${_arr_name}=()"
  while IFS= read -r _line || [ -n "${_line}" ]; do
    case "${_line}" in
      "") ;;
      *) eval "${_arr_name}+=(\"\${_line}\")" ;;
    esac
  done
}

is_wanted_modality() {
  local _filename="$1"
  local _f
  for _f in "${MODALITY_FILES[@]}"; do
    if [ "${_filename}" = "${_f}" ]; then
      return 0
    fi
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;

    --jobs)
      JOBS="$2"
      shift 2
      ;;

    --downloader)
      DOWNLOADER="$2"
      shift 2
      ;;

    --aria2-connections)
      ARIA2_CONNECTIONS="$2"
      shift 2
      ;;

    -y|--yes)
      YES=true
      shift
      ;;

    --unzip)
      UNZIP=true
      shift
      ;;

    --scene)
      SCENES+=("$2")
      shift 2
      ;;

    --all-scenes)
      ALL_SCENES=true
      shift
      ;;

    --radar)
      download_radar=true
      shift
      ;;

    --camera)
      download_camera=true
      shift
      ;;

    --lidar)
      download_lidar=true
      shift
      ;;

    --poses)
      download_poses=true
      shift
      ;;

    --calibration|--calibrations)
      download_calibration=true
      shift
      ;;

    --annotations)
      download_annotations=true
      shift
      ;;

    --accumulated-gt-depth)
      download_accumulated_gt_depth=true
      shift
      ;;

    --all-modalities)
      download_radar=true
      download_camera=true
      download_lidar=true
      download_poses=true
      download_calibration=true
      download_annotations=true
      download_accumulated_gt_depth=true
      shift
      ;;

    -h|--help)
      print_help
      exit 0
      ;;

    --upzip)
      echo "Unknown option: --upzip (did you mean --unzip?)"
      print_help
      exit 1
      ;;

    *)
      echo "Unknown option: $1"
      print_help
      exit 1
      ;;
  esac
done

if [[ "$download_radar" != true && \
      "$download_camera" != true && \
      "$download_lidar" != true && \
      "$download_poses" != true && \
      "$download_calibration" != true && \
      "$download_annotations" != true && \
      "$download_accumulated_gt_depth" != true ]]; then
  echo "No modality selected."
  echo "Use --all-modalities or one of:"
  echo "  --radar --camera --lidar --poses --calibration --annotations --accumulated-gt-depth"
  exit 1
fi

case "$DOWNLOADER" in
  auto|aria2c|curl)
    ;;
  *)
    echo "Invalid --downloader: $DOWNLOADER"
    echo "Use: auto, aria2c, or curl"
    exit 1
    ;;
esac

urlencode_component() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

urlencode_path() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe="/"))
PY
}

list_keys_for_prefix() {
  local prefix="$1"
  local marker=""
  local encoded_prefix
  encoded_prefix="$(urlencode_component "$prefix")"
  local tmpfile
  tmpfile="/tmp/truckdrive_list_$$_$RANDOM.xml"

  while true; do
    local url="${BASE_URL}/?prefix=${encoded_prefix}&delimiter="

    if [[ -n "$marker" ]]; then
      local encoded_marker
      encoded_marker="$(urlencode_component "$marker")"
      url="${url}&marker=${encoded_marker}"
    fi

    curl -fsSL "$url" > "$tmpfile" 2>/dev/null || {
      rm -f "$tmpfile"
      return 1
    }

    local parsed
    parsed="$(python3 << PYEOF
import xml.etree.ElementTree as ET

try:
    tree = ET.parse("$tmpfile")
    root = tree.getroot()
    ns = 'http://s3.amazonaws.com/doc/2006-03-01/'

    for elem in root.findall('.//{' + ns + '}Key'):
        if elem.text:
            print("KEY\t" + elem.text)

    marker_elem = root.find('.//{' + ns + '}NextMarker')
    if marker_elem is not None and marker_elem.text:
        print("MARKER\t" + marker_elem.text)
except Exception:
    pass
PYEOF
)"

    printf "%s\n" "$parsed" | awk -F '\t' '$1 == "KEY" {print $2}'

    marker="$(printf "%s\n" "$parsed" | awk -F '\t' '$1 == "MARKER" {print $2}' | tail -n 1)"

    rm -f "$tmpfile"

    if [[ -z "$marker" ]]; then
      break
    fi
  done
}

list_prefixes_for_prefix() {
  local prefix="$1"
  local delimiter="${2:-/}"
  local marker=""
  local encoded_prefix
  encoded_prefix="$(urlencode_component "$prefix")"
  local encoded_delimiter
  encoded_delimiter="$(urlencode_component "$delimiter")"
  local tmpfile
  tmpfile="/tmp/truckdrive_prefixes_$$_$RANDOM.xml"

  while true; do
    local url="${BASE_URL}/?prefix=${encoded_prefix}&delimiter=${encoded_delimiter}"

    if [[ -n "$marker" ]]; then
      local encoded_marker
      encoded_marker="$(urlencode_component "$marker")"
      url="${url}&marker=${encoded_marker}"
    fi

    curl -fsSL "$url" > "$tmpfile" 2>/dev/null || {
      rm -f "$tmpfile"
      return 1
    }

    local parsed
    parsed="$(python3 << PYEOF
import xml.etree.ElementTree as ET

try:
    tree = ET.parse("$tmpfile")
    root = tree.getroot()
    ns = 'http://s3.amazonaws.com/doc/2006-03-01/'

    for elem in root.findall('.//{' + ns + '}CommonPrefixes'):
        prefix_elem = elem.find('{' + ns + '}Prefix')
        if prefix_elem is not None and prefix_elem.text:
            print("PREFIX\t" + prefix_elem.text)

    marker_elem = root.find('.//{' + ns + '}NextMarker')
    if marker_elem is not None and marker_elem.text:
        print("MARKER\t" + marker_elem.text)
except Exception:
    pass
PYEOF
)"

    printf "%s\n" "$parsed" | awk -F '\t' '$1 == "PREFIX" {print $2}'

    marker="$(printf "%s\n" "$parsed" | awk -F '\t' '$1 == "MARKER" {print $2}' | tail -n 1)"

    rm -f "$tmpfile"

    if [[ -z "$marker" ]]; then
      break
    fi
  done
}

download_key_curl() {
  local key="$1"
  local encoded_key
  encoded_key="$(urlencode_path "$key")"

  local url="${BASE_URL}/${encoded_key}"
  local dst
  dst="$(local_path_for_key "$key")"
  local part="${dst}.part"

  mkdir -p "$(dirname "$dst")"

  if [[ -f "$dst" ]]; then
    echo "[skip] ${key}"
    return 0
  fi

  echo "[curl] ${key}"

  curl -fL \
    --retry 8 \
    --retry-delay 2 \
    --retry-connrefused \
    --connect-timeout 30 \
    --speed-limit 1024 \
    --speed-time 60 \
    --continue-at - \
    -o "$part" \
    "$url"

  mv -f "$part" "$dst"
}

download_with_curl_parallel() {
  local _key
  local _running=0

  for _key in "$@"; do
    while [ "${_running}" -ge "${JOBS}" ]; do
      if wait -n 2>/dev/null; then
        _running=$((_running - 1))
      else
        wait || true
        _running=0
      fi
    done
    download_key_curl "${_key}" &
    _running=$((_running + 1))
  done
  wait
}

download_with_aria2c() {
  local input_file
  input_file="$(mktemp "${TMPDIR:-/tmp}/truckdrive_aria2.XXXXXX")"

  local queued=0

  for key in "$@"; do
    local encoded_key
    encoded_key="$(urlencode_path "$key")"

    local url="${BASE_URL}/${encoded_key}"
    local dst
    dst="$(local_path_for_key "$key")"
    local dir
    local base

    dir="$(dirname "$dst")"
    base="$(basename "$dst")"

    mkdir -p "$dir"

    if [[ -f "$dst" ]]; then
      echo "[skip] ${key}"
      continue
    fi

    {
      printf "%s\n" "$url"
      printf "  dir=%s\n" "$dir"
      printf "  out=%s.part\n" "$base"
    } >> "$input_file"

    queued=$((queued + 1))
  done

  if [[ "$queued" -eq 0 ]]; then
    rm -f "$input_file"
    return 0
  fi

  echo "[aria2c] queued ${queued} files"
  echo "[aria2c] jobs=${JOBS}, connections-per-file=${ARIA2_CONNECTIONS}"

  set +e
  aria2c \
    --input-file="$input_file" \
    --continue=true \
    --max-concurrent-downloads="$JOBS" \
    --max-connection-per-server="$ARIA2_CONNECTIONS" \
    --split="$ARIA2_CONNECTIONS" \
    --min-split-size=16M \
    --file-allocation=none \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --max-tries=8 \
    --retry-wait=2 \
    --timeout=60 \
    --connect-timeout=30 \
    --summary-interval=30
  local status=$?
  set -e

  rm -f "$input_file"

  for key in "$@"; do
    local dst
    dst="$(local_path_for_key "$key")"
    local part="${dst}.part"

    if [[ -f "$part" && ! -f "${part}.aria2" ]]; then
      mv -f "$part" "$dst"
    fi
  done

  return "$status"
}

echo "TruckDrive downloader"
echo "Remote: ${BASE_URL}/?prefix=${PREFIX}"
echo "Output: ${OUT_DIR}"
echo "Jobs: ${JOBS}"
echo "Downloader: ${DOWNLOADER}"
echo "Unzip: ${UNZIP}"
echo

MODALITY_FILES=()

[[ "$download_radar" == true ]] && MODALITY_FILES+=("radar.zip")
[[ "$download_camera" == true ]] && MODALITY_FILES+=("camera.zip")
[[ "$download_lidar" == true ]] && MODALITY_FILES+=("lidar.zip")
[[ "$download_poses" == true ]] && MODALITY_FILES+=("poses.zip")
[[ "$download_calibration" == true ]] && MODALITY_FILES+=("calibrations.zip")
[[ "$download_annotations" == true ]] && MODALITY_FILES+=("annotations.zip")
[[ "$download_accumulated_gt_depth" == true ]] && MODALITY_FILES+=("accumulated_gt_depth.zip")

SCENES_TO_SCAN=()

if [[ "${#SCENES[@]}" -gt 0 ]]; then
  SCENES_TO_SCAN=("${SCENES[@]}")
elif [[ "${ALL_SCENES}" == true ]]; then
  echo "Listing all scenes under ${PREFIX}"
  read_lines_into SCENES_TO_SCAN < <(
    list_prefixes_for_prefix "${PREFIX}" "/" \
      | grep -o "scene_[^/]*" \
      | sort -u
  )
else
  echo "No explicit --scene provided; listing all scenes under ${PREFIX}"
  read_lines_into SCENES_TO_SCAN < <(
    list_prefixes_for_prefix "${PREFIX}" "/" \
      | grep -o "scene_[^/]*" \
      | sort -u
  )
fi

if [[ "${#SCENES_TO_SCAN[@]}" -eq 0 ]]; then
  echo "No scenes found."
  exit 1
fi

SELECTED_KEYS=()

for scene_name in "${SCENES_TO_SCAN[@]}"; do
  scene_full_prefix="${PREFIX}${scene_name}/"

  echo "[list] ${scene_full_prefix}"
  SCENE_FILES=()
  read_lines_into SCENE_FILES < <(list_keys_for_prefix "${scene_full_prefix}")

  for file in "${SCENE_FILES[@]}"; do
    filename="$(basename "${file}")"

    if is_wanted_modality "${filename}"; then
      SELECTED_KEYS+=("${file}")
    fi
  done
done

if [[ "${#SELECTED_KEYS[@]}" -gt 0 ]]; then
  SORTED_KEYS=()
  read_lines_into SORTED_KEYS < <(printf "%s\n" "${SELECTED_KEYS[@]}" | sort -u)
  SELECTED_KEYS=("${SORTED_KEYS[@]}")
fi

if [[ "${#SELECTED_KEYS[@]}" -eq 0 ]]; then
  echo "No files matched the selected scenes/modalities."
  echo
  echo "Expected remote keys like:"
  echo "  TruckDrive/scene_28_1/radar.zip"
  echo "Local layout under --out:"
  echo "  scene_28_1/radar.zip"
  exit 1
fi

echo
echo "Matched ${#SELECTED_KEYS[@]} files:"
printf "  %s\n" "${SELECTED_KEYS[@]}"
echo

if [[ "${YES}" != true ]]; then
  if [[ "${UNZIP}" == true ]]; then
    printf "Proceed with download and unzip? [y/N] "
  else
    printf "Proceed with download? [y/N] "
  fi
  read -r answer

  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

if [[ "$DOWNLOADER" == "auto" ]]; then
  if command -v aria2c >/dev/null 2>&1; then
    DOWNLOADER="aria2c"
  else
    DOWNLOADER="curl"
  fi
fi

echo
echo "Using downloader: ${DOWNLOADER}"
echo

case "$DOWNLOADER" in
  aria2c)
    if ! command -v aria2c >/dev/null 2>&1; then
      echo "aria2c is not installed. Install it or use --downloader curl."
      exit 1
    fi
    download_with_aria2c "${SELECTED_KEYS[@]}"
    ;;

  curl)
    download_with_curl_parallel "${SELECTED_KEYS[@]}"
    ;;
esac

if [[ "${UNZIP}" == true ]]; then
  if ! unzip_downloaded_archives "${SELECTED_KEYS[@]}"; then
    exit 1
  fi
fi

echo
echo "Done."
echo "Files saved under: ${OUT_DIR}"
if [[ "${UNZIP}" == true ]]; then
  echo "Viewer --root-dir: ${OUT_DIR}"
  echo "Example:"
  echo "  cd dataset_viewer && uv run python entrypoint.py --root-dir ${OUT_DIR} --recording scene_28_1"
fi