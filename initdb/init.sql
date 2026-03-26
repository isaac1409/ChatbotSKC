-- Crear bases de datos
CREATE DATABASE evolutiondb;
CREATE DATABASE n8ndb;

-- Conectarse a n8ndb
\c n8ndb;

-- Tabla clientes
CREATE TABLE clientes (
    id serial PRIMARY KEY,
    numero varchar UNIQUE NOT NULL,
    nombre text NOT NULL,
    email text,
    fecha_creacion timestamp DEFAULT now()
);

-- Tabla conversaciones
CREATE TABLE conversaciones (
    id serial PRIMARY KEY,
    numero varchar NOT NULL,
    rol varchar(10) NOT NULL,
    tipo varchar(10) DEFAULT 'texto',
    mensaje text,
    archivo_url text,
    archivo_nombre text,
    relevante boolean DEFAULT false,
    fecha timestamp DEFAULT now(),
    CONSTRAINT fk_cliente
        FOREIGN KEY (numero)
        REFERENCES clientes(numero)
);