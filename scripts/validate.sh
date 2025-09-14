#!/bin/bash
#
# Script de validación para verificar la configuración antes del despliegue
#

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[VALIDATION] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

validate_docker() {
    log "Validando configuración de Docker..."
    
    if ! docker --version > /dev/null 2>&1; then
        error "Docker no está instalado"
        return 1
    fi
    
    if ! docker compose version > /dev/null 2>&1; then
        error "Docker Compose no está instalado"
        return 1
    fi
    
    log "Docker validado ✓"
}

validate_files() {
    log "Validando archivos de configuración..."
    
    local files=(
        "app.py"
        "requirements.txt"
        "Dockerfile"
        "docker-compose.yml"
        "nginx.conf"
        "scripts/start.sh"
        "scripts/demo.sh"
        "examples.sh"
    )
    
    for file in "${files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error "Archivo faltante: $file"
            return 1
        fi
    done
    
    log "Archivos de configuración validados ✓"
}

validate_syntax() {
    log "Validando sintaxis de archivos..."
    
    # Validar Python
    if ! python3 -m py_compile app.py; then
        error "Error de sintaxis en app.py"
        return 1
    fi
    
    # Validar YAML
    if ! python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))" 2>/dev/null; then
        error "Error de sintaxis en docker-compose.yml"
        return 1
    fi
    
    # Validar NGINX config (aproximado)
    if ! grep -q "upstream orders_api" nginx.conf; then
        error "Configuración de NGINX incompleta"
        return 1
    fi
    
    log "Sintaxis validada ✓"
}

validate_ports() {
    log "Verificando disponibilidad de puertos..."
    
    local ports=(8080 8081)
    
    for port in "${ports[@]}"; do
        if ss -ln | grep -q ":$port "; then
            warn "Puerto $port está en uso. Puede causar conflictos."
        fi
    done
    
    log "Puertos verificados ✓"
}

validate_system_resources() {
    log "Verificando recursos del sistema..."
    
    # Verificar memoria (al menos 1GB libre)
    local available_mem=$(free -m | awk 'NR==2{printf "%.0f", $7}')
    if [[ $available_mem -lt 1000 ]]; then
        warn "Memoria disponible baja: ${available_mem}MB"
    fi
    
    # Verificar espacio en disco (al menos 2GB)
    local available_disk=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_disk -lt 2 ]]; then
        warn "Espacio en disco bajo: ${available_disk}GB"
    fi
    
    log "Recursos del sistema verificados ✓"
}

run_syntax_tests() {
    log "Ejecutando pruebas de sintaxis adicionales..."
    
    # Test básico de importación de Flask
    if ! python3 -c "
import sys
sys.path.append('.')
from app import app
print('Flask app imported successfully')
" 2>/dev/null; then
        error "No se pudo importar la aplicación Flask"
        return 1
    fi
    
    log "Pruebas de sintaxis completadas ✓"
}

main() {
    echo -e "${GREEN}
╔════════════════════════════════════════════════════════╗
║                  VALIDACIÓN DEL SISTEMA                ║
║               Verificando configuración                ║
╚════════════════════════════════════════════════════════╝
    ${NC}"
    
    validate_docker
    validate_files  
    validate_syntax
    validate_ports
    validate_system_resources
    run_syntax_tests
    
    echo -e "${GREEN}
╔════════════════════════════════════════════════════════╗
║              ✅ VALIDACIÓN COMPLETADA                  ║
║                                                        ║
║  El sistema está listo para ser desplegado            ║
║  Ejecuta './scripts/start.sh' para iniciar           ║
╚════════════════════════════════════════════════════════╝
    ${NC}"
}

main "$@"