#!/usr/bin/env bash
#
# smoke-test.sh — prueba de humo de todos los endpoints HTTP del stack.
#
# Requiere el stack levantado (gateway en 3000, payments en 3003):
#
#   docker compose -f docker-compose.prod.yml up -d
#   ./smoke-test.sh
#
# Crea un usuario aleatorio (smoke-...@example.com), inicia sesión, crea un
# producto, crea un pedido a partir de él, prueba los endpoints de orders y
# payments y borra el producto al final (soft delete).
#
# Variables de entorno:
#   GATEWAY_URL    default http://localhost:3000
#   PAYMENTS_URL   default http://localhost:3003
#   TIMEOUT        segundos de espera del gateway (default 120)
#   PAY_TIMEOUT    segundos de espera de payments (default 30)
#   STRICT_STRIPE  1 = fallar si Stripe no está configurado (default 0)
#
# Requiere: curl, jq.

set -uo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:3000}"
PAYMENTS_URL="${PAYMENTS_URL:-http://localhost:3003}"
TIMEOUT="${TIMEOUT:-120}"
PAY_TIMEOUT="${PAY_TIMEOUT:-30}"
STRICT_STRIPE="${STRICT_STRIPE:-0}"

API="${GATEWAY_URL%/}/api"
PAY="${PAYMENTS_URL%/}/payments"

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { printf 'Falta el comando: %s\n' "$bin" >&2; exit 1; }
done

if [[ -t 1 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; RESET=''
fi

PASS=0
FAIL=0
SKIP=0
FAILED=()

TOKEN=""
ORDER_ID=""
PRODUCT_ID=""
PRODUCT_DELETED=0

pass() { PASS=$((PASS + 1)); printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  FAILED+=("$1")
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
}
skip() { SKIP=$((SKIP + 1)); printf '  %sSKIP%s  %s\n' "$YELLOW" "$RESET" "$1"; }
section() { printf '\n%s== %s ==%s\n' "$CYAN" "$1" "$RESET"; }

HTTP_CODE="000"
BODY=""

body_preview() {
  printf '%s' "${BODY:-}" | tr '\n' ' ' | cut -c1-400
}

# request METHOD URL [JSON_BODY] [TOKEN] [EXTRA_HEADER]
request() {
  local method="$1" url="$2" data="${3:-}" token="${4:-}" extra_header="${5:-}"
  local out code
  local args=(-sS --max-time 20 -X "$method" -H 'Content-Type: application/json' -w $'\n%{http_code}')

  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token")
  [[ -n "$extra_header" ]] && args+=(-H "$extra_header")
  [[ -n "$data" ]] && args+=(--data "$data")

  out=$(curl "${args[@]}" "$url" 2>&1) || true
  code="${out##*$'\n'}"

  if [[ "$code" =~ ^[0-9]{3}$ ]]; then
    HTTP_CODE="$code"
    BODY="${out%$'\n'*}"
  else
    HTTP_CODE="000"
    BODY="$out"
  fi
}

expect() {
  local name="$1" expected="$2"
  if [[ "$HTTP_CODE" == "$expected" ]]; then
    pass "$name (HTTP $HTTP_CODE)"
    return 0
  fi
  fail "$name (esperaba HTTP $expected, obtuve $HTTP_CODE)" "$(body_preview)"
  return 1
}

jget() { jq -r "${1} // empty" <<<"$BODY" 2>/dev/null || true; }
json_ok() { jq -e "$@" <<<"$BODY" >/dev/null 2>&1; }

assert_json() {
  local name="$1"; shift
  if jq -e "$@" <<<"$BODY" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name" "$(body_preview)"
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$name"
  else
    fail "$name" "esperaba '$expected', obtuve '$actual'"
  fi
}

wait_http() {
  local url="$1" label="$2" limit="${3:-$TIMEOUT}"
  local deadline=$((SECONDS + limit)) code
  printf '  %s... esperando %s (%ss)%s\n' "$DIM" "$label" "$limit" "$RESET"
  while (( SECONDS < deadline )); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)
    if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
      printf '  %sOK%s  %s\n' "$GREEN" "$RESET" "$label"
      return 0
    fi
    sleep 2
  done
  printf '  %sTIMEOUT%s  %s\n' "$RED" "$RESET" "$label"
  return 1
}

# Si el script falla antes del DELETE, intenta limpiar el producto creado.
cleanup() {
  if [[ -n "$PRODUCT_ID" && "$PRODUCT_DELETED" != "1" ]]; then
    curl -sS -o /dev/null -X DELETE "$API/products/$PRODUCT_ID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

RUN_ID="$(date +%s)-$$-$RANDOM"
EMAIL="smoke-${RUN_ID}@example.com"
PASSWORD="Smoke1234!"
NAME="Smoke ${RUN_ID}"
PRODUCT_NAME="Smoke product ${RUN_ID}"
PRODUCT_PRICE="19.99"
UPDATED_PRICE="24.50"
QUANTITY="2"

printf '%sSmoke test%s  gateway=%s  payments=%s\n' "$CYAN" "$RESET" "$GATEWAY_URL" "$PAYMENTS_URL"
printf 'Usuario aleatorio: %s\n' "$EMAIL"

section "Esperando servicios"
if ! wait_http "$API/products?page=1&limit=1" "gateway + products-ms"; then
  printf '%sEl gateway no responde; abortando.%s\n' "$RED" "$RESET" >&2
  exit 1
fi

PAYMENTS_UP=0
if wait_http "$PAY/success" "payments-ms" "$PAY_TIMEOUT"; then
  PAYMENTS_UP=1
fi

section "AUTH"
REGISTER_PAYLOAD=$(jq -n --arg name "$NAME" --arg email "$EMAIL" --arg password "$PASSWORD" \
  '{name: $name, email: $email, password: $password}')

request POST "$API/auth/register-user" "$REGISTER_PAYLOAD"
if expect "POST /auth/register-user" 201; then
  TOKEN=$(jget '.token')
  USER_ID=$(jget '.user.id')
  assert_json "register devuelve token" '.token | type == "string" and length > 0'
  assert_eq "register devuelve el email" "$EMAIL" "$(jget '.user.email')"
  [[ -n "$USER_ID" ]] && pass "register devuelve user.id" || fail "register no devuelve user.id"
fi

LOGIN_PAYLOAD=$(jq -n --arg email "$EMAIL" --arg password "$PASSWORD" \
  '{email: $email, password: $password}')

request POST "$API/auth/login-user" "$LOGIN_PAYLOAD"
if expect "POST /auth/login-user" 201; then
  LOGIN_TOKEN=$(jget '.token')
  assert_json "login devuelve token" '.token | type == "string" and length > 0'
  [[ -n "$LOGIN_TOKEN" ]] && TOKEN="$LOGIN_TOKEN"
fi

request GET "$API/auth/get-user" "" "$TOKEN"
if expect "GET /auth/get-user (con token)" 200; then
  assert_eq "get-user devuelve el email" "$EMAIL" "$(jget '.email')"
fi

request GET "$API/auth/get-user"
expect "GET /auth/get-user sin token" 401

section "PRODUCTS"
CREATE_PRODUCT_PAYLOAD=$(jq -n --arg name "$PRODUCT_NAME" --argjson price "$PRODUCT_PRICE" \
  '{name: $name, price: $price}')

request POST "$API/products" "$CREATE_PRODUCT_PAYLOAD"
if expect "POST /products" 201; then
  PRODUCT_ID=$(jget '.product.id')
  assert_eq "POST /products devuelve el nombre" "$PRODUCT_NAME" "$(jget '.product.name')"
  if [[ "$PRODUCT_ID" =~ ^[0-9]+$ ]]; then
    pass "product.id = $PRODUCT_ID"
  else
    fail "POST /products no devolvió un id numérico" "$(body_preview)"
  fi
fi

request GET "$API/products?page=1&limit=50"
if expect "GET /products?page=1&limit=50" 200; then
  if [[ -n "$PRODUCT_ID" ]] && json_ok --argjson id "$PRODUCT_ID" '.data | map(.id) | index($id) != null'; then
    pass "el producto aparece en el listado"
  else
    fail "el producto no aparece en el listado" "$(body_preview)"
  fi
fi

if [[ -n "$PRODUCT_ID" ]]; then
  request GET "$API/products/$PRODUCT_ID"
  if expect "GET /products/:id" 200; then
    assert_eq "GET /products/:id devuelve el nombre" "$PRODUCT_NAME" "$(jget '.name')"
  fi

  UPDATE_PRODUCT_PAYLOAD=$(jq -n --argjson price "$UPDATED_PRICE" '{price: $price}')
  request PATCH "$API/products/$PRODUCT_ID" "$UPDATE_PRODUCT_PAYLOAD"
  if expect "PATCH /products/:id" 200; then
    assert_json "PATCH actualiza el precio" --argjson p "$UPDATED_PRICE" '.product.price == $p'
  fi
fi

request GET "$API/products/2147483647"
expect "GET /products/:id inexistente" 404

section "ORDERS"
if [[ -z "$TOKEN" ]]; then
  skip "sin token: se omiten las pruebas de orders"
else
  ORDER_PAYLOAD=$(jq -n --argjson pid "${PRODUCT_ID:-0}" --argjson qty "$QUANTITY" \
    '{items: [{productId: $pid, quantity: $qty}]}')

  request POST "$API/orders" "$ORDER_PAYLOAD" "$TOKEN"
  if expect "POST /orders" 201; then
    ORDER_ID=$(jget '.id')
    assert_json "la orden tiene totalAmount > 0" '.totalAmount > 0'
    assert_json "la orden tiene items" '.orderItem | length >= 1'
    [[ -n "$ORDER_ID" ]] && pass "order.id = $ORDER_ID" || fail "POST /orders no devolvió id"
  fi

  request GET "$API/orders?page=1&limit=50" "" "$TOKEN"
  if expect "GET /orders?page=1&limit=50" 200; then
    if [[ -n "$ORDER_ID" ]] && json_ok --arg id "$ORDER_ID" '.data | map(.id) | index($id) != null'; then
      pass "la orden aparece en el listado"
    else
      fail "la orden no aparece en el listado" "$(body_preview)"
    fi
  fi

  if [[ -n "$ORDER_ID" ]]; then
    request GET "$API/orders/$ORDER_ID" "" "$TOKEN"
    if expect "GET /orders/:id" 200; then
      assert_eq "GET /orders/:id devuelve el id" "$ORDER_ID" "$(jget '.id')"
    fi

    request PATCH "$API/orders/$ORDER_ID" '{"status":"PAID"}' "$TOKEN"
    if expect "PATCH /orders/:id (PAID)" 200; then
      assert_eq "la orden quedó PAID" "PAID" "$(jget '.status')"
    fi

    request GET "$API/orders?page=1&limit=10&status=PAID" "" "$TOKEN"
    if expect "GET /orders?status=PAID" 200; then
      if json_ok --arg id "$ORDER_ID" '.data | map(.id) | index($id) != null'; then
        pass "la orden PAID aparece en el filtro"
      else
        fail "la orden PAID no aparece en el filtro" "$(body_preview)"
      fi
    fi

    request PATCH "$API/orders/$ORDER_ID" '{"status":"NOPE"}' "$TOKEN"
    expect "PATCH /orders/:id con estado inválido" 400
  fi

  request POST "$API/orders" "$ORDER_PAYLOAD"
  expect "POST /orders sin token" 401

  request GET "$API/orders" "" ""
  expect "GET /orders sin token" 401

  request POST "$API/orders" '{"items":[{"productId":2147483647,"quantity":1}]}' "$TOKEN"
  expect "POST /orders con producto inexistente" 400

  request GET "$API/orders/00000000-0000-4000-8000-000000000000" "" "$TOKEN"
  expect "GET /orders/:id inexistente" 404
fi

section "PAYMENTS"
if (( PAYMENTS_UP == 0 )); then
  skip "payments-ms no responde en $PAYMENTS_URL"
else
  request GET "$PAY/success"
  if expect "GET /payments/success" 200; then
    assert_json "success devuelve ok=true" '.ok == true'
  fi

  request GET "$PAY/cancel"
  if expect "GET /payments/cancel" 200; then
    assert_json "cancel devuelve ok=false" '.ok == false'
  fi

  PAY_ORDER_ID="${ORDER_ID:-smoke-$RUN_ID}"
  SESSION_PAYLOAD=$(jq -n \
    --arg orderId "$PAY_ORDER_ID" \
    --arg name "$PRODUCT_NAME" \
    --argjson price "$PRODUCT_PRICE" \
    '{orderId: $orderId, currency: "usd", items: [{name: $name, price: $price, quantity: 1}]}')

  request POST "$PAY/create-payment-session" "$SESSION_PAYLOAD" "$TOKEN"
  case "$HTTP_CODE" in
    200|201)
      pass "POST /payments/create-payment-session (HTTP $HTTP_CODE)"
      ;;
    401)
      fail "POST /payments/create-payment-session (token rechazado)" "$(body_preview)"
      ;;
    500)
      if [[ "$STRICT_STRIPE" == "1" ]]; then
        fail "POST /payments/create-payment-session (Stripe no configurado)" "$(body_preview)"
      else
        skip "POST /payments/create-payment-session: Stripe no configurado (HTTP 500)"
      fi
      ;;
    *)
      fail "POST /payments/create-payment-session (HTTP $HTTP_CODE)" "$(body_preview)"
      ;;
  esac

  request POST "$PAY/create-payment-session" "$SESSION_PAYLOAD"
  expect "POST /payments/create-payment-session sin token" 401

  request POST "$PAY/webhook" '{"id":"evt_smoke","type":"charge.succeeded"}' "" \
    "Stripe-Signature: t=123,v1=deadbeef"
  expect "POST /payments/webhook con firma inválida" 400
fi

section "DELETE"
if [[ -n "$PRODUCT_ID" ]]; then
  request DELETE "$API/products/$PRODUCT_ID"
  if expect "DELETE /products/:id" 200; then
    PRODUCT_DELETED=1
    request GET "$API/products/$PRODUCT_ID"
    expect "GET /products/:id después del borrado" 404
  fi
else
  skip "no hay producto para borrar"
fi

section "RESUMEN"
printf '  %sPASS%s=%d  %sFAIL%s=%d  %sSKIP%s=%d\n' \
  "$GREEN" "$RESET" "$PASS" "$RED" "$RESET" "$FAIL" "$YELLOW" "$RESET" "$SKIP"
printf '  Usuario creado: %s\n' "$EMAIL"

if (( FAIL > 0 )); then
  printf '\nFallaron:\n'
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi

printf '\n%sTodo OK%s\n' "$GREEN" "$RESET"
