#!/bin/bash

ROOT_DIR=$(cd $(dirname $0)/..; pwd)
DB_DIR="$ROOT_DIR/db"
BENCH_DIR="$ROOT_DIR/bench"

export MYSQL_PWD=isucon

mysql -uisucon -e "DROP DATABASE IF EXISTS torb; CREATE DATABASE torb;"
mysql -uisucon torb < "$DB_DIR/schema.sql"

if [ ! -f "$DB_DIR/isucon8q-initial-dataset.sql.gz" ]; then
  echo "Run the following command beforehand." 1>&2
  echo "$ ( cd \"$BENCH_DIR\" && bin/gen-initial-dataset )" 1>&2
  exit 1
fi

gzip -dc "$DB_DIR/isucon8q-initial-dataset.sql.gz" \
    | perl -MTime::Moment -pe 's/"([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})",\s*(?:NULL|"([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})")/$t1=Time::Moment->from_string($1.'Z', lenient => 1)->epoch;$t2=$2 ? Time::Moment->from_string($2.'Z', lenient => 1)->epoch : 0;$t3=$t2 > $t1 ? $t2 : $t1;$t2||="NULL";"$t1, $t2, $t3"/eg;s/canceled_at\)/canceled_at, updated_at\)/g' \
    | mysql -uisucon torb
