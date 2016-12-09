#!/bin/bash
#
# Usage: data-store-check.sh [HOST [PORT [USER [CUTOFF_TIME [DEBUG]]]]]
#
# This script generates two reports, one for collections and one for data 
# objects. Each report lists all collections or data objects, respectively, that
# where created before the cutoff data and are missing the own permission for 
# the rodsadmin group or don't have one and only one UUID assigned to it.
# 
# HOST is the domain name or IP address of the server where the PostgreSQL DBMS
# containing the ICAT DB runs. The default value is 'localhost'.
#
# PORT is the TCP port the DBMS listens on. The default value is '5432'.
#
# USER is the user used to authenticate the connection to the DB. The default
# value is 'irods'.
#
# CUTOFF_TIME is the upper bound of the creation time for the collections and 
# data objects contained in the reports. The format should be the default format
# used by `date`. The default value is today '00:00:00' in the local time zone.
#
# DEBUG is any value that, if present, will cause the script to generate
# describing what it is doing. It is not present by default.

set -e

if [ "$#" -ge 1 ]
then
  readonly HOST="$1"
else
  readonly HOST=localhost
fi

if [ "$#" -ge 2 ]
then
  readonly PORT="$2"
else
  readonly PORT=5432
fi

if [ "$#" -ge 3 ]
then
  readonly USER="$3"
else
  readonly USER=irods
fi

if [ "$#" -ge 4 ]
then
  readonly CUTOFF_TIME="$4"
else
  readonly CUTOFF_TIME=$(date -I --date=today)
fi

if [ "$#" -ge 5 ]
then
  readonly DEBUG=1
fi


display_problems() 
{
  local cutoffTS=$(date --date="$CUTOFF_TIME" '+0%s')

  psql --host "$HOST" --port "$PORT" ICAT "$USER" <<EOF
\timing on

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

CREATE TEMPORARY TABLE owned_by_rodsadmin
AS 
  SELECT a.object_id
  FROM r_objt_access AS a JOIN r_user_main AS u ON u.user_id = a.user_id 
  WHERE u.user_name = 'rodsadmin'
    AND a.access_type_id =
      (SELECT token_id 
       FROM r_tokn_main 
       WHERE token_namespace = 'access_type' AND token_name = 'own');

CREATE TEMPORARY TABLE coll_perm_probs
AS 
  SELECT coll_id
  FROM r_coll_main AS c
  WHERE NOT EXISTS (SELECT * FROM owned_by_rodsadmin AS o WHERE o.object_id = c.coll_id);

CREATE TEMPORARY TABLE data_perm_probs
AS 
  SELECT data_id
  FROM r_data_main AS d
  WHERE data_repl_num = 0
    AND NOT EXISTS (SELECT * FROM owned_by_rodsadmin AS o WHERE o.object_id = d.data_id);

CREATE TEMPORARY TABLE uuid_attrs
AS 
  SELECT o.object_id
  FROM r_objt_metamap AS o JOIN r_meta_main AS m ON m.meta_id = o.meta_id 
  WHERE m.meta_attr_name = 'ipc_UUID';

CREATE TEMPORARY TABLE coll_uuid_probs (coll_id, uuid_count)
AS 
  SELECT c.coll_id, COUNT(u.object_id)
  FROM r_coll_main AS c LEFT JOIN uuid_attrs AS u ON u.object_id = c.coll_id
  GROUP BY c.coll_id
  HAVING COUNT(u.object_id) != 1;

CREATE TEMPORARY TABLE data_uuid_probs (data_id, uuid_count)
AS 
  SELECT d.data_id, COUNT(u.object_id)
  FROM r_data_main AS d LEFT JOIN uuid_attrs AS u ON u.object_id = d.data_id
  WHERE d.data_repl_num = 0 
  GROUP BY d.data_id
  HAVING COUNT(u.object_id) != 1;

\echo '1. Problem Collections Created Before $CUTOFF_TIME:'
\echo ''
SELECT
  coll_id = ANY(ARRAY(SELECT * FROM coll_perm_probs))  AS "Permission Issue",
  COALESCE((SELECT cu.uuid_count FROM coll_uuid_probs AS cu WHERE cu.coll_id = c.coll_id), 1) 
    AS "UUID Count",
  coll_owner_name || '#' || coll_owner_zone            AS "Owner",
  TO_TIMESTAMP(CAST(create_ts AS INTEGER))             AS "Create Time",
  coll_name                                            AS "Collection"
FROM r_coll_main AS c
WHERE coll_id = ANY(ARRAY(SELECT * FROM coll_perm_probs UNION SELECT coll_id FROM coll_uuid_probs))
  AND coll_name LIKE '/iplant/%'
  AND coll_type != 'linkPoint'
  AND create_ts < '$cutoffTS'
ORDER BY create_ts;

\echo ''
\echo '2. Problem Data Objects Created Before $CUTOFF_TIME:'
\echo ''
SELECT 
  d.data_id = ANY(ARRAY(SELECT * FROM data_perm_probs))  AS "Permission Issue",
  COALESCE((SELECT du.uuid_count FROM data_uuid_probs AS du WHERE du.data_id = d.data_id), 1) 
    AS "UUID Count",
  d.data_owner_name || '#' || d.data_owner_zone          AS "Owner",
  TO_TIMESTAMP(CAST(d.create_ts AS INTEGER))             AS "Create Time",
  c.coll_name || '/' || d.data_name                      AS "Data Object"
FROM r_coll_main AS c JOIN r_data_main AS d ON d.coll_id = c.coll_id 
WHERE c.coll_name LIKE '/iplant/%'
  AND d.data_id
    = ANY(ARRAY(SELECT * FROM data_perm_probs UNION SELECT data_id FROM data_uuid_probs))
  AND d.data_repl_num = 0
  AND d.create_ts < '$cutoffTS'
ORDER BY d.create_ts;

ROLLBACK;
EOF
}


format_results()
{
  while IFS= read -r
  do
    if [ -n "$DEBUG" ]
    then
      printf '%s\n' "$REPLY"
    else
      case "$REPLY" in
        Timing*|Time:*|BEGIN|SELECT*|ROLLBACK)
          ;;
        *)
          printf '%s\n' "$REPLY"
          ;;
      esac
    fi
  done
}


display_problems | format_results
