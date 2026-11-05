#!/usr/bin/env bash
#
# logster-support-bundle.sh - collect a troubleshooting bundle from a Logster
# install on OpenShift (Helm chart deploy/openshift/logster).
#
# Reads the Prometheus metrics of the install through the API server service
# proxy (no port-forward, no route), takes a small cluster snapshot, and packs
# everything into a tar.gz to send to Eunomatix support. Read-only.
#
# Needs only bash (3.2 or newer), oc and the usual Unix tools. You must be
# logged in with oc and allowed to `get services/proxy` in the namespace.
#
# Usage:
#   ./logster-support-bundle.sh                    # namespace logster, last 3d
#   ./logster-support-bundle.sh -n prod -w 12h
#   ./logster-support-bundle.sh --no-snapshot
#   ./logster-support-bundle.sh --no-es
#   ./logster-support-bundle.sh --include-logs     # asks for confirmation
#   ./logster-support-bundle.sh --help
#
# Never collected: Secrets, ConfigMap contents, environment variables, Helm
# values, Events. Logs are collected only with --include-logs, and they are
# not redacted.

set -u
umask 077

SCRIPT_VERSION="1.0.0"

NAMESPACE="logster"
WINDOW="3d"
STEP=""
OUTPUT_DIR="."
SNAPSHOT=1
COLLECT_ES=1
ES_POD="elasticsearch-0"
ES_MAX_ENDPOINTS=1000
INCLUDE_LOGS=0
ASSUME_YES=0
MAX_SERIES=200      # per metric; above this only topk(MAX_SERIES, metric) is kept
MAX_RANGE_MB=150    # total range data; past this, metrics keep the instant value only
LOG_TAIL_LINES=100000
REQUEST_TIMEOUT="60s"

# Labels of this metric carry the license identity (auth_code, license_id).
SKIP_METRICS="logster_license_info"

usage() {
    cat <<EOF
logster-support-bundle.sh ${SCRIPT_VERSION}

Collect Prometheus metrics and a small cluster snapshot from a Logster install
on OpenShift into logster-support-<namespace>-<timestamp>.tar.gz. Read-only.

Options:
  -n, --namespace NS   Logster namespace (default: logster)
  -w, --window DUR     how far back to look: 30m, 12h, 3d, 1w (default: 3d)
      --step DUR       range query step (default: window/864, at least 60s)
  -o, --output-dir DIR where to write the bundle (default: current directory)
      --no-snapshot    skip the cluster snapshot (pods, pvc, top, images)
      --no-es          skip the per-endpoint Elasticsearch counts
      --include-logs   also collect pod logs; asks for confirmation first
  -y, --yes            answer yes to the --include-logs confirmation
      --max-series N   series kept per metric (default: ${MAX_SERIES})
      --max-range-mb N total size of range data (default: ${MAX_RANGE_MB})
  -h, --help           show this help
  -V, --version        show the script version

Requires oc, logged in, with "get services/proxy" in the namespace. The
per-endpoint Elasticsearch counts also need "create pods/exec"; without it they
are listed as FAILED in README.txt and the run continues.
Never collected: Secrets, ConfigMap contents, environment variables, Helm
values, Events. Logs only with --include-logs, and they are not redacted.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_value() {
    [ "$2" -ge 2 ] || die "$1 needs a value (see --help)"
}

# Duration such as 90m, 12h, 3d to seconds; prints nothing if malformed.
duration_seconds() {
    local num="${1%?}" unit="${1#"${1%?}"}"
    case "$num" in ''|*[!0-9]*) return 1 ;; esac
    case "$unit" in
        s) echo $(( 10#$num )) ;;
        m) echo $(( 10#$num * 60 )) ;;
        h) echo $(( 10#$num * 3600 )) ;;
        d) echo $(( 10#$num * 86400 )) ;;
        w) echo $(( 10#$num * 604800 )) ;;
        *) return 1 ;;
    esac
}

is_number() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

ARGS="$*"
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace)  need_value "$1" $#; NAMESPACE=$2; shift 2 ;;
        -w|--window)     need_value "$1" $#; WINDOW=$2; shift 2 ;;
        --step)          need_value "$1" $#; STEP=$2; shift 2 ;;
        -o|--output-dir) need_value "$1" $#; OUTPUT_DIR=$2; shift 2 ;;
        --max-series)    need_value "$1" $#; MAX_SERIES=$2; shift 2 ;;
        --max-range-mb)  need_value "$1" $#; MAX_RANGE_MB=$2; shift 2 ;;
        --no-snapshot)   SNAPSHOT=0; shift ;;
        --no-es)         COLLECT_ES=0; shift ;;
        --include-logs)  INCLUDE_LOGS=1; shift ;;
        -y|--yes)        ASSUME_YES=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        -V|--version)    echo "logster-support-bundle.sh ${SCRIPT_VERSION}"; exit 0 ;;
        *)               die "unknown option: $1 (see --help)" ;;
    esac
done

is_number "$MAX_SERIES" || die "--max-series must be a number"
is_number "$MAX_RANGE_MB" || die "--max-range-mb must be a number"
WINDOW_S=$(duration_seconds "$WINDOW") || die "bad --window '$WINDOW' (use 30m, 12h, 3d, 1w)"
[ "$WINDOW_S" -ge 300 ] || die "--window must be at least 5m"
if [ -n "$STEP" ]; then
    STEP_S=$(duration_seconds "$STEP") || die "bad --step '$STEP' (use 60s, 5m, 1h)"
    [ "$STEP_S" -ge 1 ] || die "--step must be at least 1s"
else
    STEP_S=$(( (WINDOW_S + 863) / 864 ))
    [ "$STEP_S" -ge 60 ] || STEP_S=60
fi
# Prometheus refuses range queries above 11000 points per series.
[ $(( WINDOW_S / STEP_S )) -le 11000 ] || die "--step is too small for the window (over 11000 points)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/logster-support.XXXXXX") || die "cannot create a temporary directory"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM
ERR="$WORK/stderr"

err_line() {
    head -n 1 "$ERR" | cut -c1-200
}

# --- Preflight ---------------------------------------------------------------

command -v oc >/dev/null 2>&1 || die "oc not found in PATH"
oc whoami </dev/null >/dev/null 2>&1 || die "not logged in to OpenShift: run 'oc login' first"

if ! oc get project "$NAMESPACE" </dev/null >/dev/null 2>&1 \
    && ! oc get namespace "$NAMESPACE" </dev/null >/dev/null 2>&1; then
    die "namespace '$NAMESPACE' does not exist or you have no access to it (use -n to pick another)"
fi

if ! oc get service prometheus -n "$NAMESPACE" </dev/null >/dev/null 2>"$ERR"; then
    if grep -qi 'forbidden' "$ERR"; then
        die "not allowed to read services in '$NAMESPACE': $(err_line)"
    fi
    die "no 'prometheus' service in '$NAMESPACE': was the chart installed with observability.enabled=false?"
fi

PROXY="/api/v1/namespaces/${NAMESPACE}/services/prometheus:9090/proxy"

if ! oc get --raw "${PROXY}/api/v1/status/buildinfo" --request-timeout="$REQUEST_TIMEOUT" \
    </dev/null >"$WORK/buildinfo" 2>"$ERR"; then
    if grep -qi 'forbidden' "$ERR"; then
        die "not allowed to use the service proxy: you need 'get services/proxy' in '$NAMESPACE' (check with: oc auth can-i get services/proxy -n $NAMESPACE)"
    fi
    die "Prometheus in '$NAMESPACE' did not answer, is its pod ready? ($(err_line))"
fi

if [ "$INCLUDE_LOGS" -eq 1 ]; then
    echo "WARNING: logs can hold usernames, hostnames and command lines, and they are NOT redacted."
    if [ "$ASSUME_YES" -ne 1 ]; then
        printf 'Collect pod logs into the bundle? [y/N] '
        answer=""
        read -r answer || answer=""
        case "$answer" in
            y|Y|yes|YES|Yes) ;;
            *) die "aborted: logs not confirmed, nothing collected (run without --include-logs for a metrics-only bundle)" ;;
        esac
    fi
fi

# --- Bundle layout -----------------------------------------------------------

mkdir -p "$OUTPUT_DIR" || die "cannot create output directory '$OUTPUT_DIR'"
START_TS=$(date -u +%Y%m%dT%H%M%SZ)
NAME="logster-support-${NAMESPACE}-${START_TS}"
BUNDLE="${OUTPUT_DIR%/}/${NAME}"
mkdir -p "$BUNDLE/prometheus" "$BUNDLE/metrics" "$BUNDLE/derived" || die "cannot write to '$OUTPUT_DIR'"
README="$BUNDLE/README.txt"

END=$(date -u +%s)
START=$(( END - WINDOW_S ))
STARTED_AT=$END

# Epoch to readable UTC (GNU date, then BSD date).
utc() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "$1"
}

{
    echo "Logster support bundle"
    echo "Script version:  ${SCRIPT_VERSION}"
    echo "Collected at:    $(utc "$END")"
    echo "Namespace:       ${NAMESPACE}"
    echo "Window:          ${WINDOW} ($(utc "$START") to $(utc "$END"))"
    echo "Range step:      ${STEP_S}s"
    echo "Flags:           ${ARGS:-none}"
    echo "Cap per metric:  ${MAX_SERIES} series, ${MAX_RANGE_MB} MB of range data in total"
    echo "Logs included:   $([ "$INCLUDE_LOGS" -eq 1 ] && echo yes || echo no)"
    echo "Snapshot:        $([ "$SNAPSHOT" -eq 1 ] && echo yes || echo no)"
    echo "ES counts:       $([ "$COLLECT_ES" -eq 1 ] && echo yes || echo no)"
    echo "Left out:        ${SKIP_METRICS} (labels carry the license identity)"
    echo
    echo "Problems and notes, in the order they happened:"
} >"$README"

note() {
    printf '%s\n' "$*" >>"$README"
}

# --- Prometheus helpers ------------------------------------------------------

urlencode() {
    local LC_ALL=C s="$1" out="" c hex i
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        case "$c" in
            [a-zA-Z0-9._~-]) out="${out}${c}" ;;
            *) printf -v hex '%%%02X' "'$c"; out="${out}${hex}" ;;
        esac
    done
    printf '%s' "$out"
}

# prom_get <api path with query string> <output file>
# Retries once; a failed call leaves the reason in $ERR.
prom_get() {
    local try
    for try in 1 2; do
        if oc get --raw "${PROXY}$1" --request-timeout="$REQUEST_TIMEOUT" </dev/null >"$2" 2>"$ERR"; then
            grep -q '"status":"success"' "$2" && return 0
            head -c 200 "$2" >"$ERR"
        fi
        [ "$try" -eq 1 ] && sleep 1
    done
    return 1
}

prom_instant() {
    prom_get "/api/v1/query?query=$(urlencode "$1")&time=${END}" "$2"
}

prom_range() {
    prom_get "/api/v1/query_range?query=$(urlencode "$1")&start=${START}&end=${END}&step=${STEP_S}" "$2"
}

has_result() {
    grep -q '"result":\[[^]]' "$1"
}

series_count() {
    grep -o '"metric":{' "$1" | wc -l | tr -d ' '
}

json_string() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Value of a one-series instant response, e.g. "1700000000.5".
first_value() {
    sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p' "$1" | head -n 1
}

# --- Prometheus status -------------------------------------------------------

echo "==> Prometheus status"
cp "$WORK/buildinfo" "$BUNDLE/prometheus/buildinfo.json"
for item in 'targets:targets?state=active' rules:rules alerts:alerts runtimeinfo:status/runtimeinfo tsdb:status/tsdb; do
    file=${item%%:*}
    path=${item#*:}
    prom_get "/api/v1/${path}" "$BUNDLE/prometheus/${file}.json" \
        || note "FAILED prometheus/${file}: $(err_line)"
done

# The top label pairs can name the license identity; the rest of tsdb is kept.
if [ -f "$BUNDLE/prometheus/tsdb.json" ]; then
    sed -e 's/,"seriesCountByLabelValuePair":\[[^]]*\]//' \
        -e 's/"seriesCountByLabelValuePair":\[[^]]*\],//' \
        "$BUNDLE/prometheus/tsdb.json" >"$WORK/tsdb" \
        && cp "$WORK/tsdb" "$BUNDLE/prometheus/tsdb.json"
fi

PROM_START=$(sed -n 's/.*"startTime":"\([^"]*\)".*/\1/p' "$BUNDLE/prometheus/runtimeinfo.json" 2>/dev/null)
note "Prometheus started: ${PROM_START:-unknown}"

JOBS=$(grep -o '"job":"[^"]*"' "$BUNDLE/prometheus/targets.json" 2>/dev/null \
    | sed 's/"job":"//; s/"$//' | sort -u | tr '\n' ' ')
note "Scrape jobs found: ${JOBS:-none}"
DOWN=$(grep -o '"health":"down"' "$BUNDLE/prometheus/targets.json" 2>/dev/null | wc -l | tr -d ' ')
[ "$DOWN" = "0" ] || note "WARNING: ${DOWN} scrape target(s) down, see prometheus/targets.json"

# How much history is there? An emptyDir Prometheus loses it all on restart.
DERIVED_WINDOW=$WINDOW
OLDEST_FILE="$BUNDLE/prometheus/oldest_sample.json"
if prom_instant "min(min_over_time(timestamp(up)[${WINDOW}:15s]))" "$OLDEST_FILE"; then
    OLDEST=$(first_value "$OLDEST_FILE")
    OLDEST=${OLDEST%%.*}
    TOLERANCE=$(( WINDOW_S / 20 ))
    [ "$TOLERANCE" -ge 300 ] || TOLERANCE=300
    if ! is_number "$OLDEST"; then
        note "WARNING: no samples at all in the window, Prometheus may have just restarted"
    else
        note "Oldest sample in the window: $(utc "$OLDEST")"
        if [ "$OLDEST" -gt $(( START + TOLERANCE )) ]; then
            note "WARNING: short history, data covers only the last $(( END - OLDEST ))s of the ${WINDOW} window (Prometheus restarted?)"
            # rate() over the full window would spread the data thin and read far too low.
            if [ $(( END - OLDEST )) -ge 60 ]; then
                DERIVED_WINDOW="$(( END - OLDEST ))s"
                note "Derived queries use the ${DERIVED_WINDOW} that has data, not ${WINDOW}"
            fi
        fi
    fi
else
    note "FAILED prometheus/oldest_sample: $(err_line)"
fi

# --- Metrics -----------------------------------------------------------------

NAMES_FILE="$BUNDLE/prometheus/metric_names.json"
METRICS=""
if prom_get "/api/v1/label/__name__/values?start=${START}&end=${END}" "$NAMES_FILE"; then
    METRICS=$(sed -e 's/.*"data":\[//' -e 's/\].*//' "$NAMES_FILE" | tr ',' '\n' | tr -d '"' \
        | grep -E '^(logster_|process_)|^up$' | grep -v -x -e "$SKIP_METRICS")
else
    note "FAILED prometheus/metric_names: $(err_line)"
fi
[ -n "$METRICS" ] || note "WARNING: no logster_*, process_* or up metrics found"

collect_metric() {
    local m="$1" query="$1" file instant_ok=1 range_ok=1 n
    file="$BUNDLE/metrics/$(printf '%s' "$m" | tr -c 'A-Za-z0-9_.-' '_').json"

    prom_instant "$query" "$WORK/instant" || { instant_ok=0; note "FAILED metrics/${m} (instant): $(err_line)"; }
    if [ "$instant_ok" -eq 1 ]; then
        n=$(series_count "$WORK/instant")
        if [ "$n" -gt "$MAX_SERIES" ]; then
            query="topk(${MAX_SERIES}, ${m})"
            note "CAPPED metrics/${m}: ${n} series, kept ${query}"
            prom_instant "$query" "$WORK/instant" || { instant_ok=0; note "FAILED metrics/${m} (instant capped): $(err_line)"; }
        fi
    fi

    if [ "$RANGE_BYTES" -ge $(( MAX_RANGE_MB * 1024 * 1024 )) ]; then
        range_ok=0
        note "SKIPPED metrics/${m} (range): over the ${MAX_RANGE_MB} MB limit"
    elif ! prom_range "$query" "$WORK/range"; then
        range_ok=0
        note "FAILED metrics/${m} (range): $(err_line)"
    else
        RANGE_BYTES=$(( RANGE_BYTES + $(wc -c <"$WORK/range") ))
    fi

    if [ "$instant_ok" -eq 1 ] && [ "$range_ok" -eq 1 ] \
        && ! has_result "$WORK/instant" && ! has_result "$WORK/range"; then
        note "EMPTY metrics/${m}: no data in the window"
    fi

    {
        printf '{"metric":"%s","query":"%s","instant":' "$m" "$(json_string "$query")"
        if [ "$instant_ok" -eq 1 ]; then cat "$WORK/instant"; else printf 'null'; fi
        printf ',"range":'
        if [ "$range_ok" -eq 1 ]; then cat "$WORK/range"; else printf 'null'; fi
        printf '}\n'
    } >"$file"
}

RANGE_BYTES=0
TOTAL=$(printf '%s\n' "$METRICS" | grep -c .)
echo "==> Metrics: ${TOTAL} to collect (window ${WINDOW}, step ${STEP_S}s)"
COUNT=0
for m in $METRICS; do
    collect_metric "$m"
    COUNT=$(( COUNT + 1 ))
    [ $(( COUNT % 25 )) -ne 0 ] || echo "    ${COUNT}/${TOTAL}"
done

# --- Derived queries ---------------------------------------------------------

# name|PromQL, @W@ is the window. sum/max by keeps them right on single-pod and
# multi-pod installs. A metric the installed version lacks just returns nothing
# and is listed in the README.
derived_queries() {
    cat <<'EOF'
events_per_sec_avg|sum(rate(logster_normalizer_raw_events_total[@W@]))
events_per_sec_peak|max_over_time(sum(rate(logster_normalizer_raw_events_total[5m]))[@W@:5m])
events_normalized|sum(increase(logster_normalizer_normalized_events_total[@W@]))
events_dropped|sum(increase(logster_normalizer_dropped_events_total[@W@]))
parse_errors|sum(increase(logster_normalizer_parse_errors_total[@W@]))
events_by_channel|sum by (channel)(increase(logster_splunk_receiver_channel_events_total[@W@]))
endpoints_reporting|sum(1 - logster_splunk_receiver_endpoint_stale)
skips_by_reason|sum by (service, stage, skip_reason, platform)(increase(logster_pipeline_skip_total[@W@]))
windows_by_verdict|sum by (prediction)(increase(logster_inference_runs_total[@W@]))
error_verdicts|sum(increase(logster_inference_runs_total{prediction="error"}[@W@]))
llm_calls|sum(increase(logster_inference_lc_wait_seconds_count[@W@]))
llm_latency_mean|sum(increase(logster_inference_lc_wait_seconds_sum[@W@])) / sum(increase(logster_inference_lc_wait_seconds_count[@W@]))
llm_latency_p95|histogram_quantile(0.95, sum by (le)(increase(logster_inference_lc_wait_seconds_bucket[@W@])))
llm_inflight_peak|max_over_time(sum(logster_inference_lc_inflight)[@W@:1m])
llm_deadline_exceeded|sum(increase(logster_inference_lc_deadline_exceeded_total[@W@]))
llm_parked_windows_peak|max_over_time(sum(logster_inference_lc_parked_windows)[@W@:1m])
prompt_tokens_p95|histogram_quantile(0.95, sum by (le)(increase(logster_inference_prompt_tokens_bucket[@W@])))
prompt_oversized|sum(increase(logster_inference_prompt_oversized_total[@W@]))
inflight_saturation_by_stage|sum by (stage)(increase(logster_inference_inflight_saturation_total[@W@]))
dispatch_deferred_endpoints_peak|max_over_time(sum(logster_inference_dispatch_deferred_endpoints)[@W@:5m])
events_evicted_unscored|sum by (platform)(increase(logster_inference_events_evicted_unscored_total[@W@]))
active_endpoints_peak|max_over_time(sum(logster_inference_active_endpoints)[@W@:5m])
kafka_lag_peak_by_job|max_over_time(sum by (job)(logster_kafka_consumer_lag)[@W@:5m])
kafka_lag_peak_by_topic|max_over_time(sum by (group, topic)(logster_kafka_consumer_lag)[@W@:5m])
alerts_created|sum(increase(logster_alerts_created_total[@W@]))
cpu_cores_peak_by_job|max_over_time(sum by (job)(rate(process_cpu_seconds_total[5m]))[@W@:5m])
rss_bytes_peak_by_job|max by (job)(max_over_time(process_resident_memory_bytes[@W@]))
process_restarts_by_job|sum by (job)(changes(process_start_time_seconds[@W@]))
targets_up_ratio_by_job|avg by (job)(avg_over_time(up[@W@]))
EOF
}

echo "==> Derived queries"
while IFS='|' read -r name template; do
    query=$(printf '%s' "$template" | sed "s/@W@/${DERIVED_WINDOW}/g")
    if prom_instant "$query" "$WORK/derived"; then
        has_result "$WORK/derived" || note "EMPTY derived/${name}: ${query}"
        {
            printf '{"query":"%s","time":%s,"response":' "$(json_string "$query")" "$END"
            cat "$WORK/derived"
            printf '}\n'
        } >"$BUNDLE/derived/${name}.json"
    else
        note "FAILED derived/${name}: $(err_line)"
    fi
done <<EOF
$(derived_queries)
EOF

# --- Elasticsearch per-endpoint counts ---------------------------------------

# Runs inside the ES pod, which has bash but no curl. ELASTIC_PASSWORD is
# expanded there, so it is never read by this script or written to the bundle.
# Only aggregation counts are requested, never documents.
ES_POD_SCRIPT='
LC_ALL=C
index=$1 body=$2
exec 3<>/dev/tcp/127.0.0.1/9200 || exit 1
printf "POST /%s/_search HTTP/1.0\r\nHost: localhost\r\nAuthorization: Basic %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s" \
    "$index" "$(printf "elastic:%s" "$ELASTIC_PASSWORD" | base64 -w0)" "${#body}" "$body" >&3
cr=$(printf "\r") chunked=0
while IFS= read -r line <&3; do
    line=${line%"$cr"}
    [ -n "$line" ] || break
    case "$line" in [Tt]ransfer-[Ee]ncoding:*[Cc]hunked*) chunked=1 ;; esac
done
if [ "$chunked" -eq 0 ]; then
    cat <&3
    exit
fi
# Elasticsearch answers chunked even to HTTP/1.0.
while IFS= read -r size <&3; do
    size=${size%"$cr"}
    [ -n "$size" ] && [ $((16#$size)) -gt 0 ] || break
    IFS= read -r -N $((16#$size)) chunk <&3
    printf "%s" "$chunk"
    IFS= read -r line <&3
done
'

# es_counts <file> <index pattern> <sub-aggregation field>
es_counts() {
    local file="$BUNDLE/elasticsearch/$1" index="$2" field="$3" body
    body='{"size":0,"timeout":"30s","query":{"range":{"@timestamp":{"gte":"now-'"${WINDOW}"'"}}},"aggs":{"endpoints":{"terms":{"field":"endpoint_id.keyword","size":'"${ES_MAX_ENDPOINTS}"'},"aggs":{"last_seen":{"max":{"field":"@timestamp"}},"breakdown":{"terms":{"field":"'"${field}"'","size":20}}}}}}'
    if oc exec -n "$NAMESPACE" "$ES_POD" --request-timeout="$REQUEST_TIMEOUT" -- \
        bash -c "$ES_POD_SCRIPT" es-counts "$index" "$body" </dev/null >"$file" 2>"$ERR" \
        && grep -q '"aggregations"' "$file"; then
        return 0
    fi
    [ -s "$ERR" ] || head -c 200 "$file" >"$ERR"
    note "FAILED elasticsearch/$1: $(err_line)"
    rm -f "$file"
}

if [ "$COLLECT_ES" -eq 1 ]; then
    echo "==> Elasticsearch per-endpoint counts"
    mkdir -p "$BUNDLE/elasticsearch"
    es_counts events_by_endpoint.json 'logster-events*' event_type.keyword
    es_counts inferences_by_endpoint.json 'logster-inferences*' prediction.keyword
else
    note "Elasticsearch counts skipped (--no-es)"
fi

# --- Cluster snapshot --------------------------------------------------------

# snapshot <file> <oc args...>
snapshot() {
    local file="$BUNDLE/cluster/$1"
    shift
    if ! oc "$@" -n "$NAMESPACE" --request-timeout="$REQUEST_TIMEOUT" </dev/null >"$file" 2>"$ERR"; then
        note "FAILED cluster/$(basename "$file"): $(err_line)"
        err_line >"$file"
    fi
}

if [ "$SNAPSHOT" -eq 1 ]; then
    echo "==> Cluster snapshot"
    mkdir -p "$BUNDLE/cluster"
    snapshot pods.txt get pods -o wide
    snapshot pvc.txt get pvc
    snapshot workloads.txt get deployments,statefulsets
    snapshot top.txt adm top pods
    snapshot images.txt get pods \
        -o 'custom-columns=POD:.metadata.name,CONTAINERS:.spec.containers[*].name,IMAGES:.spec.containers[*].image,IMAGE_IDS:.status.containerStatuses[*].imageID'
    snapshot resources.txt get pods \
        -o 'jsonpath={range .items[*]}{.metadata.name}{range .spec.containers[*]}{"\t"}{.name}{" requests="}{.resources.requests}{" limits="}{.resources.limits}{end}{"\n"}{end}'
else
    note "Cluster snapshot skipped (--no-snapshot)"
fi

# --- Logs (only with --include-logs) -----------------------------------------

collect_logs() {
    local pod="$1" c dir
    shift
    dir="$BUNDLE/logs/$pod"
    mkdir -p "$dir"
    for c in "$@"; do
        if ! oc logs -n "$NAMESPACE" "$pod" -c "$c" --timestamps --since="${WINDOW_S}s" \
            --tail="$LOG_TAIL_LINES" </dev/null >"$dir/$c.log" 2>"$ERR"; then
            note "FAILED logs/${pod}/${c}: $(err_line)"
            rm -f "$dir/$c.log"
        fi
        # No previous container is the normal case, not a problem.
        if oc logs -n "$NAMESPACE" "$pod" -c "$c" --previous --timestamps --since="${WINDOW_S}s" \
            --tail="$LOG_TAIL_LINES" </dev/null >"$WORK/previous" 2>/dev/null && [ -s "$WORK/previous" ]; then
            cp "$WORK/previous" "$dir/$c.previous.log"
        fi
    done
}

if [ "$INCLUDE_LOGS" -eq 1 ]; then
    echo "==> Pod logs"
    mkdir -p "$BUNDLE/logs"
    if oc get pods -n "$NAMESPACE" </dev/null 2>"$ERR" \
        -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.spec.initContainers[*].name}{" "}{.spec.containers[*].name}{"\n"}{end}' \
        >"$WORK/pods"; then
        while read -r line; do
            [ -n "$line" ] || continue
            # shellcheck disable=SC2086 # word splitting is the point here
            collect_logs $line
        done <"$WORK/pods"
    else
        note "FAILED logs: $(err_line)"
    fi
fi

# --- Pack --------------------------------------------------------------------

FINISHED_AT=$(date -u +%s)
note ""
note "Finished: $(utc "$FINISHED_AT") ($(( FINISHED_AT - STARTED_AT ))s)"

echo "==> Packing"
ARCHIVE="${OUTPUT_DIR%/}/${NAME}.tar.gz"
if ! ( cd "${OUTPUT_DIR%/}/" && tar -czf "${NAME}.tar.gz" "$NAME" ); then
    die "could not create ${ARCHIVE}; the collected files are in ${BUNDLE}"
fi

echo
echo "Bundle:  ${ARCHIVE} ($(du -h "$ARCHIVE" | cut -f1 | tr -d ' '))"
echo "Folder:  ${BUNDLE}"
PROBLEMS=$(grep -c -E '^(FAILED|EMPTY|CAPPED|SKIPPED|WARNING)' "$README")
echo "Notes:   ${PROBLEMS} entries in README.txt (failed, empty, capped or skipped items)"
if [ "$INCLUDE_LOGS" -eq 1 ]; then
    echo "Logs:    in ${BUNDLE}/logs. To send without them, delete that folder and re-create the archive:"
    echo "         rm -rf '${BUNDLE}/logs' && tar -czf '${ARCHIVE}' -C '${OUTPUT_DIR%/}' '${NAME}'"
fi
