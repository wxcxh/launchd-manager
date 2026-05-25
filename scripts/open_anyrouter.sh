#!/bin/zsh

set -u

LOG_FILE="/tmp/com.kalikyle.anyrouter.daily.out"
ERR_FILE="/tmp/com.kalikyle.anyrouter.daily.err"
ANYROUTER_URL="https://anyrouter.top"

{
  echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] opening ${ANYROUTER_URL}"
  /usr/bin/open "${ANYROUTER_URL}"
  echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] open command finished"
} >> "${LOG_FILE}" 2>> "${ERR_FILE}"
