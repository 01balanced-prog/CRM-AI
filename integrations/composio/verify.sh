#!/bin/sh
# ============================================================================
# Проверка ключа только на чтение. Показывает, что читается и что запись
# отбивается. Ничего не меняет в базе — записи здесь заведомо неуспешные.
#
#   sh integrations/composio/verify.sh '<ключ crm_readonly>'
#
# Тот же ключ, что подключён к коннектору в Composio. Пять чтений обязаны
# вернуть 200, шесть попыток записи — 403 с кодом 42501.
# ============================================================================

set -e
KEY="${1:-$CRM_READONLY_KEY}"
API="${CRM_API:-https://wiokdxswbcmjdpalyrat.supabase.co/rest/v1}"
# Публичный ключ проекта, тот же что в index.html. Шлюз Supabase требует в
# заголовке apikey зарегистрированный ключ и отбивает самодельный JWT ещё
# до базы. Прав он не даёт: роль определяет Authorization.
PUB="${CRM_GATEWAY_KEY:-sb_publishable_AWo5r5fudoIWayLflnZOeQ_s5Db1q2C}"

if [ -z "$KEY" ]; then
  echo "Не передан ключ: sh verify.sh '<ключ>'" >&2
  exit 2
fi

ok=0
bad=0

call() {
  want="$1"; label="$2"; shift 2
  body=$(curl -s -m 20 -w '\n%{http_code}' "$@" \
    -H "apikey: $PUB" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json')
  code=$(printf '%s' "$body" | tail -n1)
  data=$(printf '%s' "$body" | sed '$d' | cut -c1-110)
  if [ "$code" = "$want" ]; then
    ok=$((ok + 1)); mark='  ок  '
  else
    bad=$((bad + 1)); mark='ПРОБЛЕМА'
  fi
  printf '%s  ждали %s, пришло %s — %s\n' "$mark" "$want" "$code" "$label"
  printf '          %s\n' "$data"
}

echo 'ЧТЕНИЕ — должно проходить'
call 200 'лиды со статусами'   "$API/v_leads?select=company_name,status,tariff,mrr_amount&order=company_name&limit=5"
call 200 'таблица leads'       "$API/leads?select=id,status,next_action_at&limit=3"
call 200 'заведения'           "$API/companies?select=name,segment&limit=3"
call 200 'журнал касаний'      "$API/activities?select=channel,outcome,created_at&limit=3"
call 200 'тарифы'              "$API/tariffs?select=code,title,setup_amount,mrr_amount"

echo
echo 'ЗАПИСЬ — должна отклоняться (403, код 42501)'
call 403 'POST /leads'         -X POST   "$API/leads"      -d '{"company_id":"00000000-0000-0000-0000-000000000000"}'
call 403 'POST /companies'     -X POST   "$API/companies"  -d '{"name":"Проверка записи"}'
call 403 'PATCH /leads'        -X PATCH  "$API/leads?status=eq.new" -d '{"status":"won"}'
call 403 'DELETE /leads'       -X DELETE "$API/leads?status=eq.new"
call 403 'POST /activities'    -X POST   "$API/activities" -d '{"lead_id":"00000000-0000-0000-0000-000000000000","channel":"call"}'
call 403 'POST /rpc/log_touch' -X POST   "$API/rpc/log_touch" -d '{"client_id":"00000000-0000-0000-0000-000000000000","lead_id":"00000000-0000-0000-0000-000000000000","channel":"call","outcome":"answered","status":"new"}'

echo
echo "Совпало: $ok, разошлось: $bad"
[ "$bad" -eq 0 ] || { echo 'Ключ ведёт себя не так, как должен. Отозвать: revoke crm_readonly from authenticator;' >&2; exit 1; }
echo 'Ключ отдаёт данные только на чтение.'
