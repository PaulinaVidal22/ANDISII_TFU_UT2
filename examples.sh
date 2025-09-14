# Ejemplos de uso con curl - API de Pedidos
# Sistema completo con autenticación, rate limiting y replicación

# =============================================================================
# CONFIGURACIÓN INICIAL
# =============================================================================

# URL base de la API (a través del load balancer)
export API_URL="http://localhost:8080/api"

# Usuario de prueba
export TEST_USER="testuser"
export TEST_PASSWORD="securepassword123"

# =============================================================================
# 1. VERIFICACIÓN DEL SISTEMA
# =============================================================================

# Health check del sistema
curl -X GET ${API_URL}/health | jq .

# Verificar balanceador de carga NGINX
curl -X GET http://localhost:8080/nginx-health

# Página de información del sistema
curl -X GET http://localhost:8080/

# =============================================================================
# 2. AUTENTICACIÓN - REGISTRO Y LOGIN
# =============================================================================

# 2.1. Registrar un nuevo usuario
curl -X POST ${API_URL}/register \
  -H "Content-Type: application/json" \
  -d "{
    \"username\": \"${TEST_USER}\",
    \"password\": \"${TEST_PASSWORD}\"
  }" | jq .

# 2.2. Iniciar sesión y obtener token
TOKEN=$(curl -X POST ${API_URL}/login \
  -H "Content-Type: application/json" \
  -d "{
    \"username\": \"${TEST_USER}\",
    \"password\": \"${TEST_PASSWORD}\"
  }" | jq -r .access_token)

echo "Token obtenido: $TOKEN"

# 2.3. Intentar acceso sin autenticación (debe fallar)
curl -X GET ${API_URL}/orders
# Respuesta esperada: {"error": "Authorization header is expected"}

# =============================================================================
# 3. GESTIÓN DE PEDIDOS (CRUD)
# =============================================================================

# 3.1. Crear un pedido completo
curl -X POST ${API_URL}/orders \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{
    "customer_name": "María González",
    "items": [
      {
        "name": "Laptop HP",
        "quantity": 1,
        "price": 899.99,
        "sku": "HP-LT-001"
      },
      {
        "name": "Mouse inalámbrico",
        "quantity": 2,
        "price": 25.99,
        "sku": "MS-WL-002"
      }
    ],
    "total_amount": 951.97,
    "delivery_address": "Av. Libertador 1234, CABA, Argentina",
    "notes": "Entrega en horario laboral (9-17hs)"
  }' | jq .

# 3.2. Crear pedido simple
ORDER_RESPONSE=$(curl -s -X POST ${API_URL}/orders \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{
    "customer_name": "Juan Pérez",
    "items": [
      {"name": "Producto A", "quantity": 2}
    ],
    "total_amount": 29.99
  }')

ORDER_ID=$(echo $ORDER_RESPONSE | jq -r .order.order_id)
echo "Pedido creado con ID: $ORDER_ID"

# 3.3. Listar todos los pedidos
curl -X GET ${API_URL}/orders \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# 3.4. Listar pedidos with paginación
curl -X GET "${API_URL}/orders?page=1&per_page=5" \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# 3.5. Filtrar pedidos por estado
curl -X GET "${API_URL}/orders?status=pending" \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# 3.6. Buscar pedidos por nombre de cliente
curl -X GET "${API_URL}/orders?customer_name=María" \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# 3.7. Consultar pedido específico
curl -X GET ${API_URL}/orders/${ORDER_ID} \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# 3.8. Actualizar estado del pedido
curl -X PUT ${API_URL}/orders/${ORDER_ID} \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"status": "processing"}' | jq .

# 3.9. Intentar consultar pedido inexistente
curl -X GET ${API_URL}/orders/INVALID-ORDER-ID \
  -H "Authorization: Bearer ${TOKEN}"
# Respuesta esperada: {"error": "Pedido no encontrado"}

# =============================================================================
# 4. DEMOSTRACIÓN DE RATE LIMITING
# =============================================================================

# 4.1. Hacer múltiples requests rápidas (activará rate limiting)
echo "Probando rate limiting - haciendo requests rápidas:"
for i in {1..15}; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X GET ${API_URL}/orders \
    -H "Authorization: Bearer ${TOKEN}")
  echo "Request $i: HTTP $HTTP_STATUS"
  
  if [ "$HTTP_STATUS" = "429" ]; then
    echo "Rate limiting activado!"
    break
  fi
  sleep 0.1
done

# 4.2. Verificar límites específicos para registro
echo "Probando rate limiting en registro (5 por minuto):"
for i in {1..7}; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST ${API_URL}/register \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"test${i}\", \"password\": \"pass123\"}")
  echo "Register attempt $i: HTTP $HTTP_STATUS"
  
  if [ "$HTTP_STATUS" = "429" ]; then
    echo "Rate limiting en registro activado!"
    break
  fi
  sleep 0.1
done

# =============================================================================
# 5. ESTADÍSTICAS DEL SISTEMA
# =============================================================================

# 5.1. Obtener estadísticas generales (requiere autenticación)
curl -X GET ${API_URL}/stats \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# =============================================================================
# 6. DEMOSTRACIÓN DE REPLICACIÓN Y ALTA DISPONIBILIDAD
# =============================================================================

# 6.1. Verificar diferentes instancias con headers
echo "Verificando distribución de carga entre instancias:"
for i in {1..10}; do
  UPSTREAM=$(curl -s -I ${API_URL}/health | grep -i "x-upstream-server" | cut -d' ' -f2)
  echo "Request $i manejado por: $UPSTREAM"
  sleep 0.2
done

# 6.2. Requests concurrentes para probar disponibilidad
echo "Probando disponibilidad con requests concurrentes:"
for i in {1..5}; do
  {
    RESPONSE=$(curl -s -w "Time: %{time_total}s - Status: %{http_code}" \
      -X GET ${API_URL}/health)
    echo "Concurrent request $i - $RESPONSE"
  } &
done
wait

# =============================================================================
# 7. MANEJO DE ERRORES
# =============================================================================

# 7.1. Datos inválidos en creación de pedido
curl -X POST ${API_URL}/orders \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{
    "customer_name": "",
    "items": [],
    "total_amount": -10
  }'
# Respuesta esperada: Error de validación

# 7.2. Token inválido
curl -X GET ${API_URL}/orders \
  -H "Authorization: Bearer invalid-token"
# Respuesta esperada: Error de autenticación

# 7.3. Login con credenciales incorrectas
curl -X POST ${API_URL}/login \
  -H "Content-Type: application/json" \
  -d '{
    "username": "invalid_user",
    "password": "wrong_password"
  }'
# Respuesta esperada: {"error": "Credenciales inválidas"}

# =============================================================================
# 8. CERRAR SESIÓN
# =============================================================================

# 8.1. Logout (invalida el token)
curl -X POST ${API_URL}/logout \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# 8.2. Intentar usar token después del logout
curl -X GET ${API_URL}/orders \
  -H "Authorization: Bearer ${TOKEN}"
# Respuesta esperada: Error de token revocado

# =============================================================================
# 9. PRUEBAS DE REINTENTOS (CONFIGURACIÓN AUTOMÁTICA)
# =============================================================================

# Los reintentos están configurados automáticamente en:
# - NGINX: proxy_next_upstream para fallos de instancias
# - Flask app: @retry_on_failure decorator en endpoints críticos
# - Docker Compose: restart policies para recuperación automática

# Para simular fallos, puedes parar una instancia:
# docker stop orders-api-1
# Luego hacer requests - NGINX automáticamente reroutea a instancias sanas

# =============================================================================
# 10. MONITOREO CONTINUO
# =============================================================================

# Script para monitoreo continuo de la salud del sistema
echo "Iniciando monitoreo continuo (presiona Ctrl+C para parar):"
while true; do
  HEALTH=$(curl -s ${API_URL}/health | jq -r .status)
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$TIMESTAMP] Sistema: $HEALTH"
  sleep 5
done

# =============================================================================
# NOTAS IMPORTANTES
# =============================================================================

# 1. Rate Limiting:
#    - 200 requests/día, 50/hora por defecto
#    - 5 registros/minuto
#    - 10 logins/minuto
#    - Basado en usuario autenticado o IP

# 2. Autenticación:
#    - Tokens JWT válidos por 1 hora
#    - Logout invalida el token inmediatamente

# 3. Alta Disponibilidad:
#    - 3 instancias de la API
#    - Load balancing con NGINX
#    - Health checks automáticos
#    - Restart automático de contenedores

# 4. Reintentos:
#    - NGINX: 3 reintentos con timeout de 10s
#    - App: @retry_on_failure con backoff exponencial
#    - Docker: restart unless-stopped

# 5. Monitoreo:
#    - http://localhost:8080 - Información del sistema
#    - http://localhost:8080/api/health - Health check
#    - http://localhost:8081 - Dashboard de monitoreo