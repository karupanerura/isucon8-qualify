#!/bin/bash
set -ue

export DB_DATABASE=torb
export DB_HOST=localhost
export DB_PORT=3306
export DB_USER=isucon
export DB_PASS=isucon
export REDIS_HOST=localhost

exec plackup -p 8080 -s Monoceros -MCarp::Always -e 'enable "Static", path => qr!^/(?:(?:css|js|img)/|favicon\.ico$)!, root => "./public"' --max-workers 8 --min-reqs-per-child 4096 --max-reqs-per-child 8192 --timeout 3 -E production -a app.psgi
