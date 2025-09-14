#!/usr/bin/env python3
"""
Flask REST API para gestión de pedidos en línea
Implementa:
- CRUD de pedidos (crear, listar, consultar por ID)
- Autenticación por token JWT
- Rate limiting por usuario
- Reintentos automáticos ante fallos
- Replicación con Docker Compose
"""

import os
import time
import logging
import functools
from datetime import datetime, timedelta
from typing import Dict, List, Optional

from flask import Flask, request, jsonify
from flask_jwt_extended import (
    JWTManager, create_access_token, jwt_required, 
    get_jwt_identity, get_jwt
)
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import redis
from werkzeug.security import generate_password_hash, check_password_hash

# Configuración de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuración de la aplicación
app.config['JWT_SECRET_KEY'] = os.getenv('JWT_SECRET_KEY', 'dev-secret-key-change-in-production')
app.config['JWT_ACCESS_TOKEN_EXPIRES'] = timedelta(hours=1)
app.config['REDIS_URL'] = os.getenv('REDIS_URL', 'redis://redis:6379')

# Inicialización de extensiones
jwt = JWTManager(app)

# Configuración de Redis para rate limiting
try:
    redis_client = redis.from_url(app.config['REDIS_URL'])
    redis_client.ping()
    logger.info("Conectado a Redis exitosamente")
except Exception as e:
    logger.warning(f"No se pudo conectar a Redis: {e}. Usando storage en memoria.")
    redis_client = None

# Configuración del limitador de velocidad
limiter = Limiter(
    app=app,
    key_func=lambda: get_jwt_identity() or get_remote_address(),
    storage_uri=app.config['REDIS_URL'] if redis_client else "memory://",
    default_limits=["200 per day", "50 per hour"]
)

# Almacenamiento en memoria (en producción usar base de datos)
users_db = {}  # {username: {password_hash, user_id}}
orders_db = {}  # {order_id: order_data}
blacklisted_tokens = set()  # Para invalidación de tokens
order_counter = 0

def retry_on_failure(max_retries=3, delay=1):
    """
    Decorador para reintentar operaciones que pueden fallar
    """
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(max_retries):
                try:
                    return func(*args, **kwargs)
                except Exception as e:
                    logger.warning(f"Intento {attempt + 1} falló: {str(e)}")
                    if attempt == max_retries - 1:
                        raise
                    time.sleep(delay * (2 ** attempt))  # Backoff exponencial
            return None
        return wrapper
    return decorator

@jwt.token_in_blocklist_loader
def check_if_token_revoked(jwt_header, jwt_payload):
    """Verificar si el token JWT está en la lista negra"""
    return jwt_payload['jti'] in blacklisted_tokens

# ============ ENDPOINTS DE AUTENTICACIÓN ============

@app.route('/api/register', methods=['POST'])
@limiter.limit("5 per minute")
def register():
    """
    Registrar un nuevo usuario
    """
    try:
        data = request.get_json()
        
        if not data or 'username' not in data or 'password' not in data:
            return jsonify({'error': 'Username y password son requeridos'}), 400
        
        username = data['username']
        password = data['password']
        
        if username in users_db:
            return jsonify({'error': 'Usuario ya existe'}), 409
        
        # Validación básica de password
        if len(password) < 6:
            return jsonify({'error': 'Password debe tener al menos 6 caracteres'}), 400
        
        # Crear usuario
        user_id = len(users_db) + 1
        users_db[username] = {
            'password_hash': generate_password_hash(password),
            'user_id': user_id,
            'created_at': datetime.utcnow().isoformat()
        }
        
        logger.info(f"Usuario registrado: {username}")
        return jsonify({
            'message': 'Usuario registrado exitosamente',
            'user_id': user_id
        }), 201
        
    except Exception as e:
        logger.error(f"Error en registro: {str(e)}")
        return jsonify({'error': 'Error interno del servidor'}), 500

@app.route('/api/login', methods=['POST'])
@limiter.limit("10 per minute")
def login():
    """
    Autenticar usuario y generar token JWT
    """
    try:
        data = request.get_json()
        
        if not data or 'username' not in data or 'password' not in data:
            return jsonify({'error': 'Username y password son requeridos'}), 400
        
        username = data['username']
        password = data['password']
        
        if username not in users_db:
            return jsonify({'error': 'Credenciales inválidas'}), 401
        
        user = users_db[username]
        if not check_password_hash(user['password_hash'], password):
            return jsonify({'error': 'Credenciales inválidas'}), 401
        
        # Crear token JWT
        access_token = create_access_token(identity=username)
        
        logger.info(f"Login exitoso: {username}")
        return jsonify({
            'access_token': access_token,
            'user_id': user['user_id'],
            'expires_in': app.config['JWT_ACCESS_TOKEN_EXPIRES'].total_seconds()
        }), 200
        
    except Exception as e:
        logger.error(f"Error en login: {str(e)}")
        return jsonify({'error': 'Error interno del servidor'}), 500

@app.route('/api/logout', methods=['POST'])
@jwt_required()
def logout():
    """
    Cerrar sesión e invalidar token
    """
    try:
        jti = get_jwt()['jti']
        blacklisted_tokens.add(jti)
        
        username = get_jwt_identity()
        logger.info(f"Logout exitoso: {username}")
        return jsonify({'message': 'Logout exitoso'}), 200
        
    except Exception as e:
        logger.error(f"Error en logout: {str(e)}")
        return jsonify({'error': 'Error interno del servidor'}), 500

# ============ ENDPOINTS DE PEDIDOS ============

@app.route('/api/orders', methods=['POST'])
@jwt_required()
@limiter.limit("30 per minute")
@retry_on_failure(max_retries=3)
def create_order():
    """
    Crear un nuevo pedido
    """
    try:
        global order_counter
        
        data = request.get_json()
        username = get_jwt_identity()
        
        # Validación de datos requeridos
        required_fields = ['customer_name', 'items', 'total_amount']
        if not data or not all(field in data for field in required_fields):
            return jsonify({'error': 'Campos requeridos: customer_name, items, total_amount'}), 400
        
        if not isinstance(data['items'], list) or len(data['items']) == 0:
            return jsonify({'error': 'Items debe ser una lista no vacía'}), 400
        
        if not isinstance(data['total_amount'], (int, float)) or data['total_amount'] <= 0:
            return jsonify({'error': 'Total amount debe ser un número positivo'}), 400
        
        # Crear pedido
        order_counter += 1
        order_id = f"ORD-{order_counter:06d}"
        
        order = {
            'order_id': order_id,
            'customer_name': data['customer_name'],
            'items': data['items'],
            'total_amount': float(data['total_amount']),
            'status': 'pending',
            'created_by': username,
            'created_at': datetime.utcnow().isoformat(),
            'updated_at': datetime.utcnow().isoformat()
        }
        
        # Agregar campos opcionales
        if 'delivery_address' in data:
            order['delivery_address'] = data['delivery_address']
        if 'notes' in data:
            order['notes'] = data['notes']
        
        orders_db[order_id] = order
        
        logger.info(f"Pedido creado: {order_id} por usuario {username}")
        return jsonify({
            'message': 'Pedido creado exitosamente',
            'order': order
        }), 201
        
    except Exception as e:
        logger.error(f"Error creando pedido: {str(e)}")
        return jsonify({'error': 'Error interno del servidor'}), 500

@app.route('/api/orders', methods=['GET'])
@jwt_required()
@limiter.limit("100 per minute")
@retry_on_failure(max_retries=3)
def list_orders():
    """
    Listar pedidos con paginación y filtros
    """
    try:
        username = get_jwt_identity()
        
        # Parámetros de consulta
        page = int(request.args.get('page', 1))
        per_page = min(int(request.args.get('per_page', 10)), 100)  # Máximo 100 por página
        status = request.args.get('status')
        customer_name = request.args.get('customer_name')
        
        # Filtrar pedidos
        filtered_orders = []
        for order in orders_db.values():
            # Filtro por estado
            if status and order['status'] != status:
                continue
            
            # Filtro por nombre de cliente (búsqueda parcial)
            if customer_name and customer_name.lower() not in order['customer_name'].lower():
                continue
            
            filtered_orders.append(order)
        
        # Ordenar por fecha de creación (más recientes primero)
        filtered_orders.sort(key=lambda x: x['created_at'], reverse=True)
        
        # Paginación
        start_idx = (page - 1) * per_page
        end_idx = start_idx + per_page
        paginated_orders = filtered_orders[start_idx:end_idx]
        
        total_orders = len(filtered_orders)
        total_pages = (total_orders + per_page - 1) // per_page
        
        logger.info(f"Lista de pedidos consultada por {username}: {len(paginated_orders)} resultados")
        return jsonify({
            'orders': paginated_orders,
            'pagination': {
                'page': page,
                'per_page': per_page,
                'total_orders': total_orders,
                'total_pages': total_pages,
                'has_next': page < total_pages,
                'has_prev': page > 1
            }
        }), 200
        
    except ValueError:
        return jsonify({'error': 'Parámetros de paginación inválidos'}), 400
    except Exception as e:
        logger.error(f"Error listando pedidos: {str(e)}")
        return jsonify({'error': 'Error interno del servidor'}), 500

@app.route('/api/orders/<order_id>', methods=['GET'])
@jwt_required()
@limiter.limit("200 per minute")
@retry_on_failure(max_retries=3)
def get_order(order_id):
    """
    Consultar pedido por ID
    """
    try:
        username = get_jwt_identity()
        
        if order_id not in orders_db:
            return jsonify({'error': 'Pedido no encontrado'}), 404
        
        order = orders_db[order_id]
        
        logger.info(f"Pedido consultado: {order_id} por usuario {username}")
        return jsonify({'order': order}), 200
        
    except Exception as e:
        logger.error(f"Error consultando pedido {order_id}: {str(e)}")
        return jsonify({'error': 'Error interno del servidor'}), 500

@app.route('/api/orders/<order_id>', methods=['PUT'])
@jwt_required()
@limiter.limit("20 per minute")
@retry_on_failure(max_retries=3)
def update_order(order_id):
    """
    Actualizar estado del pedido
    """
    try:
        username = get_jwt_identity()
        data = request.get_json()
        
        if order_id not in orders_db:
            return jsonify({'error': 'Pedido no encontrado'}), 404
        
        if not data or 'status' not in data:
            return jsonify({'error': 'Status es requerido'}), 400
        
        valid_statuses = ['pending', 'processing', 'shipped', 'delivered', 'cancelled']
        if data['status'] not in valid_statuses:
            return jsonify({'error': f'Status inválido. Valores válidos: {valid_statuses}'}), 400
        
        order = orders_db[order_id]
        order['status'] = data['status']
        order['updated_at'] = datetime.utcnow().isoformat()
        
        logger.info(f"Pedido actualizado: {order_id} por usuario {username}")
        return jsonify({
            'message': 'Pedido actualizado exitosamente',
            'order': order
        }), 200
        
    except Exception as e:
        logger.error(f"Error actualizando pedido {order_id}: {str(e)}")
        return jsonify({'error': 'Error interno del servidor'}), 500

# ============ ENDPOINTS DE SISTEMA ============

@app.route('/api/health', methods=['GET'])
def health_check():
    """
    Verificación de salud del servicio
    """
    try:
        # Verificar conexión a Redis
        redis_status = "connected"
        if redis_client:
            redis_client.ping()
        else:
            redis_status = "not_connected"
        
        return jsonify({
            'status': 'healthy',
            'timestamp': datetime.utcnow().isoformat(),
            'version': '1.0.0',
            'services': {
                'redis': redis_status,
                'orders_count': len(orders_db),
                'users_count': len(users_db)
            }
        }), 200
        
    except Exception as e:
        logger.error(f"Error en health check: {str(e)}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 503

@app.route('/api/stats', methods=['GET'])
@jwt_required()
@limiter.limit("10 per minute")
def get_stats():
    """
    Estadísticas del sistema (requiere autenticación)
    """
    try:
        username = get_jwt_identity()
        
        # Calcular estadísticas
        status_counts = {}
        user_orders = {}
        total_amount = 0
        
        for order in orders_db.values():
            # Contar por status
            status = order['status']
            status_counts[status] = status_counts.get(status, 0) + 1
            
            # Contar por usuario
            creator = order['created_by']
            user_orders[creator] = user_orders.get(creator, 0) + 1
            
            # Sumar amounts
            total_amount += order['total_amount']
        
        logger.info(f"Estadísticas consultadas por {username}")
        return jsonify({
            'total_orders': len(orders_db),
            'total_users': len(users_db),
            'total_amount': round(total_amount, 2),
            'orders_by_status': status_counts,
            'orders_by_user': user_orders
        }), 200
        
    except Exception as e:
        logger.error(f"Error obteniendo estadísticas: {str(e)}")
        return jsonify({'error': 'Error interno del servidor'}), 500

# ============ MANEJO DE ERRORES ============

@app.errorhandler(404)
def not_found(error):
    return jsonify({'error': 'Endpoint no encontrado'}), 404

@app.errorhandler(405)
def method_not_allowed(error):
    return jsonify({'error': 'Método no permitido'}), 405

@app.errorhandler(429)
def rate_limit_exceeded(error):
    return jsonify({'error': 'Límite de velocidad excedido. Intenta más tarde.'}), 429

@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Error interno del servidor'}), 500

if __name__ == '__main__':
    # Configuración para desarrollo
    port = int(os.getenv('PORT', 5000))
    debug = os.getenv('FLASK_ENV') == 'development'
    
    logger.info(f"Iniciando servidor en puerto {port}")
    app.run(host='0.0.0.0', port=port, debug=debug)