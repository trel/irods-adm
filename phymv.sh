#! /bin/bash

set -e

readonly EXEC_NAME=$(basename "$0")


show_help()
{
  cat << EOF
Usage: 
 $EXEC_NAME [options] <src_resc> <dest_resc> <log_file>

Moves the files from one resource to another. It will not move any file
associated with a data object that has a replica on the destination resource.

Parameters:
 <src_resc>   the resource where the files are moved from
 <dest_resc>  the resouce where the files are moved to
 <log_file>   a file where the move related messages are logged

Options:
 -c, --collection <collection>  only move the files associated with data objects
                                in the collection <collection>
 -m, --multiplier <multiplier>  a multiplier on the number of processes to run
                                at once

 -h, --help  show help and exit
EOF
}


exit_with_help()
{
  show_help >&2
  exit 1
}


readonly Opts=$(getopt --name "$EXEC_NAME" \
                       --options c:hm: \
                       --longoptions collection:,help,multiplier: \
                       -- "$@")

if [ "$?" -ne 0 ]
then
  printf '\n' >&2
  exit_with_help
fi

eval set -- "$Opts"

while true
do
  case "$1" in
    -c|--collection)
      readonly BASE_COLL="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -m|--multiplier)
      readonly PROC_MULT="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      exit_with_help
      ;;
  esac
done

if [ "$#" -lt 3 ]
then
  exit_with_help
fi

readonly SRC_RESC="$1"
readonly DEST_RESC="$2"
readonly LOG="$3"

if [ -z "$PROC_MULT" ]
then
  readonly PROC_MULT=1
fi


count_list()
{
  awk 'BEGIN { 
         RS = "\0"
         tot = 0
       } 
       
       { tot = tot + 1 } 
       
       END { print tot }'
}


count_unmovable()
{
  local baseCond="$1"

  psql --no-align --tuples-only --host irods-db3 ICAT icat_reader << EOSQL
SELECT COUNT(data_id)
  FROM r_data_main AS d JOIN r_coll_main AS c ON c.coll_id = d.coll_id
  WHERE d.data_id = ANY(ARRAY(
      SELECT data_id FROM r_data_main WHERE resc_name = '$SRC_RESC'
      INTERSECT SELECT data_id FROM r_data_main WHERE resc_name = '$DEST_RESC'))
    AND d.resc_name = '$SRC_RESC'
    AND ($baseCond)
EOSQL
}


partition()
{
  local minSizeB="$1"

  if [ "$#" -ge 2 ]
  then
    local maxSizeB="$2"

    if [ "$maxSizeB" -eq 0 ]
    then
      maxSizeB=1
    elif [ "$minSizeB" -eq 0 ]
    then
      minSizeB=1
    fi
  fi

  if [ -n "$maxSizeB" ]
  then
    awk --assign min="$minSizeB" --assign max="$maxSizeB" \
        'BEGIN {
           RS = "\0" 
           FS = " " 
           ORS = "\0"
         }

         {
           if ($1 >= min && $1 < max) { print substr($0, length($1) + 2) }
         }'
  else
    awk --assign min="$minSizeB" \
        'BEGIN {
           RS = "\0" 
           FS = " " 
           ORS = "\0"
         } 
         
         {
           if ($1 >= min) { print substr($0, length($1) + 2) }
         }' 
  fi 
}


track_prog() 
{
  local cnt="$1"
  local tot="$2"  
  local subTot="$3"

  local subCnt=0
  local msg=

  while read -r
  do
    ((++subCnt))
    ((++cnt))
    printf '\r%*s\r' "${#msg}" '' >&2
    printf -v msg \
           'cohort: %0*d/%d, all: %0*d/%d' \
           "${#subTot}" "$subCnt" "$subTot" "${#tot}" "$cnt" "$tot"
    printf '%s' "$msg" >&2
  done

  printf '\r%*s\rcohort: %0*d/%d, all: %0*d/%d\n' \
         "${#msg}" '' "${#subTot}" "$subCnt" "$subTot" "${#tot}" "$cnt" "$tot" \
      >&2

  printf '%s' "$cnt"
}


select_cohort()
{
  local cnt="$1"
  local tot="$2"
  local maxProcs="$3"
  local minThreads="$4"

  if [ "$#" -ge 5 ]
  then
    local maxThreads="$5"
  fi

  local minSizeMiB=$((minThreads * 32))
  local minSizeB=$((minSizeMiB * ((1024 ** 2))))
  local cohortList=$(tempfile)

  if [ -n "$maxThreads" ]
  then
    local maxSizeMiB=$((maxThreads * 32))
    local maxSizeB=$((maxSizeMiB * ((1024 ** 2))))

    partition "$minSizeB" "$maxSizeB"
  else
    partition "$minSizeB"
  fi > "$cohortList"

  local subTotal=$(count_list <"$cohortList")

  if [ -n "$maxSizeMiB" ]
  then
    printf 'Physically moving %s files with size in [%s, %s) MiB\n' \
           "$subTotal" "$minSizeMiB" "$maxSizeMiB" \
      >&2
  else
    printf 'Physically moving %s files with size >= %s MiB\n' "$subTotal" "$minSizeMiB" >&2
  fi
  
  if [ "$subTotal" -gt 0 ]
  then
    local maxArgs=$((2 * ((maxProcs ** 2))))
    maxProcs=$((maxProcs * PROC_MULT))

    xargs --null --max-args "$maxArgs" --max-procs "$maxProcs" \
          iphymv -M -v -R "$DEST_RESC" -S "$SRC_RESC" \
        < "$cohortList" \
        2>> "$LOG" \
        | tee --append "$LOG" \
        | track_prog "$cnt" "$tot" "$subTotal"
  else
    printf '%s\n' "$cnt"
  fi

  rm --force "$cohortList"  
}


readonly ObjectList=$(tempfile)
trap "rm --force '$ObjectList'" EXIT

truncate --size 0 "$LOG"

if [ -n "$BASE_COLL" ]
then
  readonly BaseCond="c.coll_name = '$BASE_COLL' OR c.coll_name LIKE '$BASE_COLL/%'"
else
  readonly BaseCond=TRUE
fi

printf 'Checking to see if all data objects can be physically moved...\n'

if [ $(count_unmovable "$BaseCond") -gt 0 ] 
then
  cat << EOF
WARNING: NOT ALL DATA OBJECTS COULD BE MOVED BECAUSE REPLICAS ARE ALREADY ON THE
DESTINATION RESOURCE
EOF
fi

printf 'Retrieving data objects to physically move...\n'

psql --no-align --tuples-only --record-separator-zero --field-separator ' ' --host irods-db3 \
     ICAT icat_reader \
<< EOSQL > "$ObjectList"
SELECT d.data_size, c.coll_name || '/' || d.data_name
  FROM r_data_main AS d JOIN r_coll_main AS c ON c.coll_id = d.coll_id
  WHERE d.data_id = ANY(ARRAY(
      SELECT data_id FROM r_data_main WHERE resc_name = '$SRC_RESC'
      EXCEPT SELECT data_id FROM r_data_main WHERE resc_name = '$DEST_RESC'))
    AND d.resc_name = '$SRC_RESC'
    AND ($BaseCond)
EOSQL

readonly Tot=$(count_list < "$ObjectList")
printf '%d data objects to physically move\n' "$Tot"

if [ "$Tot" -gt 0 ]
then
  cnt=0
  cnt=$(select_cohort "$cnt" "$Tot" 16   0  0 < "$ObjectList")  # 16 0 byte transfers 
  cnt=$(select_cohort "$cnt" "$Tot" 16   0  1 < "$ObjectList")  # 16 1-threaded transfers 
  cnt=$(select_cohort "$cnt" "$Tot"  8   1  2 < "$ObjectList")  # 8 2-threaded
  cnt=$(select_cohort "$cnt" "$Tot"  6   2  3 < "$ObjectList")  # 6 3-threaded
  cnt=$(select_cohort "$cnt" "$Tot"  4   3  5 < "$ObjectList")  # 4 4--5-threaded
  cnt=$(select_cohort "$cnt" "$Tot"  3   5  7 < "$ObjectList")  # 3 6--7-threaded
  cnt=$(select_cohort "$cnt" "$Tot"  2   7 15 < "$ObjectList")  # 2 8--15-threaded
  cnt=$(select_cohort "$cnt" "$Tot"  1  15    < "$ObjectList")  # 1 16-threaded
fi 2>&1
