#!/bin/bash
# Проверяем, запущен ли PostgreSQL

if sudo -u postgres pg_isready -h 127.0.0.1 -U postgres -t 3 >/dev/null 2>&1; then
    exit 0
else
    exit 1
fi
