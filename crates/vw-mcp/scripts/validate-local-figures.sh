#!/usr/bin/env bash
set -euo pipefail

server="${1:-target/debug/vw-mcp}"
store="${2:-.local/vw-knowledge.sqlite}"
assets="${3:-.local/source-assets}"
source_id="fa503a5f-1b7a-5855-af11-480ef231883e"

for label in "Fig. 4-3" "Fig. 4-4" "Fig. 4-5"; do
  request=$(jq -cn \
    --arg source "$source_id" --arg label "$label" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"source-service_get-figure-image",arguments:{citation_id:null,source_item_id:$source,figure_label:$label,padding:16,resolution_dpi:200,include_caption:true,format:"png"}}}')
  response=$(printf '%s\n' "$request" | "$server" --store-path "$store" --asset-root "$assets")
  jq -e --arg label "$label" '
    .result.isError == false and
    .result.structuredContent.status == "resolved" and
    .result.structuredContent.metadata.figure_label == $label and
    any(.result.content[]; .type == "image" and .mimeType == "image/png" and (.data | length) > 100)
  ' <<<"$response" >/dev/null
  echo "validated $label"
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
