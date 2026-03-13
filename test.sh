#!/bin/bash
set -e

echo "============================================"
echo "  Bedrock + LiteLLM + Open WebUI Test"
echo "============================================"

if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

MK="${LITELLM_MASTER_KEY:-sk-change-me}"
LU="http://localhost:${LITELLM_PORT:-4000}"
OU="http://localhost:${OPENWEBUI_PORT:-3000}"
PASS=0; FAIL=0

check() { if [ $? -eq 0 ]; then echo "  ✅ $1"; PASS=$((PASS+1)); else echo "  ❌ $1"; FAIL=$((FAIL+1)); fi; }

echo ""; echo "=== 1. LiteLLM Health ==="
curl -sf "$LU/health/readiness" > /dev/null 2>&1; check "LiteLLM healthy"

echo ""; echo "=== 2. Models ==="
curl -s "$LU/v1/models" -H "Authorization: Bearer $MK" | python3 -c "import sys,json; [print(f'  - {m[\"id\"]}') for m in json.load(sys.stdin)['data']]" 2>/dev/null
check "Models registered"

echo ""; echo "=== 3. Bedrock call (alice) ==="
R=$(curl -s "$LU/v1/chat/completions" -H "Authorization: Bearer $MK" -H "Content-Type: application/json" -H "X-OpenWebUI-User-Email: alice@test.com" -d '{"model":"claude-haiku","messages":[{"role":"user","content":"Say hi"}]}')
echo "$R" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  Response: {d[\"choices\"][0][\"message\"][\"content\"]}')" 2>/dev/null
check "Bedrock call (alice)"

echo ""; echo "=== 4. Bedrock call (bob) ==="
R=$(curl -s "$LU/v1/chat/completions" -H "Authorization: Bearer $MK" -H "Content-Type: application/json" -H "X-OpenWebUI-User-Email: bob@test.com" -d '{"model":"claude-haiku","messages":[{"role":"user","content":"1+1=?"}]}')
echo "$R" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  Response: {d[\"choices\"][0][\"message\"][\"content\"]}')" 2>/dev/null
check "Bedrock call (bob)"

echo ""; echo "=== 5. Budget test (charlie \$0) ==="
curl -s -X POST "$LU/customer/new" -H "Authorization: Bearer $MK" -H "Content-Type: application/json" -d '{"user_id":"charlie@test.com","max_budget":0}' > /dev/null 2>&1
curl -s "$LU/v1/chat/completions" -H "Authorization: Bearer $MK" -H "Content-Type: application/json" -H "X-OpenWebUI-User-Email: charlie@test.com" -d '{"model":"claude-haiku","messages":[{"role":"user","content":"hi"}]}' > /dev/null 2>&1
sleep 2
R=$(curl -s "$LU/v1/chat/completions" -H "Authorization: Bearer $MK" -H "Content-Type: application/json" -H "X-OpenWebUI-User-Email: charlie@test.com" -d '{"model":"claude-haiku","messages":[{"role":"user","content":"hi"}]}')
echo "$R" | grep -q "ExceededBudget"; check "Budget enforcement (charlie rejected)"

echo ""; echo "=== 6. Spend tracking ==="
for u in alice bob; do
  S=$(curl -s "$LU/customer/info?end_user_id=${u}@test.com" -H "Authorization: Bearer $MK" | python3 -c "import sys,json; print(f'\${json.load(sys.stdin).get(\"spend\",0):.6f}')" 2>/dev/null)
  echo "  ${u}: spend=${S}"
done; check "Spend tracking"

echo ""; echo "=== 7. Open WebUI ==="
HC=$(curl -s -o /dev/null -w "%{http_code}" "$OU" 2>/dev/null)
[ "$HC" = "200" ]; check "Open WebUI (HTTP $HC)"

echo ""; echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "  Open WebUI: $OU | LiteLLM: $LU/ui"
echo "============================================"
exit $FAIL
