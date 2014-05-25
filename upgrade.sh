#!/bin/bash -u

set -o errexit
cd `dirname $0`
eval `./admin/ShowDBDefs`

NEW_SCHEMA_SEQUENCE=20
OLD_SCHEMA_SEQUENCE=$((NEW_SCHEMA_SEQUENCE - 1))
URI_BASE='ftp://ftp.musicbrainz.org/pub/musicbrainz/data/schema-change-2014-05'

while getopts "b:" option
do
  case "${option}"
  in
      b) URI_BASE=${OPTARG};;
  esac
done

################################################################################
# Assert pre-conditions

if [ "$DB_SCHEMA_SEQUENCE" != "$OLD_SCHEMA_SEQUENCE" ]
then
    echo `date` : Error: Schema sequence must be $OLD_SCHEMA_SEQUENCE when you run this script
    exit -1
fi


# Slaves need to catch up on release_tag and other data
if [ "$REPLICATION_TYPE" = "$RT_SLAVE" -a -n "$URI_BASE" ]
then
    echo `date` : Downloading a copy of the release_tag and place documentation tables from $URI_BASE
    mkdir -p catchup
    OUTPUT=`wget -q "$URI_BASE/mbdump-derived.tar.bz2" -O catchup/mbdump-derived.tar.bz2` || ( echo "$OUTPUT" ; exit 1 )
    OUTPUT=`wget -q "$URI_BASE/mbdump-documentation.tar.bz2" -O catchup/mbdump-documentation.tar.bz2` || ( echo "$OUTPUT" ; exit 1 )

    echo `date` : Deleting the contents of release_tag and reimporting from the downloaded copy
    OUTPUT=`./admin/MBImport.pl --skip-editor --delete-first --no-update-replication-control catchup/mbdump-derived.tar.bz2 2>&1` || ( echo "$OUTPUT" ; exit 1 )

    echo `date` : Deleting the contents of documentation.l_place_* and documentation.l_*_place and reimporting from the downloaded copy
    OUTPUT=`./admin/MBImport.pl --skip-editor --delete-first --no-update-replication-control catchup/mbdump-documentation.tar.bz2 2>&1` || ( echo "$OUTPUT" ; exit 1 )
fi

################################################################################
# Backup and disable replication triggers

if [ "$REPLICATION_TYPE" = "$RT_MASTER" ]
then
    echo `date` : Export pending db changes
    ./admin/RunExport

    echo `date`" : Bundling replication packets, daily"
    ./admin/replication/BundleReplicationPackets $FTP_DATA_DIR/replication --period daily --require-previous
    echo `date`" : + weekly"
    ./admin/replication/BundleReplicationPackets $FTP_DATA_DIR/replication --period weekly --require-previous

    echo `date` : 'Dump a copy of release_tag and documentation tables for import on slave databases.'
    mkdir -p catchup
    ./admin/ExportAllTables --table='release_tag' --table='documentation.l_area_place_example' --table='documentation.l_artist_place_example' --table='documentation.l_label_place_example' --table='documentation.l_place_place_example' --table='documentation.l_place_recording_example' --table='documentation.l_place_release_example' --table='documentation.l_place_release_group_example' --table='documentation.l_place_url_example' --table='documentation.l_place_work_example' -d catchup

    echo `date` : 'Drop replication triggers (musicbrainz)'
    ./admin/psql READWRITE < ./admin/sql/DropReplicationTriggers.sql

    for schema in caa documentation statistics wikidocs
    do
        echo `date` : "Drop replication triggers ($schema)"
        ./admin/psql READWRITE < ./admin/sql/$schema/DropReplicationTriggers.sql
    done

fi

if [ "$REPLICATION_TYPE" != "$RT_SLAVE" ]
then
    echo `date` : Disabling last_updated triggers
    ./admin/sql/DisableLastUpdatedTriggers.pl
fi

################################################################################
# Migrations that apply for only slaves
#if [ "$REPLICATION_TYPE" = "$RT_SLAVE" ]
#then
#fi

################################################################################
# Scripts that should run on *all* nodes (master/slave/standalone)

echo `date` : 'Running upgrade scripts for all nodes'
./admin/psql READWRITE < ./admin/sql/updates/schema-change/${NEW_SCHEMA_SEQUENCE}.slave.sql || exit 1

echo `date` : 'Making some (potentially) missing primary keys'
./admin/psql READWRITE < ./admin/sql/updates/20140509-place-example-pkeys.sql

################################################################################
# Re-enable replication

if [ "$REPLICATION_TYPE" = "$RT_MASTER" ]
then
    echo `date` : 'Create replication triggers (musicbrainz)'
    OUTPUT=`./admin/psql READWRITE < ./admin/sql/CreateReplicationTriggers.sql 2>&1` || ( echo "$OUTPUT" ; exit 1 )

    for schema in caa documentation statistics wikidocs
    do
        echo `date` : "Create replication triggers ($schema)"
        OUTPUT=`./admin/psql READWRITE < ./admin/sql/$schema/CreateReplicationTriggers.sql 2>&1` || ( echo "$OUTPUT" ; exit 1 )
    done
fi

################################################################################
# Add constraints that apply only to master/standalone (FKS)

if [ "$REPLICATION_TYPE" != "$RT_SLAVE" ]
then
    echo `date` : 'Running upgrade scripts for master/standalone nodes'
    ./admin/psql READWRITE < ./admin/sql/updates/schema-change/${NEW_SCHEMA_SEQUENCE}.standalone.sql || exit 1

    echo `date` : Enabling last_updated triggers
    ./admin/sql/EnableLastUpdatedTriggers.pl
fi

################################################################################
# Bump schema sequence

echo `date` : Going to schema sequence $NEW_SCHEMA_SEQUENCE
echo "UPDATE replication_control SET current_schema_sequence = $NEW_SCHEMA_SEQUENCE;" | ./admin/psql READWRITE

# ignore superuser-only vacuum tables
echo `date` : Vacuuming DB.
echo "VACUUM ANALYZE;" | ./admin/psql READWRITE 2>&1 | grep -v 'only superuser can vacuum it'

################################################################################
# Prompt for final manual intervention

echo `date` : Done
echo `date` : UPDATE THE DB_SCHEMA_SEQUENCE IN DBDefs.pm TO $NEW_SCHEMA_SEQUENCE !

# eof
