#!/usr/bin/env bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

LOG_INFO_PREFIX="${LOG_INFO_PREFIX:-log}"
LOG_WARN_PREFIX="${LOG_WARN_PREFIX:-warn}"
LOG_ERROR_PREFIX="${LOG_ERROR_PREFIX:-error}"

log() {
  printf "${GREEN}[%s]${NC} %s\n" "${LOG_INFO_PREFIX}" "$*"
}

warn() {
  printf "${YELLOW}[%s]${NC} %s\n" "${LOG_WARN_PREFIX}" "$*"
}

die() {
  printf "${RED}[%s]${NC} %s\n" "${LOG_ERROR_PREFIX}" "$*" >&2
  exit 1
}
