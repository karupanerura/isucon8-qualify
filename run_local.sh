#!/bin/bash
set -ue

rm -rf ./webapp/perl/.xslate_cache

envfile ./webapp/env-local.sh start_server --path ./tmp/torb.sock --pid-file ./run/torb.pid -- \
             plackup -s Gazelle \
             --min-reqs-per-child 4096 \
             --max-reqs-per-child 8192 \
             --max-workers 16 \
             --timeout 3 \
             -E production \
             -a ./webapp/perl/app.psgi &

h2o -c ./h2o-local.conf &

trap 'kill $(cat ./run/*.pid)' INT
trap 'kill $(cat ./run/*.pid)' TERM
trap 'kill $(cat ./run/*.pid)' QUIT
wait
