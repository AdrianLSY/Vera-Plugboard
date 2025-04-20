#!/bin/bash

# Run migrations
/app/bin/plugboard eval "Plugboard.Release.migrate()"

# Start the phoenix server
exec /app/bin/server
