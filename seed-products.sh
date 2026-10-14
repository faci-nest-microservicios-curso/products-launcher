#!/usr/bin/env bash
#
# seed-products.sh
#
# Llena la base de datos de productos con datos mock de tecnologia.
# Crea N productos aleatorios a traves del API Gateway (POST /api/products).
#
# Uso:
#   ./seed-products.sh [count] [base_url]
#
# Ejemplos:
#   ./seed-products.sh                          # 100 productos en http://localhost:3000
#   ./seed-products.sh 20                       # 20 productos
#   ./seed-products.sh 50 http://localhost:3000 # 50 productos contra otro host
#
# Nota: Product.name tiene constraint UNIQUE, por eso cada nombre lleva un
# sufijo numerico unico (el indice del bucle).

set -uo pipefail

COUNT="${1:-100}"
BASE_URL="${2:-http://localhost:3000}"
ENDPOINT="${BASE_URL%/}/api/products"

BRANDS=(
  Apple Samsung Lenovo Dell HP Asus Acer MSI Xiaomi Sony LG
  Logitech Corsair Razer Kingston HyperX Google Microsoft Huawei
  Motorola Toshiba Alienware Vaio
)

CATEGORIES=(
  Laptop Smartphone Tablet Monitor Teclado Mouse Auriculares Webcam
  Router Smartwatch SSD GPU CPU RAM Microfono Parlante Consola
  Camara Proyector Dock Hub
)

QUALIFIERS=(
  Pro Max Ultra Air Plus Mini Gaming Lite Turbo Neo Prime
  Elite Zenbook ThinkPad Ideapad Pavilion Aspire Predator
)

SPECS=(
  X1000 X2000 G15 G16 M2 M3 RTX4080 RTX5090 i7 i9 Ryzen9
  4K 8K Gen5 Wifi6 OLED 32GB 16GB 1TB NVMe
)

echo "Creando ${COUNT} productos de tecnologia en ${ENDPOINT} ..."
echo

created=0
errors=0

for (( i=1; i<=COUNT; i++ )); do
  brand=${BRANDS[$((RANDOM % ${#BRANDS[@]}))]}
  category=${CATEGORIES[$((RANDOM % ${#CATEGORIES[@]}))]}
  qualifier=${QUALIFIERS[$((RANDOM % ${#QUALIFIERS[@]}))]}
  spec=${SPECS[$((RANDOM % ${#SPECS[@]}))]}
  suffix=$(printf '%04d' "$i")

  name="${brand} ${category} ${qualifier} ${spec} ${suffix}"

  # Precio aleatorio entre 50.00 y 3000.00
  price="$((RANDOM % 2951 + 50)).$(printf '%02d' "$((RANDOM % 100))")"

  payload=$(printf '{"name":"%s","price":%s}' "$name" "$price")

  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$ENDPOINT" \
    -H 'Content-Type: application/json' \
    -d "$payload")

  if [[ "$http_code" == "201" ]]; then
    (( created++ ))
    printf '[%3d/%d] 201 Created  %-55s $%s\n' "$i" "$COUNT" "$name" "$price"
  else
    (( errors++ ))
    printf '[%3d/%d] ERROR %s    %-55s $%s\n' "$i" "$COUNT" "$http_code" "$name" "$price"
  fi
done

echo
echo "Listo: ${created}/${COUNT} productos creados, ${errors} errores."
