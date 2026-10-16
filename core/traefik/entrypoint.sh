#!/bin/sh
# Render the traefik.yml template, replacing ${VAR} placeholders with environment variables, then start Traefik
set -e

awk '{
  while (match($0, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
    name = substr($0, RSTART + 2, RLENGTH - 3)
    if (!(name in ENVIRON)) {
      print "entrypoint.sh: environment variable " name " is not set" > "/dev/stderr"
      exit 1
    }
    $0 = substr($0, 1, RSTART - 1) ENVIRON[name] substr($0, RSTART + RLENGTH)
  }
  print
}' /config/traefik.yml > /tmp/traefik.yml

exec /entrypoint.sh --configFile=/tmp/traefik.yml "$@"
