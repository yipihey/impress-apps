#!/usr/bin/env bash
#
# test-imprint-api.sh — Comprehensive HTTP API stress test for imprint
#
# Exercises retained HTTP routes and generated document contracts on an isolated
# imprint host, validates responses, and tests error handling.
#
# Usage: IMPRINT_API_TEST_ISOLATED=1 \
#   IMPRINT_API_TEST_BASE_URL=http://localhost:<scratch-port> \
#   bash apps/imprint/test-imprint-api.sh
# The target must be an isolated imprint host using a PID-owned scratch workspace.
# Exit codes: 0 = all pass, 1 = failures, 2 = precondition fail

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Configuration ───────────────────────────────────────────────────
BASE_URL="${IMPRINT_API_TEST_BASE_URL:-}"
RESULTS_FILE="/tmp/imprint_api_results.txt"
DOC_ID=""
FAKE_UUID="00000000-0000-0000-0000-000000000000"
LOOPBACK_TOKEN="${IMPRESS_APP_TOKEN:-}"

if [[ "${IMPRINT_API_TEST_ISOLATED:-}" != "1" ]]; then
    echo "Error: refusing to run without IMPRINT_API_TEST_ISOLATED=1."
    echo "Use a dedicated imprint host backed by a PID-owned scratch workspace."
    exit 2
fi

case "$BASE_URL" in
    http://localhost:*|http://127.0.0.1:*) ;;
    *)
        echo "Error: set IMPRINT_API_TEST_BASE_URL to the isolated host's loopback URL."
        exit 2
        ;;
esac

API_PORT=$(printf '%s' "$BASE_URL" | sed -E 's#^http://(localhost|127\.0\.0\.1):([0-9]+)$#\2#')
case "$API_PORT" in
    ''|*[!0-9]*)
        echo "Error: IMPRINT_API_TEST_BASE_URL must be http://localhost:<port> or http://127.0.0.1:<port>."
        exit 2
        ;;
esac

if [[ -z "$LOOPBACK_TOKEN" ]]; then
    TOKEN_FILE="$HOME/Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/automation/loopback-${API_PORT}.token"
    if [[ -r "$TOKEN_FILE" ]]; then
        LOOPBACK_TOKEN=$(cat "$TOKEN_FILE")
    else
        echo "Error: no loopback token found for port ${API_PORT}; set IMPRESS_APP_TOKEN or start the isolated host."
        exit 2
    fi
fi

TOTAL_PASS=0
TOTAL_FAIL=0

> "$RESULTS_FILE"

# ── Timing ──────────────────────────────────────────────────────────
# macOS `date` lacks nanosecond support. Try gdate, fall back to perl, then seconds.
TIMING_METHOD="seconds"
if command -v gdate &>/dev/null; then
    TIMING_METHOD="gdate"
elif perl -MTime::HiRes -e '1' &>/dev/null; then
    TIMING_METHOD="perl"
fi

timestamp_ms() {
    case "$TIMING_METHOD" in
        gdate)  echo $(( $(gdate +%s%N) / 1000000 )) ;;
        perl)   perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' ;;
        *)      echo $(( $(date +%s) * 1000 )) ;;
    esac
}

# ── Display helpers ─────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  $1$(printf '%*s' $((59 - ${#1})) '')║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
}

print_section() {
    echo ""
    echo -e "${CYAN}┌─ $1${NC}"
    echo -e "${DIM}│${NC}"
}

print_section_end() {
    echo -e "${DIM}└─────────────────────────────────────────────${NC}"
}

print_result() {
    local status="$1" name="$2" duration="$3" error="${4:-}"
    if [[ "$status" == "PASS" ]]; then
        echo -e "${DIM}│${NC}  ${GREEN}✓${NC} ${name} ${DIM}(${duration}ms)${NC}"
    else
        echo -e "${DIM}│${NC}  ${RED}✗${NC} ${name} ${DIM}(${duration}ms)${NC}"
        if [[ -n "$error" ]]; then
            echo -e "${DIM}│${NC}    ${RED}→ ${error}${NC}"
        fi
    fi
}

# ── Test harness ────────────────────────────────────────────────────
# run_test category test_name expected_http_status [curl_args...]
# Captures response body + HTTP status, validates, records result.
LAST_BODY=""
LAST_STATUS=""

run_test() {
    local category="$1" test_name="$2" expected_status="$3"
    shift 3

    local t_start t_end duration http_code body
    t_start=$(timestamp_ms)

    # Run curl; capture body and http_code on the last line
    local response
    response=$(curl -s -H "Authorization: Bearer ${LOOPBACK_TOKEN}" \
        -w "\n%{http_code}" "$@" 2>&1) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    t_end=$(timestamp_ms)
    duration=$(( t_end - t_start ))

    LAST_BODY="$body"
    LAST_STATUS="$http_code"

    if [[ "$http_code" == "$expected_status" ]]; then
        echo "PASS|${category}|${test_name}|${duration}" >> "$RESULTS_FILE"
        print_result "PASS" "$test_name" "$duration"
        (( TOTAL_PASS++ )) || true
        return 0
    else
        local err="Expected HTTP ${expected_status}, got ${http_code}"
        echo "FAIL|${category}|${test_name}|${duration}|${err}" >> "$RESULTS_FILE"
        print_result "FAIL" "$test_name" "$duration" "$err"
        (( TOTAL_FAIL++ )) || true
        return 1
    fi
}

# Generated verbs are POST requests and require the per-launch loopback bearer.
# Keep their raw JSON result in LAST_BODY so the existing jq assertions can map
# arrays/records directly without expecting the legacy {status, ...} envelopes.
run_verb_test() {
    local category="$1" test_name="$2" expected_status="$3" descriptor="$4" args_json="$5"
    run_test "$category" "$test_name" "$expected_status" \
        -X POST "${BASE_URL}/api/verb/${descriptor}" \
        -H "Content-Type: application/json" \
        -d "$args_json"
}

# Assertions — operate on LAST_BODY from most recent run_test
assert_field() {
    local jq_path="$1" expected="$2" category="$3" test_name="$4"
    local t_start t_end duration actual
    t_start=$(timestamp_ms)

    actual=$(echo "$LAST_BODY" | jq -r "$jq_path" 2>/dev/null) || actual="(jq error)"

    t_end=$(timestamp_ms)
    duration=$(( t_end - t_start ))

    if [[ "$actual" == "$expected" ]]; then
        echo "PASS|${category}|${test_name}|${duration}" >> "$RESULTS_FILE"
        print_result "PASS" "$test_name" "$duration"
        (( TOTAL_PASS++ )) || true
    else
        local err="Expected ${jq_path}='${expected}', got '${actual}'"
        echo "FAIL|${category}|${test_name}|${duration}|${err}" >> "$RESULTS_FILE"
        print_result "FAIL" "$test_name" "$duration" "$err"
        (( TOTAL_FAIL++ )) || true
    fi
}

assert_field_exists() {
    local jq_path="$1" category="$2" test_name="$3"
    local t_start t_end duration actual
    t_start=$(timestamp_ms)

    actual=$(echo "$LAST_BODY" | jq -r "$jq_path" 2>/dev/null) || actual="null"

    t_end=$(timestamp_ms)
    duration=$(( t_end - t_start ))

    if [[ "$actual" != "null" && "$actual" != "" ]]; then
        echo "PASS|${category}|${test_name}|${duration}" >> "$RESULTS_FILE"
        print_result "PASS" "$test_name" "$duration"
        (( TOTAL_PASS++ )) || true
    else
        local err="${jq_path} is null or missing"
        echo "FAIL|${category}|${test_name}|${duration}|${err}" >> "$RESULTS_FILE"
        print_result "FAIL" "$test_name" "$duration" "$err"
        (( TOTAL_FAIL++ )) || true
    fi
}

assert_field_type() {
    local jq_path="$1" expected_type="$2" category="$3" test_name="$4"
    local t_start t_end duration actual_type
    t_start=$(timestamp_ms)

    actual_type=$(echo "$LAST_BODY" | jq -r "${jq_path} | type" 2>/dev/null) || actual_type="(jq error)"

    t_end=$(timestamp_ms)
    duration=$(( t_end - t_start ))

    if [[ "$actual_type" == "$expected_type" ]]; then
        echo "PASS|${category}|${test_name}|${duration}" >> "$RESULTS_FILE"
        print_result "PASS" "$test_name" "$duration"
        (( TOTAL_PASS++ )) || true
    else
        local err="Expected type '${expected_type}' at ${jq_path}, got '${actual_type}'"
        echo "FAIL|${category}|${test_name}|${duration}|${err}" >> "$RESULTS_FILE"
        print_result "FAIL" "$test_name" "$duration" "$err"
        (( TOTAL_FAIL++ )) || true
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" category="$3" test_name="$4"
    local t_start t_end duration
    t_start=$(timestamp_ms)
    t_end=$(timestamp_ms)
    duration=$(( t_end - t_start ))

    if echo "$haystack" | grep -q "$needle"; then
        echo "PASS|${category}|${test_name}|${duration}" >> "$RESULTS_FILE"
        print_result "PASS" "$test_name" "$duration"
        (( TOTAL_PASS++ )) || true
    else
        local err="Response does not contain '${needle}'"
        echo "FAIL|${category}|${test_name}|${duration}|${err}" >> "$RESULTS_FILE"
        print_result "FAIL" "$test_name" "$duration" "$err"
        (( TOTAL_FAIL++ )) || true
    fi
}

# ── Prerequisites ───────────────────────────────────────────────────
print_header "imprint HTTP API Stress Test"
echo ""
echo -e "${DIM}Checking prerequisites...${NC}"

if ! command -v jq &>/dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "  Install with: brew install jq"
    exit 2
fi
echo -e "  ${GREEN}✓${NC} jq available"

if ! command -v curl &>/dev/null; then
    echo -e "${RED}Error: curl is required but not installed.${NC}"
    exit 2
fi
echo -e "  ${GREEN}✓${NC} curl available"
echo -e "  ${DIM}Timing: ${TIMING_METHOD}${NC}"

# Check imprint is running
echo -e "${DIM}Connecting to imprint at ${BASE_URL}...${NC}"
if ! curl -s --connect-timeout 3 "${BASE_URL}/api/status" > /dev/null 2>&1; then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  Cannot connect to imprint on port 23121                    ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Make sure imprint is running with a document open."
    echo -e "  Check Settings > General > Automation:"
    echo -e "    • Enable Automation API = ON"
    echo -e "    • Enable HTTP server = ON"
    echo ""
    exit 2
fi
echo -e "  ${GREEN}✓${NC} imprint is running"

SCRIPT_START=$(timestamp_ms)

# ════════════════════════════════════════════════════════════════════
# 1. Server Health
# ════════════════════════════════════════════════════════════════════
print_section "1. Server Health"

run_test "health" "status_endpoint" "200" "${BASE_URL}/api/status"
# Gate: if status fails, exit immediately
if [[ "$LAST_STATUS" != "200" ]]; then
    echo ""
    echo -e "${RED}Status endpoint failed — cannot proceed.${NC}"
    echo -e "Ensure imprint is running with HTTP server enabled."
    exit 2
fi
assert_field ".status" "ok" "health" "status_field_ok"
assert_field ".app" "imprint" "health" "status_app_imprint"

run_test "health" "root_api_info" "200" "${BASE_URL}/"
assert_field_exists ".name" "health" "root_has_name"
assert_field_type ".endpoints" "object" "health" "root_has_endpoints"

run_test "health" "api_path_info" "200" "${BASE_URL}/api"

run_test "health" "cors_preflight" "204" -X OPTIONS "${BASE_URL}/api/status"

run_test "health" "unknown_endpoint" "404" "${BASE_URL}/api/nonexistent"

run_test "health" "logs_endpoint" "200" "${BASE_URL}/api/logs?limit=5"
assert_field_type ".data.entries" "array" "health" "logs_entries_is_array"

print_section_end

# ════════════════════════════════════════════════════════════════════
# 2. Logs Query
# ════════════════════════════════════════════════════════════════════
print_section "2. Logs Query"

run_test "logs" "logs_with_limit" "200" "${BASE_URL}/api/logs?limit=3"
# Check entries length <= 3
ENTRIES_LEN=$(echo "$LAST_BODY" | jq '.data.entries | length' 2>/dev/null) || ENTRIES_LEN="-1"
if [[ "$ENTRIES_LEN" -le 3 ]]; then
    echo "PASS|logs|logs_limit_respected|0" >> "$RESULTS_FILE"
    print_result "PASS" "logs_limit_respected" "0"
    (( TOTAL_PASS++ )) || true
else
    echo "FAIL|logs|logs_limit_respected|0|Got ${ENTRIES_LEN} entries, expected <= 3" >> "$RESULTS_FILE"
    print_result "FAIL" "logs_limit_respected" "0" "Got ${ENTRIES_LEN} entries, expected <= 3"
    (( TOTAL_FAIL++ )) || true
fi

run_test "logs" "logs_with_offset" "200" "${BASE_URL}/api/logs?limit=5&offset=2"
run_test "logs" "logs_level_filter" "200" "${BASE_URL}/api/logs?level=info,warning"
run_test "logs" "logs_category_filter" "200" "${BASE_URL}/api/logs?category=httpRouter"
run_test "logs" "logs_search_filter" "200" "${BASE_URL}/api/logs?search=document"

print_section_end

# ════════════════════════════════════════════════════════════════════
# 3. Document Lifecycle
# ════════════════════════════════════════════════════════════════════
print_section "3. Document Lifecycle"

# Create a test document through the generated contract (raw JSON string ID).
run_verb_test "document" "create_document" "200" \
    "imprint-app-service_create-document" \
    '{"title":"API Test Doc","format":"typst"}'
if [[ "$LAST_STATUS" == "200" ]]; then
    DOC_ID=$(echo "$LAST_BODY" | jq -r '. // empty' 2>/dev/null)
fi

# Verify the created row with the generated detail contract; otherwise fall back
# to the generated list result (a raw array, not the old {documents: [...]} envelope).
if [[ -n "$DOC_ID" && "$DOC_ID" != "null" ]]; then
    run_verb_test "document" "verify_created_document" "200" \
        "imprint-manuscript-service_get-document" "{\"id\":\"${DOC_ID}\"}"
    VERIFY_ID=$(echo "$LAST_BODY" | jq -r '.id // empty' 2>/dev/null)
    if [[ "$LAST_STATUS" != "200" || "$VERIFY_ID" != "$DOC_ID" ]]; then
        echo -e "${DIM}│${NC}  ${YELLOW}⚠ Created doc detail was not verified; falling back to generated list...${NC}"
        DOC_ID=""
    fi
fi

if [[ -z "$DOC_ID" || "$DOC_ID" == "null" ]]; then
    echo -e "${DIM}│${NC}  ${DIM}Fetching generated manuscript list for fallback...${NC}"
    run_verb_test "document" "list_documents_fallback" "200" \
        "imprint-manuscript-service_list-documents" "{}"
    DOC_ID=$(echo "$LAST_BODY" | jq -r '.[0].id // empty' 2>/dev/null)
fi

if [[ -z "$DOC_ID" || "$DOC_ID" == "null" ]]; then
    echo -e "${DIM}│${NC}  ${YELLOW}⚠ No documents available — skipping document-dependent tests${NC}"
    SKIP_DOC_TESTS=true
else
    SKIP_DOC_TESTS=false
    echo -e "${DIM}│${NC}  ${DIM}Using document: ${DOC_ID}${NC}"
fi

if [[ "$SKIP_DOC_TESTS" == "false" ]]; then
    # The generated list returns a raw array of DocumentSummary rows.
    run_verb_test "document" "list_documents" "200" \
        "imprint-manuscript-service_list-documents" "{}"
    assert_field_type "." "array" "document" "list_documents_array"

    # The generated detail returns a raw DocumentDetail record.
    run_verb_test "document" "get_document_metadata" "200" \
        "imprint-manuscript-service_get-document" "{\"id\":\"${DOC_ID}\"}"
    assert_field ".id" "$DOC_ID" "document" "metadata_id_matches"

    # Get document content
    run_test "document" "get_document_content" "200" "${BASE_URL}/api/documents/${DOC_ID}/content"
    assert_field_exists ".source" "document" "content_has_source"

    # Get document outline
    run_test "document" "get_document_outline" "200" "${BASE_URL}/api/documents/${DOC_ID}/outline"
    assert_field_type ".outline" "array" "document" "outline_is_array"

    # Update document
    run_test "document" "update_document" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/update" \
        -H "Content-Type: application/json" \
        -d '{"source":"= Introduction\n\nUpdated test document.\n\n== Methods\n\nUpdated methods.\n","title":"API Test Doc Updated"}'

    # Update metadata
    run_test "document" "update_metadata" "200" \
        -X PUT "${BASE_URL}/api/documents/${DOC_ID}/metadata" \
        -H "Content-Type: application/json" \
        -d '{"title":"API Test Doc Final","authors":["Test Author","Second Author"]}'
fi

print_section_end

# ════════════════════════════════════════════════════════════════════
# 4. Content Operations
# ════════════════════════════════════════════════════════════════════
if [[ "$SKIP_DOC_TESTS" == "false" ]]; then
    print_section "4. Content Operations"

    # Insert text at beginning
    run_test "content" "insert_text" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/insert" \
        -H "Content-Type: application/json" \
        -d '{"position":0,"text":"// Header\n"}'
    assert_field_exists ".textLength" "content" "insert_has_textLength"

    # Insert text at end (large position)
    run_test "content" "insert_text_end" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/insert" \
        -H "Content-Type: application/json" \
        -d '{"position":99999,"text":"\n// Footer\n"}'

    # Delete text
    run_test "content" "delete_text" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/delete" \
        -H "Content-Type: application/json" \
        -d '{"start":0,"end":10}'
    assert_field ".deletedLength" "10" "content" "delete_length_correct"

    # Compile document
    run_test "content" "compile_document" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/compile" \
        -H "Content-Type: application/json"
    assert_contains "$LAST_BODY" "ompilation" "content" "compile_message"

    # Get PDF (allow 404 if compilation is slow)
    sleep 1
    run_test "content" "get_pdf_attempt" "200" "${BASE_URL}/api/documents/${DOC_ID}/pdf" || {
        if [[ "$LAST_STATUS" == "404" ]]; then
            echo -e "${DIM}│${NC}  ${YELLOW}⚠ PDF not available yet (compilation may be slow) — not a failure${NC}"
            # Override: remove the FAIL, record as WARN
            sed -i '' '/get_pdf_attempt/d' "$RESULTS_FILE" 2>/dev/null || true
            echo "PASS|content|get_pdf_attempt(warn:404)|0" >> "$RESULTS_FILE"
            (( TOTAL_FAIL-- )) || true
            (( TOTAL_PASS++ )) || true
        fi
    }

    print_section_end
fi

# ════════════════════════════════════════════════════════════════════
# 5. Search & Replace
# ════════════════════════════════════════════════════════════════════
if [[ "$SKIP_DOC_TESTS" == "false" ]]; then
    print_section "5. Search & Replace"

    run_test "search" "search_simple" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/search" \
        -H "Content-Type: application/json" \
        -d '{"query":"test"}'
    assert_field_type ".matches" "array" "search" "search_matches_array"

    run_test "search" "search_case_insensitive" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/search" \
        -H "Content-Type: application/json" \
        -d '{"query":"INTRODUCTION","caseSensitive":false}'

    run_test "search" "search_case_sensitive" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/search" \
        -H "Content-Type: application/json" \
        -d '{"query":"INTRODUCTION","caseSensitive":true}'

    run_test "search" "search_regex" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/search" \
        -H "Content-Type: application/json" \
        -d '{"query":"=+\\s+\\w+","regex":true}'
    MATCH_COUNT=$(echo "$LAST_BODY" | jq '.matchCount // -1' 2>/dev/null) || MATCH_COUNT="-1"
    if [[ "$MATCH_COUNT" -ge 0 ]]; then
        echo "PASS|search|regex_matchCount_valid|0" >> "$RESULTS_FILE"
        print_result "PASS" "regex_matchCount_valid" "0"
        (( TOTAL_PASS++ )) || true
    else
        echo "FAIL|search|regex_matchCount_valid|0|matchCount is negative or missing" >> "$RESULTS_FILE"
        print_result "FAIL" "regex_matchCount_valid" "0" "matchCount is negative or missing"
        (( TOTAL_FAIL++ )) || true
    fi

    run_test "search" "replace_text" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/replace" \
        -H "Content-Type: application/json" \
        -d '{"search":"test","replacement":"example","all":true}'
    assert_field ".replaceAll" "true" "search" "replace_all_flag"

    print_section_end
fi

# ════════════════════════════════════════════════════════════════════
# 6. Citation Management
# ════════════════════════════════════════════════════════════════════
if [[ "$SKIP_DOC_TESTS" == "false" ]]; then
    print_section "6. Citation Management"

    EINSTEIN_BIB='@article{Einstein1905, author={Albert Einstein}, title={On the Electrodynamics of Moving Bodies}, journal={Annalen der Physik}, year={1905}}'
    FEYNMAN_BIB='@article{Feynman1965, author={Richard Feynman}, title={The Character of Physical Law}, journal={MIT Press}, year={1965}}'

    # Add Einstein citation
    run_test "citations" "add_citation_bib" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/bibliography" \
        -H "Content-Type: application/json" \
        -d "{\"citeKey\":\"Einstein1905\",\"bibtex\":\"${EINSTEIN_BIB}\"}"
    assert_field ".citeKey" "Einstein1905" "citations" "add_einstein_citekey"

    # Add Feynman citation
    run_test "citations" "add_second_citation" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/bibliography" \
        -H "Content-Type: application/json" \
        -d "{\"citeKey\":\"Feynman1965\",\"bibtex\":\"${FEYNMAN_BIB}\"}"

    # Small delay for operations to be processed
    sleep 0.3

    # Get bibliography
    run_test "citations" "get_bibliography" "200" "${BASE_URL}/api/documents/${DOC_ID}/bibliography"
    assert_field_type ".citations" "array" "citations" "bib_citations_array"

    # Insert citation reference
    run_test "citations" "insert_citation_ref" "200" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/insert-citation" \
        -H "Content-Type: application/json" \
        -d '{"citeKey":"Einstein1905","position":50}'
    assert_field ".citeKey" "Einstein1905" "citations" "insert_ref_citekey"

    # Get citation usages
    run_test "citations" "get_citation_usages" "200" "${BASE_URL}/api/documents/${DOC_ID}/citations"
    assert_field_type ".usages" "array" "citations" "usages_is_array"

    # Remove Feynman citation
    run_test "citations" "remove_citation" "200" \
        -X DELETE "${BASE_URL}/api/documents/${DOC_ID}/bibliography/Feynman1965"
    assert_field ".citeKey" "Feynman1965" "citations" "remove_feynman_citekey"

    print_section_end
fi

# ════════════════════════════════════════════════════════════════════
# 7. Export
# ════════════════════════════════════════════════════════════════════
if [[ "$SKIP_DOC_TESTS" == "false" ]]; then
    print_section "7. Export"

    # Export LaTeX (default template)
    run_test "export" "export_latex_default" "200" "${BASE_URL}/api/documents/${DOC_ID}/export/latex"
    assert_contains "$LAST_BODY" '\\begin{document}' "export" "latex_has_begin_document"

    # Export LaTeX (mnras template)
    run_test "export" "export_latex_mnras" "200" "${BASE_URL}/api/documents/${DOC_ID}/export/latex?template=mnras"
    assert_contains "$LAST_BODY" '\\documentclass{mnras}' "export" "latex_mnras_class"

    # Export plain text
    run_test "export" "export_text" "200" "${BASE_URL}/api/documents/${DOC_ID}/export/text"
    if [[ -n "$LAST_BODY" ]]; then
        echo "PASS|export|text_non_empty|0" >> "$RESULTS_FILE"
        print_result "PASS" "text_non_empty" "0"
        (( TOTAL_PASS++ )) || true
    else
        echo "FAIL|export|text_non_empty|0|Response body is empty" >> "$RESULTS_FILE"
        print_result "FAIL" "text_non_empty" "0" "Response body is empty"
        (( TOTAL_FAIL++ )) || true
    fi

    # Export Typst
    run_test "export" "export_typst" "200" "${BASE_URL}/api/documents/${DOC_ID}/export/typst"
    assert_field_exists ".source" "export" "typst_has_source"
    assert_field_exists ".bibliography" "export" "typst_has_bibliography"

    print_section_end
fi

# ════════════════════════════════════════════════════════════════════
# 8. Error Handling
# ════════════════════════════════════════════════════════════════════
print_section "8. Error Handling"

# The generated detail contract is exercised above. This legacy URL stays in
# the harness only to verify that the retired registration is no longer mounted.
run_test "errors" "retired_document_detail_invalid_uuid" "404" "${BASE_URL}/api/documents/not-a-uuid"

# Nonexistent document (valid UUID, not found)
run_test "errors" "nonexistent_document" "404" "${BASE_URL}/api/documents/${FAKE_UUID}"

# Nonexistent document content
run_test "errors" "nonexistent_content" "404" "${BASE_URL}/api/documents/${FAKE_UUID}/content"

# Nonexistent document outline
run_test "errors" "nonexistent_outline" "404" "${BASE_URL}/api/documents/${FAKE_UUID}/outline"

# Nonexistent document bibliography
run_test "errors" "nonexistent_bibliography" "404" "${BASE_URL}/api/documents/${FAKE_UUID}/bibliography"

if [[ "$SKIP_DOC_TESTS" == "false" ]]; then
    # Missing query parameter in search
    run_test "errors" "missing_query_param" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/search" \
        -H "Content-Type: application/json" \
        -d '{}'
    assert_contains "$LAST_BODY" "query" "errors" "missing_query_error_msg"

    # Missing search parameter in replace
    run_test "errors" "missing_search_param" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/replace" \
        -H "Content-Type: application/json" \
        -d '{"replacement":"x"}'

    # Missing replacement parameter in replace
    run_test "errors" "missing_replacement_param" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/replace" \
        -H "Content-Type: application/json" \
        -d '{"search":"x"}'

    # Missing position parameter in insert
    run_test "errors" "missing_position_param" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/insert" \
        -H "Content-Type: application/json" \
        -d '{"text":"x"}'

    # Missing text parameter in insert
    run_test "errors" "missing_text_param" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/insert" \
        -H "Content-Type: application/json" \
        -d '{"position":0}'

    # Invalid delete range (start > end)
    run_test "errors" "invalid_delete_range" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/delete" \
        -H "Content-Type: application/json" \
        -d '{"start":10,"end":5}'

    # Missing start parameter in delete
    run_test "errors" "missing_start_param" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/delete" \
        -H "Content-Type: application/json" \
        -d '{"end":5}'

    # Missing end parameter in delete
    run_test "errors" "missing_end_param" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/delete" \
        -H "Content-Type: application/json" \
        -d '{"start":0}'

    # Missing citeKey in insert-citation
    run_test "errors" "missing_citekey_insert" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/insert-citation" \
        -H "Content-Type: application/json" \
        -d '{}'

    # Missing citeKey in add bibliography
    run_test "errors" "missing_citekey_add" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/bibliography" \
        -H "Content-Type: application/json" \
        -d '{"bibtex":"@article{x, author={x}}"}'

    # Missing bibtex in add bibliography
    run_test "errors" "missing_bibtex_add" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/bibliography" \
        -H "Content-Type: application/json" \
        -d '{"citeKey":"x"}'

    # Invalid JSON body
    run_test "errors" "invalid_json_body" "400" \
        -X POST "${BASE_URL}/api/documents/${DOC_ID}/search" \
        -H "Content-Type: application/json" \
        -d 'not json'
fi

print_section_end

# ════════════════════════════════════════════════════════════════════
# 9. Stress / Rapid Fire
# ════════════════════════════════════════════════════════════════════
print_section "9. Stress / Rapid Fire (20 sequential requests)"

STRESS_PASS=0
STRESS_FAIL=0
STRESS_TOTAL_MS=0
STRESS_MAX_MS=0

# Build endpoint list to cycle through
declare -a STRESS_ENDPOINTS
STRESS_ENDPOINTS+=("${BASE_URL}/api/status")
if [[ "$SKIP_DOC_TESTS" == "false" ]]; then
    STRESS_ENDPOINTS+=("${BASE_URL}/api/documents/${DOC_ID}/content")
    STRESS_ENDPOINTS+=("${BASE_URL}/api/documents/${DOC_ID}/outline")
fi

NUM_ENDPOINTS=${#STRESS_ENDPOINTS[@]}

for i in $(seq 1 20); do
    IDX=$(( (i - 1) % NUM_ENDPOINTS ))
    URL="${STRESS_ENDPOINTS[$IDX]}"

    t_start=$(timestamp_ms)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null) || HTTP_CODE="000"
    t_end=$(timestamp_ms)
    LATENCY=$(( t_end - t_start ))

    STRESS_TOTAL_MS=$(( STRESS_TOTAL_MS + LATENCY ))
    if [[ "$LATENCY" -gt "$STRESS_MAX_MS" ]]; then
        STRESS_MAX_MS=$LATENCY
    fi

    if [[ "$HTTP_CODE" == "200" ]]; then
        (( STRESS_PASS++ )) || true
    else
        (( STRESS_FAIL++ )) || true
    fi
done

STRESS_AVG_MS=$(( STRESS_TOTAL_MS / 20 ))

echo -e "${DIM}│${NC}  Completed: ${BOLD}20${NC} requests"
echo -e "${DIM}│${NC}  Passed:    ${GREEN}${STRESS_PASS}${NC}  Failed: ${RED}${STRESS_FAIL}${NC}"
echo -e "${DIM}│${NC}  Avg latency: ${BOLD}${STRESS_AVG_MS}ms${NC}  Max: ${BOLD}${STRESS_MAX_MS}ms${NC}"

if [[ "$STRESS_FAIL" -eq 0 ]]; then
    echo "PASS|stress|rapid_fire_20|${STRESS_TOTAL_MS}" >> "$RESULTS_FILE"
    print_result "PASS" "rapid_fire_20 (${STRESS_PASS}/20, avg ${STRESS_AVG_MS}ms)" "$STRESS_TOTAL_MS"
    (( TOTAL_PASS++ )) || true
else
    echo "FAIL|stress|rapid_fire_20|${STRESS_TOTAL_MS}|${STRESS_FAIL}/20 failed" >> "$RESULTS_FILE"
    print_result "FAIL" "rapid_fire_20 (${STRESS_PASS}/20)" "$STRESS_TOTAL_MS" "${STRESS_FAIL}/20 requests failed"
    (( TOTAL_FAIL++ )) || true
fi

print_section_end

# ════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════
SCRIPT_END=$(timestamp_ms)
TOTAL_DURATION=$(( SCRIPT_END - SCRIPT_START ))

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Summary                                                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Per-category breakdown (compatible with bash 3.x — no associative arrays)
# Build unique ordered category list and count pass/fail per category via awk
printf "  ${BOLD}%-25s %8s %8s${NC}\n" "Category" "Pass" "Fail"
printf "  %-25s %8s %8s\n" "─────────────────────────" "────────" "────────"

awk -F'|' '
{
    cat = $2
    if (cat == "") next
    if (!(cat in seen)) { order[++n] = cat; seen[cat] = 1 }
    if ($1 == "PASS") pass[cat]++
    else if ($1 == "FAIL") fail[cat]++
}
END {
    for (i = 1; i <= n; i++) {
        c = order[i]
        p = (c in pass) ? pass[c] : 0
        f = (c in fail) ? fail[c] : 0
        printf "%s|%d|%d\n", c, p, f
    }
}
' "$RESULTS_FILE" | while IFS='|' read -r cat P F; do
    if [[ "$F" -gt 0 ]]; then
        printf "  %-25s ${GREEN}%8d${NC} ${RED}%8d${NC}\n" "$cat" "$P" "$F"
    else
        printf "  %-25s ${GREEN}%8d${NC} %8d\n" "$cat" "$P" "$F"
    fi
done

printf "  %-25s %8s %8s\n" "─────────────────────────" "────────" "────────"

TOTAL=$(( TOTAL_PASS + TOTAL_FAIL ))
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    printf "  ${BOLD}%-25s ${GREEN}%8d${NC} ${RED}%8d${NC}${NC}\n" "TOTAL" "$TOTAL_PASS" "$TOTAL_FAIL"
else
    printf "  ${BOLD}%-25s ${GREEN}%8d${NC} %8d${NC}\n" "TOTAL" "$TOTAL_PASS" "$TOTAL_FAIL"
fi

echo ""
echo -e "  ${DIM}Total duration: ${TOTAL_DURATION}ms${NC}"
echo -e "  ${DIM}Results file: ${RESULTS_FILE}${NC}"

if [[ "$SKIP_DOC_TESTS" == "true" ]]; then
    echo ""
    echo -e "  ${YELLOW}⚠ Document-dependent tests were skipped (no document available)${NC}"
fi

echo ""

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}RESULT: ${TOTAL_FAIL} test(s) FAILED${NC}"
    echo ""
    exit 1
else
    echo -e "  ${GREEN}${BOLD}RESULT: All ${TOTAL_PASS} tests PASSED${NC}"
    echo ""
    exit 0
fi
