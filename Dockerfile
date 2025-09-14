# Dockerfile para la API Flask de pedidos en línea
FROM python:3.11-slim

# Información del mantenedor
LABEL maintainer="orders-api@example.com"
LABEL description="Flask REST API para gestión de pedidos con autenticación y rate limiting"

# Configurar variables de entorno
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV FLASK_APP=app.py
ENV FLASK_ENV=production

# Crear directorio de trabajo
WORKDIR /app

# Crear usuario no-root por seguridad
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Instalar dependencias del sistema
RUN apt-get update && apt-get install -y \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copiar y instalar dependencias de Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiar código de la aplicación
COPY app.py .
COPY scripts/ ./scripts/

# Crear directorio para logs
RUN mkdir -p /app/logs && chown -R appuser:appuser /app

# Cambiar a usuario no-root
USER appuser

# Exponer puerto
EXPOSE 5000

# Health check para Docker
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:5000/api/health || exit 1

# Comando por defecto
CMD ["python", "app.py"]