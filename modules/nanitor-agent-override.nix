# Override for nanitor-agent module to fix v7 enrollment key format issue
# Issue: The upstream module incorrectly handles the ' + ' separator in the key body.
# The nanitor-agent v7 expects: JWT on one line, '+' on another line, SIGNATURE on third line.
#
# This module overrides the preStart script to correctly format the key.
#
# Upstream issue: https://github.com/kd2flz/nanitor-agent/issues/9
# See docs/nanitor-issue-9-comment.md for detailed root cause analysis.
#
# BACKWARD COMPATIBILITY: This override will remain compatible if/when upstream
# fixes the issue because it:
# 1. Handles keys with ' + ' separator by splitting them correctly
# 2. Handles keys without ' + ' separator by passing them through unchanged
# 3. Can be safely removed once upstream module is fixed

{ config, lib, pkgs, ... }:

let
  cfg = config.services.nanitor-agent;
in
{
  config = lib.mkIf (cfg.enable && cfg.enroll.enable) {
    systemd.services.nanitor-agent.preStart = lib.mkForce ''
      set -euo pipefail

      bin="${cfg.package}/bin/nanitor-agent"

      ${lib.optionalString (cfg.enroll.keyFile != null) ''
        if [ ! -f ${lib.escapeShellArg cfg.enroll.keyFile} ]; then
          echo "[nanitor-agent unit] ERROR: key file not found: ${lib.escapeShellArg cfg.enroll.keyFile}"
          exit 1
        fi
        if [ ! -s ${lib.escapeShellArg cfg.enroll.keyFile} ]; then
          echo "[nanitor-agent unit] ERROR: key file is empty: ${lib.escapeShellArg cfg.enroll.keyFile}"
          exit 1
        fi

        _KEY_LINES=$(wc -l < ${lib.escapeShellArg cfg.enroll.keyFile})
        _KEY_BYTES=$(wc -c < ${lib.escapeShellArg cfg.enroll.keyFile})
        _HAS_BEGIN=$(grep -c '-----BEGIN' ${lib.escapeShellArg cfg.enroll.keyFile} || true)
        _HAS_PLUS=$(grep -cF ' + ' ${lib.escapeShellArg cfg.enroll.keyFile} || true)
        echo "[nanitor-agent unit] Key file: lines=$_KEY_LINES bytes=$_KEY_BYTES has_BEGIN=$_HAS_BEGIN has_plus_sep=$_HAS_PLUS"

        NANITOR_KEY_TMPFILE=$(mktemp /tmp/nanitor-signup-key.XXXXXX)

        _RAW=$(cat ${lib.escapeShellArg cfg.enroll.keyFile})
        _BODY=$(echo "$_RAW" | sed 's/^[[:space:]]*-----BEGIN[^-]*-----[[:space:]]*//' | sed 's/[[:space:]]*-----END[^-]*-----[[:space:]]*$//' | tr -d '\r\n')
        _LABEL=$(echo "$_RAW" | grep -o 'BEGIN [^-]*' | sed 's/BEGIN //' | tr -d '\r\n' | sed 's/[[:space:]]*$//')

        # FIX: Split JWT and SIGNATURE with '+' on separate lines (as v7 expects)
        if echo "$_BODY" | grep -qF ' + '; then
          # Extract JWT and signature from "JWT + SIGNATURE" format
          _JWT=$(echo "$_BODY" | sed 's/ + .*//')
          _SIG=$(echo "$_BODY" | sed 's/.* + //')
          echo "[nanitor-agent unit] Writing multi-line PEM format (JWT, +, SIG on separate lines)"
          printf '%s\n%s\n%s\n%s\n%s\n' \
            "-----BEGIN ''${_LABEL}-----" \
            "$_JWT" \
            "+" \
            "$_SIG" \
            "-----END ''${_LABEL}-----" > "$NANITOR_KEY_TMPFILE"
        else
          echo "[nanitor-agent unit] Writing single-line PEM format (no separator found)"
          printf '%s\n%s\n%s\n' \
            "-----BEGIN ''${_LABEL}-----" \
            "$_BODY" \
            "-----END ''${_LABEL}-----" > "$NANITOR_KEY_TMPFILE"
        fi

        echo "[nanitor-agent unit] Key file staged for signup ($(wc -l < "$NANITOR_KEY_TMPFILE") lines)"
      ''}

      ${lib.optionalString (cfg.enroll.serverUrlFile != null) ''
        if [ ! -f ${lib.escapeShellArg cfg.enroll.serverUrlFile} ]; then
          echo "[nanitor-agent unit] ERROR: server URL file not found: ${lib.escapeShellArg cfg.enroll.serverUrlFile}"
          exit 1
        fi
        NANITOR_SERVER_URL=$(tr -d '[:space:]' < ${lib.escapeShellArg cfg.enroll.serverUrlFile})
        if [ -z "$NANITOR_SERVER_URL" ]; then
          echo "[nanitor-agent unit] ERROR: server URL file is empty: ${lib.escapeShellArg cfg.enroll.serverUrlFile}"
          exit 1
        fi
        export NANITOR_SERVER_URL
        echo "[nanitor-agent unit] Setting server URL from file"
        "$bin" set-server-url "$NANITOR_SERVER_URL" || echo "[nanitor-agent unit] set-server-url failed (continuing)"
      ''}

      ${lib.optionalString (cfg.enroll.serverUrl != null) ''
        echo "[nanitor-agent unit] Setting server URL to '${cfg.enroll.serverUrl}'"
        "$bin" set-server-url ${lib.escapeShellArg cfg.enroll.serverUrl} || echo "[nanitor-agent unit] set-server-url failed (continuing)"
      ''}

      AGENT_UUID=$("$bin" info 2>/dev/null | grep "^UUID:" | sed 's/^UUID: *//' || true)
      if ! "$bin" is-signedup >/dev/null 2>&1 || [ -z "$AGENT_UUID" ]; then
        echo "[nanitor-agent unit] Not enrolled yet; attempting signup"
        ${lib.optionalString (cfg.enroll.keyFile != null) ''
          "$bin" signup --keyfile "$NANITOR_KEY_TMPFILE" || echo "[nanitor-agent unit] signup failed; agent may not connect"
        ''}
        ${lib.optionalString (cfg.enroll.key != null) ''
          "$bin" signup --key ${lib.escapeShellArg cfg.enroll.key} || echo "[nanitor-agent unit] signup failed; agent may not connect"
        ''}
        ${lib.optionalString ((cfg.environment.NANITOR_ENROLL_TOKEN or "") != "") ''
          "$bin" signup --key "$NANITOR_ENROLL_TOKEN" || echo "[nanitor-agent unit] signup failed; agent may not connect"
        ''}
      else
        echo "[nanitor-agent unit] Agent already enrolled (UUID: $AGENT_UUID)"
      fi

      ${lib.optionalString (cfg.enroll.keyFile != null) ''
        [ -n "''${NANITOR_KEY_TMPFILE:-}" ] && rm -f "$NANITOR_KEY_TMPFILE" || true
      ''}
    '';
  };
}
