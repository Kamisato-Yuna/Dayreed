#!/usr/bin/env bash

set -euo pipefail

APP_BUNDLE_ID="YunaBuild.Dayreed"
HELPER_RELATIVE_PATH="Contents/Helpers/dayreed"
SCRIPT_NAME="$(basename "$0")"
CLI_NAME="dayreed"
DEFAULT_BIN_DIR="${HOME}/.local/bin"

print_usage() {
  cat <<'USAGE'
用法：
  install_cli.sh install --app <Dayreed.app> [--bin-dir <路径>]
  install_cli.sh uninstall --app <Dayreed.app> [--bin-dir <路径>]

说明：
  - 通过符号链接安装/移除 CLI `dayreed`。
  - 安装目录默认为 ~/.local/bin，可通过 --bin-dir 覆盖。
  - 安装/卸载前会校验 App 身份、Helper 可执行性和版本 JSON。
  - 不会写入 /usr/local，也不会修改任何 shell 配置。
USAGE
}

error() {
  echo "$SCRIPT_NAME: $*" >&2
  exit 1
}

resolve_path() {
  local path="$1"
  python3 - "$path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
}

validate_bin_dir() {
  local bin_dir="$1"
  if [[ "$bin_dir" == "/usr/local" || "$bin_dir" == /usr/local/* ]]; then
    error "禁止安装到 /usr/local 下：${bin_dir}"
  fi
}

validate_app() {
  local app_path="$1"

  if [[ ! -d "$app_path" ]]; then
    error "未找到 App 目录：${app_path}"
  fi
  if [[ ! "$app_path" == *.app ]]; then
    error "请提供 .app 路径：${app_path}"
  fi

  local info_plist="${app_path}/Contents/Info.plist"
  if [[ ! -f "$info_plist" ]]; then
    error "未找到 Info.plist：${info_plist}"
  fi

  local bundle_id
  if ! bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null)"; then
    error "无法读取 CFBundleIdentifier：${info_plist}"
  fi
  if [[ "$bundle_id" != "$APP_BUNDLE_ID" ]]; then
    error "Bundle ID 不匹配：${bundle_id}（期望 ${APP_BUNDLE_ID}）"
  fi

  local plist_version
  if ! plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null)"; then
    error "无法读取 CFBundleShortVersionString：${info_plist}"
  fi

  local plist_build
  if ! plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null)"; then
    error "无法读取 CFBundleVersion：${info_plist}"
  fi

  local helper_path="${app_path}/${HELPER_RELATIVE_PATH}"
  if [[ ! -f "$helper_path" ]]; then
    error "未找到 Helper：${helper_path}"
  fi
  if [[ ! -x "$helper_path" ]]; then
    error "Helper 不可执行：${helper_path}"
  fi

  local version_json
  if ! version_json="$("$helper_path" version --json)"; then
    error "无法执行 Helper 的 version --json：${helper_path}"
  fi

  if ! python3 - "$version_json" "$APP_BUNDLE_ID" "$plist_version" "$plist_build" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
required_keys = {"name", "version", "build", "bundleIdentifier", "minimumSystemVersion"}
missing = sorted(required_keys - set(payload.keys()))
if missing:
    raise SystemExit(f"version --json 缺少字段：{', '.join(missing)}")

if payload.get("bundleIdentifier") != sys.argv[2]:
    raise SystemExit("version --json 中的 Bundle ID 不匹配")

if not isinstance(payload.get("build"), int):
    raise SystemExit("version --json 的 build 类型必须是整数")

if not isinstance(payload.get("version"), str):
    raise SystemExit("version --json 的 version 类型必须是字符串")

if payload.get("version") != sys.argv[3]:
    raise SystemExit("version --json 的 version 与 App 不匹配")

if str(payload.get("build")) != sys.argv[4]:
    raise SystemExit("version --json 的 build 与 App 不匹配")

if payload.get("minimumSystemVersion") != "26.0":
    raise SystemExit("minimumSystemVersion 解析失败")
PY
  then
    error "Helper version --json 校验失败：${helper_path}"
  fi
}

install_cli() {
  local app_path="$1"
  local bin_dir="$2"
  local link_path="${bin_dir}/${CLI_NAME}"
  local helper_path="${app_path}/${HELPER_RELATIVE_PATH}"
  local expected_target
  local existing_target

  expected_target="$(resolve_path "$helper_path")"

  if [[ -L "$link_path" ]]; then
    existing_target="$(resolve_path "$link_path")"
    if [[ "$existing_target" == "$expected_target" ]]; then
      echo "已存在同名链接且目标一致，跳过安装：${link_path}"
      return 0
    fi
    error "链接已存在但指向其它目标：${link_path}"
  fi
  if [[ -e "$link_path" ]]; then
    error "安装目标已被占用且不是符号链接：${link_path}"
  fi

  ln -s "$helper_path" "$link_path"
  echo "已安装 CLI：${link_path} -> ${helper_path}"
}

uninstall_cli() {
  local app_path="$1"
  local bin_dir="$2"
  local link_path="${bin_dir}/${CLI_NAME}"
  local helper_path="${app_path}/${HELPER_RELATIVE_PATH}"
  local expected_target
  local existing_target

  if [[ ! -L "$link_path" ]]; then
    echo "无需卸载：未发现 ${link_path}"
    return 0
  fi

  expected_target="$(resolve_path "$helper_path")"
  existing_target="$(resolve_path "$link_path")"
  if [[ "$existing_target" != "$expected_target" ]]; then
    error "当前链接非本 App 的 CLI，不执行移除：${link_path}"
  fi

  rm -f "$link_path"
  echo "已移除 CLI 链接：${link_path}"
}

main() {
  if [[ $# -lt 1 ]]; then
    print_usage
    error "缺少操作命令（install/uninstall）"
  fi

  local mode="$1"
  shift
  if [[ "$mode" == "--help" || "$mode" == "-h" ]]; then
    print_usage
    return 0
  fi

  if [[ "$mode" != "install" && "$mode" != "uninstall" ]]; then
    print_usage
    error "未知操作：${mode}"
  fi

  local app_path=""
  local bin_dir="$DEFAULT_BIN_DIR"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app)
        if [[ $# -lt 2 ]]; then
          error "--app 需要一个参数"
        fi
        app_path="$2"
        shift 2
        ;;
      --bin-dir)
        if [[ $# -lt 2 ]]; then
          error "--bin-dir 需要一个参数"
        fi
        bin_dir="$2"
        shift 2
        ;;
      --help|-h)
        print_usage
        return 0
        ;;
      *)
        error "未知参数：${1}"
        ;;
    esac
  done

  if [[ -z "$app_path" ]]; then
    error "缺少 --app"
  fi

  bin_dir="$(resolve_path "$bin_dir")"
  validate_bin_dir "$bin_dir"
  validate_app "$app_path"
  app_path="$(resolve_path "$app_path")"

  if [[ "$mode" == "install" ]]; then
    mkdir -p "$bin_dir"
  fi

  case "$mode" in
    install) install_cli "$app_path" "$bin_dir" ;;
    uninstall) uninstall_cli "$app_path" "$bin_dir" ;;
  esac
}

main "$@"
