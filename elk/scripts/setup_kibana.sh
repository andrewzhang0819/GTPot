#!/bin/bash
set -e

# -------------------------
# Config (override via docker-compose environment)
# -------------------------
KIBANA_URL="${KIBANA_URL:-http://kibana:5601}"                 # internal docker URL
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://localhost:5601}"   # what the user clicks in browser

EXEC_SPACE_ID="${EXEC_SPACE_ID:-exec}"
ANALYST_SPACE_ID="${ANALYST_SPACE_ID:-analyst}"

EXEC_NDJSON="${EXEC_NDJSON:-/kibana/exec.ndjson}"
ANALYST_NDJSON="${ANALYST_NDJSON:-/kibana/analyst.ndjson}"

DATA_VIEW_PATTERN="${DATA_VIEW_PATTERN:-honeypot-*}"
TIME_FIELD="${TIME_FIELD:-@timestamp}"

DASHBOARD_TITLE_SEARCH_EXEC="${DASHBOARD_TITLE_SEARCH_EXEC:-Honeypot Overview}"
DASHBOARD_TITLE_SEARCH_ANALYST="${DASHBOARD_TITLE_SEARCH_ANALYST:-Honeypot Analyst View}"

# -------------------------
# Wait for Kibana
# -------------------------
echo "==> Waiting for Kibana at ${KIBANA_URL} ..."
i=0
until curl -fsS -H "kbn-xsrf: true" "${KIBANA_URL}/api/status" >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -ge 90 ]; then
    echo "ERROR: Kibana not ready after waiting." >&2
    exit 1
  fi
  sleep 2
done
echo "==> Kibana is ready."

# -------------------------
# Helpers
# -------------------------
create_space () {
  SPACE_ID="$1"
  SPACE_NAME="$2"

  echo "==> Ensuring space exists: ${SPACE_ID}"
  # If it already exists, Kibana returns 409; ignore that.
  curl -sS -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -X POST "${KIBANA_URL}/api/spaces/space" \
    -d "{\"id\":\"${SPACE_ID}\",\"name\":\"${SPACE_NAME}\"}" >/dev/null || true
}

create_data_view () {
  SPACE_ID="$1"
  PATTERN="$2"
  TFIELD="$3"

  echo "==> Ensuring data view exists in space ${SPACE_ID}: ${PATTERN}"
  # If it already exists, this may return 409; ignore.
  curl -sS -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -X POST "${KIBANA_URL}/s/${SPACE_ID}/api/data_views/data_view" \
    -d "{
      \"data_view\": {
        \"title\": \"${PATTERN}\",
        \"timeFieldName\": \"${TFIELD}\"
      }
    }" >/dev/null || true
}

import_ndjson () {
  SPACE_ID="$1"
  FILE_PATH="$2"

  if [ ! -f "$FILE_PATH" ]; then
    echo "ERROR: Missing NDJSON: ${FILE_PATH}" >&2
    exit 1
  fi

  echo "==> Importing ${FILE_PATH} into space ${SPACE_ID}"
  curl -fsS -H "kbn-xsrf: true" \
    -X POST "${KIBANA_URL}/s/${SPACE_ID}/api/saved_objects/_import?overwrite=true" \
    -F "file=@${FILE_PATH}" \
    >/tmp/kibana_import_"${SPACE_ID}".json

  echo "==> Import result saved: /tmp/kibana_import_${SPACE_ID}.json"
}

find_dashboard_id () {
  SPACE_ID="$1"
  SEARCH="$2"

  # URL-encode spaces
  SEARCH_Q=$(printf "%s" "$SEARCH" | sed 's/ /%20/g')

  curl -fsS -H "kbn-xsrf: true" \
    "${KIBANA_URL}/s/${SPACE_ID}/api/saved_objects/_find?type=dashboard&search_fields=title&search=${SEARCH_Q}" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1
}

create_landing_dashboard () {
  # IDs extracted directly from the ndjson files — no search needed
  EXEC_ID="${EXEC_DASHBOARD_ID:-bd5015ad-ec4f-4243-8467-38c5ff093861}"
  ANALYST_ID="${ANALYST_DASHBOARD_ID:-20be6af8-fa4d-4e97-bbfe-50143f47044d}"

  echo "==> Exec dashboard id: ${EXEC_ID}"
  echo "==> Analyst dashboard id: ${ANALYST_ID}"
  echo "==> Creating landing page dashboard in DEFAULT space..."

  CYBER_LINK="${PUBLIC_BASE_URL}/s/${ANALYST_SPACE_ID}/app/dashboards#/view/${ANALYST_ID}"
  EXEC_LINK="${PUBLIC_BASE_URL}/s/${EXEC_SPACE_ID}/app/dashboards#/view/${EXEC_ID}"

  # IMPORTANT: panelsJSON must be a single-line JSON string (no literal newlines)
  cat > /tmp/landing-page.json <<EOF
{
  "attributes": {
    "title": "Choose View",
    "description": "Landing page to choose between Cyber and Exec dashboards",
    "panelsJSON": "[{\\"panelIndex\\":\\"1\\",\\"type\\":\\"markdown\\",\\"gridData\\":{\\"x\\":0,\\"y\\":0,\\"w\\":48,\\"h\\":15,\\"i\\":\\"1\\"},\\"embeddableConfig\\":{\\"markdown\\":\\"# Choose a view\\\\n\\\\n- [Cyber View](${CYBER_LINK})\\\\n- [Exec View](${EXEC_LINK})\\"}}]"
  }
}
EOF

  # -f makes curl fail on 4xx/5xx so the script stops if the JSON is rejected
  curl -fsS -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -X POST "${KIBANA_URL}/api/saved_objects/dashboard/landing-page?overwrite=true" \
    --data-binary @/tmp/landing-page.json >/dev/null

  echo "==> Landing page created: ${PUBLIC_BASE_URL}/app/dashboards#/view/landing-page"
}

# -------------------------
# Run
# -------------------------
# 0) Elasticsearch index template (MUST be before any data lands)
echo "==> Creating Elasticsearch index template..."
curl -sS -X PUT "http://elasticsearch:9200/_index_template/honeypot-template" \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns": ["honeypot-*"],
    "template": {
      "mappings": {
        "properties": {
          "geoip": {
            "properties": {
              "location": { "type": "geo_point" },
              "country_name": { "type": "keyword" },
              "city_name": { "type": "keyword" },
              "country_code2": { "type": "keyword" }
            }
          },
          "src_ip":                 { "type": "keyword" },
          "src_subnet":             { "type": "keyword" },
          "kill_chain_stage":       { "type": "keyword" },
          "attack_classification":  { "type": "keyword" },
          "mitre_tactic":           { "type": "keyword" },
          "mitre_technique":        { "type": "keyword" },
          "mitre_technique_id":     { "type": "keyword" },
          "honeypot":               { "type": "keyword" },
          "eventid":                { "type": "keyword" },
          "event_type":             { "type": "keyword" },
          "@timestamp":             { "type": "date" }
        }
      }
    }
  }'
echo "==> Index template created."

# 1) Spaces
create_space "$EXEC_SPACE_ID" "Executive"
create_space "$ANALYST_SPACE_ID" "Cyber Analyst"

# 2) Data views
create_data_view "$EXEC_SPACE_ID" "$DATA_VIEW_PATTERN" "$TIME_FIELD"
create_data_view "$ANALYST_SPACE_ID" "$DATA_VIEW_PATTERN" "$TIME_FIELD"

# 3) Imports
import_ndjson "$EXEC_SPACE_ID" "$EXEC_NDJSON"
import_ndjson "$ANALYST_SPACE_ID" "$ANALYST_NDJSON"

# 4) Landing page
create_landing_dashboard

echo "==> Kibana setup completed."