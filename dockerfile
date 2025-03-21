FROM elixir:1.18.2-alpine AS build

# Install build dependencies
RUN apk add --no-cache git

# Set working directory
WORKDIR /app

# Set Mix env to prod
ENV MIX_ENV=prod

# Copy only the files needed for dependency installation first
COPY mix.exs mix.lock ./

# Install mix dependencies
RUN mix deps.get

# Now copy the rest of the application code
COPY assets ./assets
COPY config ./config
COPY lib ./lib
COPY priv ./priv
COPY .formatter.exs ./

# Compile and create release
RUN mix do compile, release

# Start a new build stage
FROM erlang:27-alpine

WORKDIR /app

# Copy the release from the build stage
COPY --from=build /app/_build/prod/rel/vera /app/

# Set the command to run the release
CMD ["/app/bin/vera", "start"]