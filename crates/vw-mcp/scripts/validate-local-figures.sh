#!/usr/bin/env bash
set -euo pipefail

server="${1:-target/debug/vw-mcp}"
store="${2:-.local/vw-knowledge.sqlite}"
assets="${3:-.local/source-assets}"
source_id="fa503a5f-1b7a-5855-af11-480ef231883e"
page_466_citation="9e357f95-9162-5651-b1a4-818b7e9843a5"
page_467_citation="7ceb0804-6413-5afc-ada3-529593683239"

for spec in \
  "Fig. 4-3|$page_466_citation|466" \
  "Fig. 4-4|$page_466_citation|466" \
  "Fig. 4-5|$page_467_citation|467"; do
  IFS='|' read -r label citation page <<<"$spec"
  request=$(jq -cn \
    --arg citation "$citation" --arg label "$label" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"source-service_get-figure-image",arguments:{citation_id:$citation,source_item_id:null,figure_label:$label,padding:16,resolution_dpi:200,include_caption:true,format:"png"}}}')
  response=$(printf '%s\n' "$request" | "$server" --store-path "$store" --asset-root "$assets")
  jq -e --arg label "$label" --arg page "$page" '
    .result.isError == false and
    .result.structuredContent.status == "resolved" and
    .result.structuredContent.metadata.figure_label == $label and
    .result.structuredContent.metadata.page_label == $page and
    any(.result.content[]; .type == "image" and .mimeType == "image/png" and (.data | length) > 100)
  ' <<<"$response" >/dev/null
  echo "validated $label on PDF page $page"
done

page_request=$(jq -cn --arg source "$source_id" \
  '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"source-service_get-page-image",arguments:{source_item_id:$source,page_index:null,page_label:"467",resolution_dpi:150,format:"png"}}}')
page_response=$(printf '%s\n' "$page_request" | "$server" --store-path "$store" --asset-root "$assets")
jq -e '
  .result.isError == false and
  .result.structuredContent.metadata.page_label == "467" and
  any(.result.content[]; .type == "image" and .mimeType == "image/png" and (.data | length) > 100)
' <<<"$page_response" >/dev/null
echo "validated complete PDF page 467"
