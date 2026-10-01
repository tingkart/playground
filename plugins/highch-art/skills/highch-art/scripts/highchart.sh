#!/usr/bin/env bash
# highchart.sh - upload datasets and upload/update dashboards on a highch.art workspace.
# Requires: curl, jq. Credentials: HIGHCHART_URL + HIGHCHART_API_KEY, or ~/.config/highchart/credentials.json
# ({"https://origin":{"apiKey":"hc_..."}}). Optional: HIGHCHART_COOKIE for a private gateway.
set -euo pipefail

CRED="${HIGHCHART_CREDENTIALS:-$HOME/.config/highchart/credentials.json}"
STATE=".highchart/state.json"
die() { echo "highchart: $*" >&2; exit 1; }
command -v curl >/dev/null && command -v jq >/dev/null || die "curl and jq are required."

URL="${HIGHCHART_URL:-}"; KEY="${HIGHCHART_API_KEY:-}"
if [ "${1:-}" = "--url" ]; then URL=$2; shift 2; fi
if [ -z "$URL" ] && [ -f "$CRED" ]; then
  [ "$(jq 'length' "$CRED")" = 1 ] && URL=$(jq -r 'keys[0]' "$CRED") || die "Several origins in $CRED; set HIGHCHART_URL or pass --url."
fi
[ -n "$URL" ] || die "No highch.art URL. Set HIGHCHART_URL or save credentials to $CRED."
URL=${URL%/}
[ -n "$KEY" ] || { [ -f "$CRED" ] && KEY=$(jq -r --arg u "$URL" '.[$u].apiKey // empty' "$CRED"); }
[ -n "$KEY" ] || die "No API key for $URL. Copy the connected prompt from the workspace again."

# call METHOD PATH [curl args]: prints the response body, fails with the server's error message on HTTP >= 400.
call() {
  local method=$1 path=$2; shift 2
  local out code; out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" -H "Authorization: Bearer $KEY" ${HIGHCHART_COOKIE:+-H "Cookie: $HIGHCHART_COOKIE"} "$@" "$URL$path") || { rm -f "$out"; die "request to $URL$path failed."; }
  if [ "$code" -ge 400 ]; then echo "highchart: HTTP $code $method $path: $(jq -r '.error // empty' "$out" 2>/dev/null)" >&2; rm -f "$out"; exit 1; fi
  cat "$out"; rm -f "$out"
}
enc() { jq -rn --arg v "$1" '$v|@uri'; }
state_get() { [ -f "$STATE" ] && jq -r --arg o "$URL" --arg id "$1" '.[$o][$id].revision // empty' "$STATE" || true; }
state_set() {
  mkdir -p .highchart; [ -f "$STATE" ] || echo '{}' > "$STATE"
  local tmp; tmp=$(mktemp); jq --arg o "$URL" --arg id "$1" --argjson r "$2" '.[$o][$id]={revision:$r}' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}
append() { jq -c --arg v "$2" '. + [$v]' <<<"$1"; }

upload_dataset() {
  local file=${1:?usage: upload-dataset FILE --name NAME [--description TEXT] [--meta META.json]}; shift
  local name="" desc="" meta=""
  while [ $# -gt 0 ]; do case $1 in --name) name=$2;; --description) desc=$2;; --meta) meta=$2;; *) die "unknown option $1";; esac; shift 2; done
  [ -n "$name" ] || die "--name is required."
  [ -f "$file" ] || die "$file not found."
  local res
  case $file in
    *.csv) [ -z "$meta" ] || die "--meta needs a JSON rows file; CSV uploads carry only name and description."
      res=$(call POST "/api/v1/datasets?name=$(enc "$name")&description=$(enc "$desc")" -H 'Content-Type: text/csv' --data-binary @"$file");;
    *.json) res=$(jq -c --arg name "$name" --arg desc "$desc" --slurpfile meta "${meta:-/dev/null}" \
        '{name:$name,description:$desc,rows:.} + (if ($meta|length)>0 then {metadata:$meta[0]} else {} end)' "$file" | call POST /api/v1/datasets -H 'Content-Type: application/json' --data-binary @-);;
    *) die "Use a .csv file or a .json array of row objects.";;
  esac
  echo "$URL/data/$(jq -r .id <<<"$res")"
  jq -r '"result.id=\(.id)\nresult.rows=\(.rowCount)\nresult.visibility=\(.visibility)"' <<<"$res" >&2
}

pull() {
  local id=${1:?usage: pull ID [FILE]} file=${2:-}
  local cur rev; cur=$(call GET "/api/v1/dashboards/$(enc "$id")"); rev=$(jq -r .revision <<<"$cur")
  file=${file:-$id.html}
  call GET "/api/v1/dashboards/$(enc "$id")/source?revision=$rev" > "$file"
  state_set "$id" "$rev"
  echo "$file"; echo "result.revision=$rev" >&2
}

push() {
  local file=${1:?usage: push FILE [--id ID] [--title T] [--description D] [--dataset ID]... [--tag T]... [--source URL[|TITLE]]... [--overwrite]}; shift
  local id="" title="" desc="" overwrite=0 ds=null tags=null srcs=null
  while [ $# -gt 0 ]; do case $1 in
    --id) id=$2; shift 2;; --title) title=$2; shift 2;; --description) desc=$2; shift 2;; --overwrite) overwrite=1; shift;;
    --dataset) ds=$(append "$([ "$ds" = null ] && echo '[]' || echo "$ds")" "$2"); shift 2;;
    --tag) tags=$(append "$([ "$tags" = null ] && echo '[]' || echo "$tags")" "$2"); shift 2;;
    --source) srcs=$(jq -c --arg v "$2" '(. // []) + [{url:($v|split("|")[0])} + (if ($v|contains("|")) then {title:($v|split("|")[1:]|join("|"))} else {} end)]' <<<"$srcs"); shift 2;;
    *) die "unknown option $1";; esac; done
  [ -f "$file" ] || die "$file not found."
  local base='{}' rev=""
  if [ -n "$id" ]; then
    local cur; cur=$(call GET "/api/v1/dashboards/$(enc "$id")")
    rev=$(state_get "$id")
    if [ "$overwrite" = 1 ]; then rev=$(jq -r .revision <<<"$cur"); fi
    [ -n "$rev" ] || die "No local revision for $id. Run 'highchart.sh pull $id' first, or pass --overwrite."
    base=$(jq -c '{title,description,datasetIds,sources,tags,freshness}' <<<"$cur")
  fi
  local body res
  body=$(jq -c -n --rawfile html "$file" --arg filename "$(basename "$file")" --argjson base "$base" --arg title "$title" --arg desc "$desc" \
    --argjson ds "$ds" --argjson tags "$tags" --argjson srcs "$srcs" \
    '$base + {html:$html,filename:$filename}
     + (if $title != "" then {title:$title} else {} end) + (if $desc != "" then {description:$desc} else {} end)
     + (if $ds != null then {datasetIds:$ds} else {} end) + (if $tags != null then {tags:$tags} else {} end) + (if $srcs != null then {sources:$srcs} else {} end)')
  if [ -n "$id" ]; then
    res=$(printf '%s' "$body" | call PUT "/api/v1/dashboards/$(enc "$id")" -H 'Content-Type: application/json' -H "If-Match: \"$rev\"" --data-binary @-)
  else
    res=$(printf '%s' "$body" | call POST /api/v1/dashboards -H 'Content-Type: application/json' --data-binary @-)
  fi
  state_set "$(jq -r .id <<<"$res")" "$(jq -r .revision <<<"$res")"
  jq -r .url <<<"$res"
  jq -r '"result.id=\(.id)\nresult.revision=\(.revision)\nresult.visibility=\(.visibility)"' <<<"$res" >&2
}

publish() {
  local id=${1:?usage: publish ID --index|--link}; shift
  local listed=""
  while [ $# -gt 0 ]; do case $1 in --index) listed=true;; --link) listed=false;; *) die "unknown option $1";; esac; shift; done
  [ -n "$listed" ] || die "Choose --index (list on the public index page) or --link (public URL only)."
  local res; res=$(printf '{"listed":%s}' "$listed" | call POST "/api/v1/dashboards/$(enc "$id")/publish" -H 'Content-Type: application/json' --data-binary @-)
  jq -r '.publicUrl' <<<"$res"
  jq -r '"result.revision=\(.publishedRevision)\nresult.listed=\(.listed)"' <<<"$res" >&2
}

case "${1:-help}" in
  datasets)        call GET "/api/v1/datasets?q=$(enc "${2:-}")" | jq '.datasets[] | {id,name,description,rowCount,columns:[.columns[].name],tags:.metadata.tags}';;
  dataset)         call GET "/api/v1/datasets/$(enc "${2:?usage: dataset ID}")" | jq 'del(.preview)';;
  dataset-content) call GET "/api/v1/datasets/$(enc "${2:?usage: dataset-content ID}")/content";;
  upload-dataset)  shift; upload_dataset "$@";;
  dashboards)      call GET "/api/v1/dashboards?q=$(enc "${2:-}")" | jq '.dashboards[] | {id,title,revision,updatedAt,visibility,publicUrl,datasetIds}';;
  dashboard)       call GET "/api/v1/dashboards/$(enc "${2:?usage: dashboard ID}")";;
  versions)        call GET "/api/v1/dashboards/$(enc "${2:?usage: versions ID}")/versions" | jq '.versions[] | {revision,createdAt,title,datasetIds}';;
  publish)         shift; publish "$@";;
  unpublish)       call DELETE "/api/v1/dashboards/$(enc "${2:?usage: unpublish ID}")/publish" | jq -r '"withdrawn: \(.revision)"';;
  pull)            shift; pull "$@";;
  push)            shift; push "$@";;
  *) cat >&2 <<USAGE
usage: highchart.sh [--url URL] COMMAND
  datasets [QUERY]            search the shared dataset library
  dataset ID                  metadata and schema
  dataset-content ID          all rows as JSON
  upload-dataset FILE --name N [--description D] [--meta META.json]
  dashboards [QUERY]          search dashboards
  dashboard ID | versions ID
  publish ID --index|--link   make the current revision public (owner only)
  unpublish ID                withdraw the public page
  pull ID [FILE]              download the latest source and remember its revision
  push FILE [--id ID] [--title T] [--description D] [--dataset ID]... [--tag T]... [--source URL[|TITLE]]... [--overwrite]
USAGE
  exit 2;;
esac
