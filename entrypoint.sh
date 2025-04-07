#!/bin/bash

# Run migrations
/app/bin/vera eval "Vera.Release.migrate()"

# Start the phoenix server
exec /app/bin/server
