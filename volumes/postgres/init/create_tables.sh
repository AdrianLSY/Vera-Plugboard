#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE vera_development;
    CREATE DATABASE vera_test;
    CREATE DATABASE vera_production;
EOSQL
