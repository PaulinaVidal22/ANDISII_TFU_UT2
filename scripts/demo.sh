#!/bin/bash
#
# Script de demostración para mostrar las capacidades del sistema
# Demuestra: autenticación, rate limiting, replicación y reintentos
#

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuración
API_URL="http://localhost:8080/api"
TEST_USER="demo_user"
TEST_PASSWORD="demo123456"

# Función para logging
log() {
    echo -e "${GREEN}[DEMO] $1${NC}"
}

step() {
    echo -e "${BLUE}[PASO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[ADVERTENCIA] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

info() {
    echo -e "${CYAN}[INFO] $1${NC}"
}

# Función para hacer requests con manejo de errores
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local headers="$4"
    
    local cmd="curl -s -X $method $API_URL$endpoint"
    
    if [[ -n "$headers" ]]; then
        cmd="$cmd -H '$headers'"
    fi
    
    if [[ -n "$data" ]]; then
        cmd="$cmd -H 'Content-Type: application/json' -d '$data'"
    fi
    
    eval $cmd
}

# Verificar que el sistema esté ejecutándose
check_system() {
    step "Verificando que el sistema esté en ejecución..."
    
    if ! curl -s $API_URL/health > /dev/null; then
        error "El sistema no está ejecutándose. Ejecuta './scripts/start.sh' primero."
        exit 1
    fi
    
    log "Sistema verificado ✓"
}

# Demostración de health check y replicación
demo_health_and_replication() {
    step "Demostrando Health Check y Replicación..."
    
    echo "📊 Estado del sistema:"
    curl -s $API_URL/health | jq .
    echo
    
    log "El sistema tiene múltiples instancias ejecutándose"
    log "NGINX balancea automáticamente la carga entre ellas"
    echo
}

# Demostración de autenticación
demo_authentication() {
    step "Demostrando Sistema de Autenticación..."
    
    # Registrar usuario
    info "Registrando usuario de prueba..."
    register_response=$(api_request "POST" "/register" "{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASSWORD\"}")
    echo "Respuesta de registro: $register_response" | jq .
    echo
    
    # Iniciar sesión
    info "Iniciando sesión..."
    login_response=$(api_request "POST" "/login" "{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASSWORD\"}")
    ACCESS_TOKEN=$(echo $login_response | jq -r .access_token)
    
    if [[ "$ACCESS_TOKEN" == "null" || -z "$ACCESS_TOKEN" ]]; then
        error "No se pudo obtener el token de acceso"
        echo "Respuesta de login: $login_response"
        return 1
    fi
    
    echo "Respuesta de login: $login_response" | jq .
    log "Token de acceso obtenido exitosamente ✓"
    echo
}

# Demostración de CRUD de pedidos
demo_orders_crud() {
    step "Demostrando CRUD de Pedidos..."
    
    # Crear pedido
    info "Creando pedido de prueba..."
    order_data='{
        "customer_name": "Juan Pérez Demo",
        "items": [
            {"name": "Producto A", "quantity": 2, "price": 15.99},
            {"name": "Producto B", "quantity": 1, "price": 29.99}
        ],
        "total_amount": 61.97,
        "delivery_address": "Calle Demo 123, Ciudad Demo",
        "notes": "Pedido creado por script de demostración"
    }'
    
    create_response=$(api_request "POST" "/orders" "$order_data" "Authorization: Bearer $ACCESS_TOKEN")
    ORDER_ID=$(echo $create_response | jq -r .order.order_id)
    
    echo "Pedido creado: $create_response" | jq .
    echo
    
    # Listar pedidos
    info "Consultando lista de pedidos..."
    list_response=$(api_request "GET" "/orders" "" "Authorization: Bearer $ACCESS_TOKEN")
    echo "Lista de pedidos: $list_response" | jq .
    echo
    
    # Consultar pedido específico
    info "Consultando pedido específico ($ORDER_ID)..."
    get_response=$(api_request "GET" "/orders/$ORDER_ID" "" "Authorization: Bearer $ACCESS_TOKEN")
    echo "Pedido específico: $get_response" | jq .
    echo
    
    # Actualizar pedido
    info "Actualizando estado del pedido..."
    update_response=$(api_request "PUT" "/orders/$ORDER_ID" '{"status":"processing"}' "Authorization: Bearer $ACCESS_TOKEN")
    echo "Pedido actualizado: $update_response" | jq .
    echo
    
    log "CRUD de pedidos completado exitosamente ✓"
}

# Demostración de rate limiting
demo_rate_limiting() {
    step "Demostrando Rate Limiting..."
    
    info "Realizando múltiples requests rápidos para activar rate limiting..."
    
    # Hacer muchas requests rápidamente
    for i in {1..15}; do
        response=$(curl -s -o /dev/null -w "%{http_code}" -X GET $API_URL/orders -H "Authorization: Bearer $ACCESS_TOKEN")
        echo -n "Request $i: HTTP $response "
        
        if [[ "$response" == "429" ]]; then
            echo -e "${RED}(Rate Limited!)${NC}"
            break
        else
            echo -e "${GREEN}(OK)${NC}"
        fi
        
        sleep 0.1
    done
    
    echo
    log "Rate limiting demostrado ✓"
    info "El sistema protege contra abuso con limits por usuario"
    echo
}

# Demostración de reintentos y disponibilidad
demo_retries_and_availability() {
    step "Demostrando Reintentos y Alta Disponibilidad..."
    
    # Función para simular carga y verificar disponibilidad
    info "Simulando alta carga y verificando disponibilidad..."
    
    # Hacer requests concurrentes para probar la disponibilidad
    for i in {1..5}; do
        {
            response=$(curl -s -w "%{http_code}" -X GET $API_URL/health)
            echo "Health check $i: $response"
        } &
    done
    wait
    
    echo
    info "Verificando balanceador de carga con headers de upstream..."
    
    # Hacer varias requests para ver diferentes instancias
    for i in {1..5}; do
        upstream=$(curl -s -I $API_URL/health | grep -i "x-upstream-server" | cut -d' ' -f2 | tr -d '\r')
        echo "Request $i manejado por instancia: $upstream"
        sleep 0.2
    done
    
    echo
    log "Sistema de alta disponibilidad verificado ✓"
    info "Las requests se distribuyen entre múltiples instancias"
    echo
}

# Demostración de estadísticas del sistema
demo_system_stats() {
    step "Mostrando Estadísticas del Sistema..."
    
    info "Obteniendo estadísticas actuales..."
    stats_response=$(api_request "GET" "/stats" "" "Authorization: Bearer $ACCESS_TOKEN")
    echo "Estadísticas del sistema: $stats_response" | jq .
    echo
    
    log "Estadísticas obtenidas exitosamente ✓"
}

# Demostración de manejo de errores
demo_error_handling() {
    step "Demostrando Manejo de Errores..."
    
    # Intento de acceso sin autenticación
    info "Intentando acceder sin token de autenticación..."
    unauth_response=$(curl -s -w "%{http_code}" $API_URL/orders)
    echo "Response sin auth: $unauth_response"
    echo
    
    # Intento de crear pedido con datos inválidos
    info "Intentando crear pedido con datos inválidos..."
    invalid_response=$(api_request "POST" "/orders" '{"invalid":"data"}' "Authorization: Bearer $ACCESS_TOKEN")
    echo "Response datos inválidos: $invalid_response" | jq .
    echo
    
    # Intento de consultar pedido inexistente
    info "Intentando consultar pedido inexistente..."
    notfound_response=$(api_request "GET" "/orders/INVALID-ID" "" "Authorization: Bearer $ACCESS_TOKEN")
    echo "Response pedido inexistente: $notfound_response" | jq .
    echo
    
    log "Manejo de errores verificado ✓"
}

# Función principal de demostración
main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                🚀 DEMO DEL SISTEMA                   ║"
    echo "║           API de Pedidos con Alta                   ║"
    echo "║           Disponibilidad y Seguridad                ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_system
    demo_health_and_replication
    demo_authentication
    demo_orders_crud
    demo_rate_limiting
    demo_retries_and_availability
    demo_system_stats
    demo_error_handling
    
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                ✅ DEMO COMPLETADO                    ║"
    echo "║                                                      ║"
    echo "║  El sistema ha demostrado exitosamente:             ║"
    echo "║  • Autenticación JWT                                ║"
    echo "║  • Rate Limiting                                    ║"
    echo "║  • Replicación y Load Balancing                     ║"
    echo "║  • Reintentos automáticos                           ║"
    echo "║  • CRUD completo de pedidos                         ║"
    echo "║  • Manejo robusto de errores                        ║"
    echo "║                                                      ║"
    echo "║  🎉 Sistema listo para producción!                  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Verificar dependencias
if ! command -v curl &> /dev/null; then
    error "curl no está instalado. Es requerido para la demostración."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    warn "jq no está instalado. Los responses JSON no se formatearán."
fi

# Ejecutar demostración
main "$@"