#!/bin/bash
# **README**
#1. This script runs the pre-upgrade-checks for RDS PostgreSQL and Amazon Aurora for PostgreSQL
#2. Copy script on Amazon EC2 Linux instance with AWS CLI configured, and psql client installed with accessibility to RDS/Aurora Postgres instance
#3. Make script executable: chmod +x pg_upgrade_pre_check.sh
#4. Run the script: ./pg_upgrade_pre_check.sh
#5. Use the RDS PostgreSQL or Aurora PostgreSQL Cluster endpoint URL for connection
#6. The database user should have READ access on all of the tables to get better metrics
#7. It will take around 2-3 mins to run (depending on size of instance), and generate html report:  <CompanyName>_<DatabaseIdentifier>_pre-upgrade-check_report_<date>.html
#8. Share the report with your AWS resource for dive deep session
#################
# Author: Vivek Singh, Principal Postgres Specialist Technical Account Manager, AWS
# V05 : NOV13 2025
# Changes in V05:
# - Added support for IAM authentication
# - Added cross-region support
# - Enhanced SSL certificate handling
# - Added custom port support
#################

clear
echo -n -e "RDS PostgreSQL instance endpoint URL or Aurora PostgreSQL Cluster endpoint URL: "
read EP

# Extract instance and region information
RDSNAME="${EP%%.*}"
REGNAME=`echo "$EP" | cut -d. -f3`
START=$(date -u -d '5 minutes ago' "+%Y-%m-%dT%H:%M:%SZ")
END=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

echo -n -e "Port (default: 5432): "
read RDSPORT
RDSPORT=${RDSPORT:-5432}

echo -n -e "Database Name: "
read DBNAME

# Authentication type selection
echo "Select authentication type:"
echo "1) Password Authentication"
echo "2) IAM Authentication"
echo -n "Enter your choice (1 or 2): "
read AUTH_CHOICE

case $AUTH_CHOICE in
    1)
        echo -n -e "RDS Master User Name: "
        read MASTERUSER
        echo -n -e "Password: "
        read -s MYPASS
        echo ""
        export PGPASSWORD=$MYPASS
        PSQLCL="psql -h $EP -p $RDSPORT -U $MASTERUSER -d $DBNAME"
        ;;
    2)
        # Check if IAM authentication is enabled
        echo "Checking IAM authentication status..."
        if [[ $EP == *"cluster"* ]]; then
            IAM_ENABLED=$(aws rds describe-db-clusters \
            --db-cluster-identifier $RDSNAME \
            --region $REGNAME \
            --query 'DBClusters[0].IAMDatabaseAuthenticationEnabled' \
            --output text)
        else
            IAM_ENABLED=$(aws rds describe-db-instances \
            --db-instance-identifier $RDSNAME \
            --region $REGNAME \
            --query 'DBInstances[0].IAMDatabaseAuthenticationEnabled' \
            --output text)
        fi

        if [[ "${IAM_ENABLED,,}" != "true" ]]; then
            echo "IAM authentication is not enabled for this RDS instance. Please enable it first."
            exit 1
        fi

        # Ask for IAM username
        echo -n -e "IAM Username: "
        read MASTERUSER

        # Download SSL certificate if not exists
        if [ ! -f "$REGNAME-bundle.pem" ]; then
            echo "Downloading RDS SSL certificate..."
            curl -O https://truststore.pki.rds.amazonaws.com/$REGNAME/$REGNAME-bundle.pem
            if [ $? -ne 0 ]; then
                echo "Failed to download SSL certificate"
                exit 1
            fi
        fi

        # Generate IAM token
        echo "Generating IAM authentication token..."
        TOKEN=$(aws rds generate-db-auth-token \
            --hostname $EP \
            --port $RDSPORT \
            --region $REGNAME \
            --username $MASTERUSER 2>&1)
        if [ $? -ne 0 ]; then
            echo "Failed to generate IAM token: $TOKEN"
            exit 1
        fi
        export PGPASSWORD=$TOKEN
        PSQLCL="psql -h $EP -p $RDSPORT -U $MASTERUSER -d $DBNAME -v sslmode=verify-full -v sslrootcert=$REGNAME-bundle.pem"
        ;;
    *)
        echo "Invalid choice. Please enter 1 for Password or 2 for IAM authentication."
        exit 1
        ;;
esac

echo -n -e "Target Postgres version: "

read TDBVER
echo -n -e "Company Name (with no space): "
read COMNAME

# Test database connection
case $AUTH_CHOICE in
    1)
        echo "Testing password authentication connection..."
        $PSQLCL -c "SELECT now()" >/dev/null 2>&1
        ;;
    2)
        echo "Testing IAM authentication connection..."
        $PSQLCL -c "SELECT now()" >/dev/null 2>&1
        ;;
esac

#Check for database connection
if [ "$?" -gt "0" ]; then
    echo "PostgreSQL instance $EP cannot be connected. Stopping the script"
    if [ "$AUTH_CHOICE" == "2" ]; then
        echo "Debug information for IAM authentication:"
        echo "1. SSL certificate path: $REGNAME-bundle.pem"
        echo "2. IAM authentication enabled: $IAM_ENABLED"
        echo "3. Connection command: $PSQLCL"
        echo "4. Generated token: $TOKEN"
    fi
    sleep 1
    exit 1
else
    echo "PostgreSQL instance $EP is running. Creating report."
fi

#Check RDS or Aurora PostgreSQL
if
$PSQLCL -c "SELECT name from pg_settings" | cut -d \| -f 1 | grep -qw apg_buffer_invalid_lookup_strategy; then
DBTYPE="aurora-postgresql"
else
DBTYPE="postgres"
fi

#Derive Aurora writer instance name
if [[ $DBTYPE == aurora-postgresql ]]
then
    CLUSNAME=$RDSNAME
    RDSNAME=`aws rds describe-db-clusters --db-cluster-identifier $CLUSNAME --query "DBClusters[*].DBClusterMembers[*].[DBInstanceIdentifier]" --output text |tail -1`
fi

INSTCLASS=`aws rds describe-db-instances --db-instance-identifier $RDSNAME --region $REGNAME --query 'DBInstances[0].DBInstanceClass' --output text`
DBVER=`$PSQLCL -c "select version()" | sed -n '3 p'|awk '{print $2}'`

#SQLs Used In the Script:
#Count for open prepared transactions
SQL1="SELECT count(*) FROM pg_catalog.pg_prepared_xacts;"

#SELECT for prepared transactions
SQL2="SELECT * FROM pg_catalog.pg_prepared_xacts;"

#Check for unsupported reg* data types
SQL3="SELECT count(*) FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
  WHERE c.oid = a.attrelid
      AND NOT a.attisdropped
      AND a.atttypid IN ('pg_catalog.regproc'::pg_catalog.regtype,
                         'pg_catalog.regprocedure'::pg_catalog.regtype,
                         'pg_catalog.regoper'::pg_catalog.regtype,
                         'pg_catalog.regoperator'::pg_catalog.regtype,
                         'pg_catalog.regconfig'::pg_catalog.regtype,
                         'pg_catalog.regdictionary'::pg_catalog.regtype)
      AND c.relnamespace = n.oid
      AND n.nspname NOT IN ('pg_catalog', 'information_schema');"

#Count replication slots
SQL4="SELECT COUNT(*) FROM pg_replication_slots;"

#Select replication slots
SQL5="SELECT slot_name, plugin, slot_type, datoid, database FROM pg_replication_slots;"

#Select work_mem value
SQL6="SELECT setting from pg_settings where name in ('work_mem');"

#Select shared_buffers value
SQL7="select setting from pg_settings where name='shared_buffers';"

#Count UNKNOWN data type
SQL8="SELECT count(*) FROM information_schema.columns where data_type ilike 'unknown';"

#Select UNKNOWN data type
SQL9="SELECT table_schema, table_name, column_name FROM information_schema.columns where data_type ilike 'unknown';"

#Count extensions
SQL10="SELECT COUNT(*) FROM pg_catalog.pg_extension e LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace LEFT JOIN pg_catalog.pg_description c ON c.objoid = e.oid AND c.classoid = 'pg_catalog.pg_extension'::pg_catalog.regclass WHERE n.nspname NOT LIKE 'pg_catalog';"

#Select extensions' details
SQL11="SELECT e.extname AS \"Name\", e.extversion AS \"Version\" FROM pg_catalog.pg_extension e LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace LEFT JOIN pg_catalog.pg_description c ON c.objoid = e.oid AND c.classoid = 'pg_catalog.pg_extension'::pg_catalog.regclass WHERE n.nspname NOT LIKE 'pg_catalog';"

#Check for user's full access
SQL12="SELECT r.rolname, ARRAY(SELECT b.rolname FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles b ON (m.roleid = b.oid) WHERE m.member = r.oid) as member_of FROM pg_catalog.pg_roles r WHERE r.rolname !~ '^pg_' and r.rolname='$MASTERUSER' ORDER BY 1;"

#List of views from current database
SQL13="SELECT n.nspname as \"Schema\",
  c.relname as \"Name\",
  CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' WHEN 'i' THEN 'index' WHEN 'S' THEN 'sequence' WHEN 's' THEN 'special' WHEN 't' THEN 'TOAST table' WHEN 'f' THEN 'foreign table' WHEN 'p' THEN 'partitioned table' WHEN 'I' THEN 'partitioned index' END as \"Type\",
  pg_catalog.pg_get_userbyid(c.relowner) as \"Owner\"
FROM pg_catalog.pg_class c
     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
WHERE c.relkind IN ('v','m','')
      AND n.nspname <> 'pg_catalog'
      AND n.nspname !~ '^pg_toast'
      AND n.nspname <> 'information_schema'
  AND pg_catalog.pg_table_is_visible(c.oid)
  AND pg_catalog.pg_get_userbyid(c.relowner) NOT LIKE 'rdsadmin'
ORDER BY 1,2;"
#Count sql_identifier columns
SQL15="SELECT COUNT(*)
FROM pg_attribute
  join pg_class on attrelid=oid
  join pg_namespace on relnamespace=pg_namespace.oid
WHERE atttypid::regtype::text like '%sql_identifier'
and nspname not in ('information_schema','oracle');"

#Details of sql_identifier columns
SQL16="SELECT pg_class.relname, pg_class.relkind
FROM pg_attribute
  join pg_class on attrelid=oid
  join pg_namespace on relnamespace=pg_namespace.oid
WHERE atttypid::regtype::text like '%sql_identifier'
  and nspname!='information_schema';"

#GIST index count
SQL17="SELECT COUNT(*) FROM pg_index i
             JOIN pg_class c ON i.indexrelid = c.oid
             JOIN pg_namespace n ON c.relnamespace = n.oid
             JOIN pg_am am ON c.relam = am.oid
             WHERE am.amname = 'gist'
             AND n.nspname NOT IN ('pg_catalog', 'information_schema');"

#GIST index list
SQL18="SELECT n.nspname as schema_name, c.relname as index_name
           FROM pg_index i
           JOIN pg_class c ON i.indexrelid = c.oid
           JOIN pg_namespace n ON c.relnamespace = n.oid
           JOIN pg_am am ON c.relam = am.oid
           WHERE am.amname = 'gist'
           AND n.nspname NOT IN ('pg_catalog', 'information_schema');"

sleep 1
echo "still working ..."
echo "20% done ..."

html=${COMNAME}_${RDSNAME}_pre-upgrade-check_report_$(date +"%m-%d-%y").html

#Derive HTML file name for Aurora
if [[ $DBTYPE  ==  aurora-postgresql ]]
then
html=${COMNAME}_${CLUSNAME}_pre-upgrade-check_report_$(date +"%m-%d-%y").html
fi

#Generating HTML file
echo "<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">" > $html
echo "<html>" >> $html
echo "<link rel="stylesheet" href="https://unpkg.com/purecss@0.6.2/build/pure-min.css">" >> $html
echo "<body style="font-family:'Verdana'" bgcolor="#F8F8F8">" >> $html
echo "<fieldset>" >> $html
echo "<table><tr> <td width="20"></td> <td>" >>$html
echo "<h1><font face="verdana" color="#0099cc"><center><u>PostgreSQL Pre-upgrade Check Report For $COMNAME</u></center></font></h1></color>" >> $html
echo "<font face="verdana" color="#808080"><small>Author: Vivek Singh, Principal Database Specialist - PostgreSQL, Amazon Web Services | Version V05</small></font>" >> $html
echo "</fieldset>" >> $html
echo "<br>" >> $html
echo "<br>" >> $html
echo "<table><tr><td bgcolor="red">&nbsp;&nbsp;&nbsp;&nbsp;</td><td><font face="verdana" color="#0099cc"><medium>&nbsp;&nbsp;Issue found.&nbsp;&nbsp;&nbsp;&nbsp;</font></td>" >> $html
echo "<td bgcolor="green">&nbsp;&nbsp;&nbsp;&nbsp;</td><td><font face="verdana" color="#0099cc"><medium>&nbsp;&nbsp;No issue found.&nbsp;&nbsp;&nbsp;&nbsp;</font></td>" >> $html
echo "<td bgcolor="orange">&nbsp;&nbsp;&nbsp;&nbsp;</td><td><font face="verdana" color="#0099cc"><medium>&nbsp;&nbsp;Requires manual analysis.</font></td></tr> </table>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Pre-upgrade check report for:  </font>" >>$html
echo "<br>" >> $html
echo "Postgres Endpoint URL: $EP" >> $html
echo "<br>" >> $html
echo "Current Postgres version: $DBVER" >>$html
echo "<br>" >> $html
echo "Target Postgres version: $TDBVER" >>$html
echo "<br>" >> $html
echo "Date of report: `date +%m-%d-%Y`" >>$html
echo "<br>" >> $html
echo "<br>" >> $html

#Check for target Postgres version
echo "<font face="verdana" color="#ff6600">1. Check for target Postgres version: </font>" >>$html
echo "<br>" >> $html
if aws rds describe-db-engine-versions --engine $DBTYPE --engine-version $DBVER --region $REGNAME --query "DBEngineVersions[*].ValidUpgradeTarget[*].{EngineVersion:EngineVersion}" --output text | grep -q $TDBVER
then
echo "<font face="verdana" color="green">$TDBVER is one of the target versions for current version of $DBTYPE $DBVER. No issue found.</font>" >> $html
else
echo "<font face="verdana" color="red">$TDBVER is not found in the target versions for current version of $DBTYPE $DBVER. Upgrade will fail. Please ensure target version $TDBVER is one of the target versions for current version of $DBTYPE $DBVER.</font>" >> $html
fi
echo "<br>" >> $html
echo "<br>" >> $html

#Check for unsupported DB instance classes
echo "<font face="verdana" color="#ff6600">2. Check for unsupported DB instance classes: </font>" >>$html
echo "<br>" >> $html
if aws rds describe-orderable-db-instance-options --engine $DBTYPE --db-instance-class $INSTCLASS --query "OrderableDBInstanceOptions[].{EngineVersion:EngineVersion}"  --output text  --region $REGNAME | sort -u | grep -q $TDBVER
then
echo "<font face="verdana" color="green">$DBTYPE DB instance class $INSTCLASS is supported for target $DBTYPE version $TDBVER. No issue found.</font>" >> $html
else
echo "<font face="verdana" color="red">$DBTYPE DB instance class $INSTCLASS is not supported for target $DBTYPE version $TDBVER. Please choose different target version or change current instance class.</font>" >> $html
fi
echo "<br>" >> $html
echo "<br>" >> $html

#Open prepared transactions
echo "<font face="verdana" color="#ff6600">3. Check for open prepared transactions: </font>" >>$html
echo "<br>" >> $html

PREPXCNT=`$PSQLCL -c "$SQL1" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

if [ $PREPXCNT  -eq  0 ]
then
echo "<font face="verdana" color="green">Prepared transactions that are open on the database might lead to upgrade failure. Be sure to commit or roll back all open prepared transactions before starting an upgrade. No uncommitted prepared transactions found.</font>" >> $html
else
echo "<font face="verdana" color="red">Prepared transactions that are open on the database might lead to upgrade failure. There are $PREPXCNT uncommitted prepared transactions found. Please commit or rollback all prepared transactions to avoid upgrade failure. Details of uncommitted prepared transactions are as below:</font>" >> $html
echo "`$PSQLCL --html -c "$SQL2"|sed '$d'|sed '$d' ` " >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

#Check for unsupported reg* data types
echo "<font face="verdana" color="#ff6600">4. Check for unsupported reg* data types: </font>" >>$html
echo "<br>" >> $html
MAZDBVER="`echo "$DBVER"|sed 's/\..*$//'`"
if [ $MAZDBVER  -eq  10 ]
then
SQL3="SELECT count(*) FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
  WHERE c.oid = a.attrelid
      AND NOT a.attisdropped
      AND a.atttypid IN ('pg_catalog.regproc'::pg_catalog.regtype,
                         'pg_catalog.regprocedure'::pg_catalog.regtype,
                         'pg_catalog.regoper'::pg_catalog.regtype,
                         'pg_catalog.regoperator'::pg_catalog.regtype,
                         'pg_catalog.regconfig'::pg_catalog.regtype,
                         'pg_catalog.regdictionary'::pg_catalog.regtype)
      AND c.relnamespace = n.oid
      AND n.nspname NOT IN ('pg_catalog', 'information_schema');"
fi

if [ $MAZDBVER  -eq  11 ]
then
SQL3="SELECT count(*) FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
  WHERE c.oid = a.attrelid
      AND NOT a.attisdropped
      AND a.atttypid IN ('pg_catalog.regproc'::pg_catalog.regtype,
                         'pg_catalog.regprocedure'::pg_catalog.regtype,
                         'pg_catalog.regoper'::pg_catalog.regtype,
                         'pg_catalog.regoperator'::pg_catalog.regtype,
                         'pg_catalog.regconfig'::pg_catalog.regtype,
                         'pg_catalog.regnamespace'::pg_catalog.regtype,
                         'pg_catalog.regdictionary'::pg_catalog.regtype)
      AND c.relnamespace = n.oid
      AND n.nspname NOT IN ('pg_catalog', 'information_schema');"
fi

if [ $MAZDBVER  -eq  14 ]
then
SQL3="SELECT count(*) FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
  WHERE c.oid = a.attrelid
      AND NOT a.attisdropped
      AND a.atttypid IN ('pg_catalog.regproc'::pg_catalog.regtype,
                         'pg_catalog.regprocedure'::pg_catalog.regtype,
                         'pg_catalog.regoper'::pg_catalog.regtype,
                         'pg_catalog.regoperator'::pg_catalog.regtype,
                         'pg_catalog.regconfig'::pg_catalog.regtype,
                         'pg_catalog.regcollation'::pg_catalog.regtype,
                         'pg_catalog.regnamespace'::pg_catalog.regtype,
                         'pg_catalog.regrole'::pg_catalog.regtype,
                         'pg_catalog.regdictionary'::pg_catalog.regtype)
      AND c.relnamespace = n.oid
      AND n.nspname NOT IN ('pg_catalog', 'information_schema');"
fi

REGTYPECNT=`$PSQLCL -c "$SQL3" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
if [ "$REGTYPECNT"  -eq  "0" ]
then
echo "<font face="verdana" color="green">The pg_upgrade utility doesn't support upgrading databases that include table columns using the reg* OID-referencing system data types. Remove all uses of reg* data types, except for regclass, regrole, and regtype, before attempting an upgrade. No unsupported reg* data types found.</font>" >> $html
else
echo "<font face="verdana" color="red">The pg_upgrade utility doesn't support upgrading databases that include table columns using the reg* OID-referencing system data types. Remove all uses of reg* data types, except for regclass, regrole, and regtype, before attempting an upgrade. $REGTYPECNT unsupported reg* data types found as below. Please change data types of associated colums to avoid upgrade failure. Only regclass, regrole, and regtype data types are supported. Please use below query to find out unsupported reg* OID-referencing data types columns:</font>" >> $html
echo "<br>" >> $html
echo "$SQL3" >> $html
fi

echo "<br>" >> $html
echo "<br>" >> $html

#Check for logical replication slots
echo "<font face="verdana" color="#ff6600">5. Check for logical replication slots: </font>" >>$html
echo "<br>" >> $html
REPSLOTCNT=`$PSQLCL -c "$SQL4" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

if [ $REPSLOTCNT  -eq  0 ]
then
echo "<font face="verdana" color="green">No logical replication slots found. An upgrade can't occur if your instance has any logical replication slots. Logical replication slots are typically used for AWS Database Migration Service (AMS DMS) migration.</font>" >> $html
else
echo "<font face="verdana" color="red">$REPSLOTCNT logical replication slots found as below. An upgrade can't occur if your instance has any logical replication slots. Logical replication slots are typically used for AWS Database Migration Service (AMS DMS) migration. Please drop replication slots using SELECT pg_drop_replication_slot(slot_name) to avoid upgrade failures.</font>" >> $html
echo "`$PSQLCL --html -c "$SQL5"|sed '$d'|sed '$d' ` " >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

sleep 1
echo "still working ..."
echo "40% done ..."

#Check for storage issue
echo "<font face="verdana" color="#ff6600">6. Check for storage issues: </font>" >>$html
echo "<br>" >> $html

TOTALDBSIZE=`$PSQLCL -c "SELECT pg_size_pretty(SUM(pg_database_size(pg_database.datname))) as \"Total_DB_size\" FROM pg_database where datname not in ('rdsadmin') " | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
if [[ $DBTYPE  ==  postgres ]]
then
CURRFREESTORAGE=`aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace --start-time $START --end-time $END --period 300 --statistics Average --dimensions "Name=DBInstanceIdentifier, Value=$RDSNAME" --region $REGNAME | grep Ave* | awk '{ print $2 }'| sed 's/,//g'|sed 's/\..*$//'`
echo "<font face="verdana" color="orange">Total size of all databases in RDS instance $RDSNAME instance is $TOTALDBSIZE. Current FreeStorageSpace is $(( CURRFREESTORAGE / 1073741824 ))GB. Make sure to have 15%-20% free storage to avoid upgrade failures.</font>" >>$html
fi

if [[ $DBTYPE  ==  aurora-postgresql ]]
then
echo "<font face="verdana" color="orange">Total size of all databases in Aurora cluster $RDSNAME is $TOTALDBSIZE. Aurora storage capacity is 128TiB. Make sure to have 15%-20% free storage to avoid upgrade failures.</font>" >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

#Incompatible parameter error
echo "<font face="verdana" color="#ff6600">7. Check for 'Incompatible Parameter' error: </font>" >>$html
echo "<br>" >> $html
#work_mem check
WORKMEMVAL=`$PSQLCL -c "$SQL6" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
if [ $WORKMEMVAL  -eq  4096 ]
then
echo "<font face="verdana" color="green">Work_mem is set at default value 4MB. Higher value of work_mem can cause 'Incompatible Parameters' issue and might fail upgrade. No issues found.</font>" >>$html
else
echo "<font face="verdana" color="red">Value of work_mem is found modified to $WORKMEMVAL. Higher value of work_mem can cause 'Incompatible Parameters' issue and might fail upgrade. Set it to default 4MB to avoid upgrade failures.</font>" >>$html
fi
echo "<br>" >> $html

sleep 1
echo "still working ..."
echo "60% done ..."

#Shared_buffers check
#shared_buffers percentage
NUMSBRAW=`$PSQLCL -c "$SQL7"|sed -n 3p`
NUM2=1048576
NUM3=$((NUMSBRAW*8 / NUM2))
SBNUM=$((NUM3*1024))
if [[ $DBTYPE == aurora-postgresql ]]; then
    echo "<font face="verdana" color="orange">Shared_buffers is $NUM3 GB. For Aurora PostgreSQL, shared_buffers is managed automatically based on instance configuration.</font>" >>$html
else
    INSTCLASS=`aws rds describe-db-instances --db-instance-identifier $RDSNAME --region $REGNAME | grep Class| awk '{ print $2 }'|sed 's/"//g' |sed 's/db.//g' |sed 's/,//g'`
    if [[ $INSTCLASS != "serverless" ]]; then
        TOTALRAM=`aws ec2 describe-instance-types --instance-types $INSTCLASS | grep SizeInMiB | awk '{ print $2 }'`
        if [ ! -z "$TOTALRAM" ] && [ "$TOTALRAM" -ne 0 ]; then
            RATIOSB=$((SBNUM*100/$TOTALRAM))
            echo "<font face="verdana" color="orange">Shared_buffers is $NUM3 GB, $RATIOSB% of total instance memory. The default value of Shared_buffers for RDS Postgres is set at ~24%. If the value is modified to higher value, please reset it to avoid upgrade failures.</font>" >>$html
        fi
    else
        echo "<font face="verdana" color="orange">Instance is using Serverless configuration. Shared_buffers is managed automatically.</font>" >>$html
    fi
fi


if [[ $DBTYPE  ==  postgres ]]
then
echo "<font face="verdana" color="orange">Shared_buffers is $NUM3 GB, $RATIOSB% of total instance memory. The default value of Shared_buffers for RDS Postgres is set at ~24%. If the value is modified to higher value, please reset it to avoid upgrade failures.</font>" >>$html
fi

if [[ $DBTYPE  ==  aurora-postgresql ]]
then
echo "<font face="verdana" color="orange">Shared_buffers is $NUM3 GB, $RATIOSB% of total instance memory. The default value of  Shared_buffers for Aurora Postgres is set at ~67%. If the value is modified to higher value, please reset it to avoid upgrade failures.</font>" >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

#Check for Unknown data types
echo "<font face="verdana" color="#ff6600">8. Check for Unknown data types: </font>" >>$html
echo "<br>" >> $html

UNKNOWNCNT=`$PSQLCL -c "$SQL8" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
if [ $UNKNOWNCNT  -eq  0 ]
then
echo "<font face="verdana" color="green">PostgreSQL versions 10 and later don't support unknown data types. UNKNOWN data type causes upgrade failure. No 'UNKNOWN' datatype found.</font>" >>$html
else
echo "<font face="verdana" color="red">PostgreSQL versions 10 and later don't support unknown data types. UNKNOWN dataype causes upgrade failure. UNKNOWN datatype found as below. Remove UNKNOWN dataype to avoid upgrade failure.</font>" >>$html
echo "`$PSQLCL --html -c "$SQL9"|sed '$d'|sed '$d' ` " >>$html
fi
echo "<br>" >> $html
echo "<br>" >> $html

sleep 1
echo "still working ..."
echo "80% done ..."

#Read replica upgrade failure
echo "<font face="verdana" color="#ff6600">9. Check for Read Replica upgrade failure: </font>" >>$html
echo "<br>" >> $html
if [[ $DBTYPE  ==  postgres ]]
then
RRCNT=`aws rds describe-db-instances --db-instance-identifier $RDSNAME --region $REGNAME --query 'DBInstances[0].ReadReplicaDBInstanceIdentifiers' --output text| wc -l`
fi

if [[ $DBTYPE  ==  postgres ]] && [ $RRCNT -eq 0 ]
then
echo "<font face="verdana" color="green">In RDS Postgres, all Read Replicas are upgraded followed up by Source instance, adding up outage. No Read Replica found for RDS instance $RDSNAME.</font>">>$html
fi

if [[ $DBTYPE  ==  postgres ]] && [ $RRCNT -ne 0 ]
then
echo "<font face="verdana" color="red">$RRCNT Read Replica found for RDS instance $RDSNAME as below. All Read Replicas are upgraded followed up by Source instance. For reducing outage, please drop promote or drop replica. You can recreate the read replicas after the upgrade is completed. Below are the list of Read Replica:</font>" >>$html
echo "<br>" >> $html
aws rds describe-db-instances --db-instance-identifier $RDSNAME --region $REGNAME --query 'DBInstances[0].ReadReplicaDBInstanceIdentifiers' --output text >>$html
fi

if [ $DBTYPE  ==  aurora-postgresql ]
then
RRCNT=`aws rds describe-db-clusters --db-cluster-identifier $CLUSNAME --region $REGNAME --query "DBClusters[*].DBClusterMembers[*].[DBInstanceIdentifier]"  --output text|tail -n +2 |wc -l`
fi

if [ $DBTYPE  ==  aurora-postgresql ] && [ $RRCNT -eq 0 ]
then
echo "<font face="verdana" color="green">For Aurora, after the writer upgrade completes, each reader instance experiences a brief outage while it's upgraded to the new major, adding up overall outage. No Reader found for Aurora cluster $RDSNAME.</font>" >>$html
fi

if [ $DBTYPE  ==  aurora-postgresql ] && [ $RRCNT -ne 0 ]
then
echo "<font face="verdana" color="red">For Aurora, after the writer upgrade completes, each reader instance experiences a brief outage while it's upgraded to the new major, adding up overall outage. $RRCNT readers found for this Aurora cluster. For reducing outage, please drop below readers.</font>" >>$html
echo "<br>" >> $html
aws rds describe-db-clusters --db-cluster-identifier $CLUSNAME --region $REGNAME --query "DBClusters[*].DBClusterMembers[*].[DBInstanceIdentifier]"  --output text | head -n -1 >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

#Postgres extensions check
echo "<font face="verdana" color="#ff6600">10. Check for Postgres extensions: </font>" >>$html
echo "<br>" >> $html

EXTNCNT=`$PSQLCL -c "$SQL10" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

if [[ $EXTNCNT  -eq  0 ]]
then
echo "<font face="verdana" color="green">No user extension found.</font>" >>$html
else
echo "<font face="verdana" color="red">PostgreSQL engine upgrade doesn't upgrade most PostgreSQL extensions. To <a href="https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.PostgreSQL.html#USER_UpgradeDBInstance.PostgreSQL.ExtensionUpgrades" target="_blank">update a Postgres extension</a> after a version upgrade, use the ALTER EXTENSION UPDATE command. $EXTNCNT user extension found as below. Some extensions may need to be dropped otherwise the upgrade fails.</font>" >>$html
echo "`$PSQLCL --html -c "$SQL11"|sed '$d'|sed '$d' ` " >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

#User access check
echo "<font face="verdana" color="#ff6600">11. Check for user access: </font>" >>$html
echo "<br>" >> $html

echo "<font face="verdana" color="orange">This upgrade is being run by user $MASTERUSER. Please make sure this user has access to all database objects. Below are the roles this user is member of. To make sure this user has access to all db objects, pelase grant all users to $MASTERUSER as: GRANT user_name to $MASTERUSER. If the user running upgrade doesn't have access to all tables, upgrade will fail.</font>" >>$html

echo "`$PSQLCL --html -c "$SQL12"|sed '$d'|sed '$d' ` " >>$html

echo "<br>" >> $html
echo "<br>" >> $html

#"sql_identifier" data type check
echo "<font face="verdana" color="#ff6600">12. Check for sql_identifier data type: </font>" >>$html
echo "<br>" >> $html

EXTNSI=`$PSQLCL -c "$SQL15" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

if [[ $EXTNSI  -eq  0 ]]
then
echo "<font face="verdana" color="green">Your database doesn't contain the 'sql_identifier' data type in user tables and/or indexes. No issue found.</font>" >>$html
else
echo "<font face="verdana" color="red">$EXTNSI 'sql_identifier' data type  columns found. Your installation contains the "sql_identifier" data type in user tables and/or indexes.  The on-disk format for this data type has changed, so this cluster cannot currently be upgraded.  You can remove the problem tables or change the data type to "name" and restart the upgrade.Use command: ALTER TABLE table_name ALTER COLUMN column_name TYPE name;.</font>" >>$html
echo "`$PSQLCL --html -c "$SQL16"|sed '$d'|sed '$d' ` " >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

#Check for views dependency
echo "<font face="verdana" color="#ff6600">13. Check for views dependency: </font>" >>$html
echo "<br>" >> $html

echo "<font face="verdana" color="orange">Check dependency of views, materialized views or functions on system catalogs. If user view, materialized view or function depends on system catalogs such as pg_stat_activity, upgrade may fail. Please verify all views or materialized views and functions are not depending on system catalogs. Below is the list of all views and materialized views.</font>" >>$html
echo "`$PSQLCL --html -c "$SQL13"|sed '$d'|sed '$d' ` " >>$html

echo "<br>" >> $html
echo "<br>" >> $html

#User access check
echo "<font face="verdana" color="#ff6600">14. Check for incorrect primary user name: </font>" >>$html
echo "<br>" >> $html
PGMASTERUSER=`aws rds describe-db-instances --db-instance-identifier $RDSNAME --region $REGNAME --query 'DBInstances[0].MasterUsername' --output text`
if [[ ${PGMASTERUSER:0:3} == "pg_" ]]
then
echo "<font face="verdana" color="red">RDS master user is $PGMASTERUSER and it starts by 'pg_'. Upgrade will fail. Please change the RDS master user name.</font>" >>$html
else
echo "<font face="verdana" color="green">RDS master user is $PGMASTERUSER and it doesn't start by 'pg_'. No issue found.</font>" >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

#GIST index check
echo "<font face="verdana" color="#ff6600">15. Check for GIST index: </font>" >>$html
echo "<br>" >> $html

GISTCOUNT=`$PSQLCL -c "$SQL17" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

if [[ $GISTCOUNT  -eq  0 ]]
then
echo "<font face="verdana" color="green">No GIST indexes found. PostgreSQL 16 changes how GIST indexes handle null values. No action needed.</font>" >>$html
else
echo "<font face="verdana" color="red">$GISTCOUNT GIST indexes found. PostgreSQL 16 changes how GIST indexes handle null values. Consider REINDEX after upgrade for optimal performance. Below is the list of GIST indexes:</font>" >>$html
echo "`$PSQLCL --html -c "$SQL18"|sed '$d'|sed '$d' ` " >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html

# Add ICU Collation check for PostgreSQL 16+
echo "<font face="verdana" color="#ff6600">16. Check for ICU Collations (PostgreSQL 16+): </font>" >>$html
echo "<br>" >> $html

if [ "$TDBVER" == "16" ] || [ "$TDBVER" == "17" ]
then
  # SQL to check for ICU collations
  ICUSQL="SELECT collname, collprovider
          FROM pg_collation
          WHERE collprovider = 'i'
          AND collname NOT LIKE 'default%' limit 10;"

  ICUCOUNT=`$PSQLCL -c "SELECT COUNT(*) FROM pg_collation WHERE collprovider = 'i' AND collname NOT LIKE 'default%';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

  if [ "$ICUCOUNT" -eq "0" ]
  then
    echo "<font face="verdana" color="green">No custom ICU collations found. PostgreSQL 16 has stricter requirements for ICU collation versions. No action needed.</font>" >> $html
  else
    echo "<font face="verdana" color="orange">$ICUCOUNT custom ICU collations found. PostgreSQL 16 has stricter requirements for ICU collation versions. These collations may need to be recreated after upgrade. A few ICU collations are below: </font>" >> $html
    echo "`$PSQLCL --html -c "$ICUSQL"|sed '$d'|sed '$d' ` " >>$html
  fi
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

# Add check for new reserved keywords in PostgreSQL 17
if [ "$TDBVER" == "17" ]
then
  echo "<font face="verdana" color="#ff6600">17. Check for new reserved keywords (PostgreSQL 17): </font>" >>$html
  echo "<br>" >> $html

  # SQL to check for objects using names that will become reserved in PG17
  PG17KEYWORDS="'checkpoint', 'subscription', 'publication'"

  KEYWORDSQL="SELECT n.nspname as schema_name, c.relname as object_name,
              CASE c.relkind
                WHEN 'r' THEN 'table'
                WHEN 'v' THEN 'view'
                WHEN 'i' THEN 'index'
                WHEN 'S' THEN 'sequence'
                WHEN 'm' THEN 'materialized view'
              END as object_type
              FROM pg_class c
              JOIN pg_namespace n ON c.relnamespace = n.oid
              WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND lower(c.relname) IN ($PG17KEYWORDS);"

  KEYWORDCOUNT=`$PSQLCL -c "SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND lower(c.relname) IN ($PG17KEYWORDS);" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

  if [ "$KEYWORDCOUNT" -eq "0" ]
  then
    echo "<font face="verdana" color="green">No objects found using names that will become reserved keywords in PostgreSQL 17. No action needed.</font>" >> $html
  else
    echo "<font face="verdana" color="orange">$KEYWORDCOUNT objects found using names that will become reserved keywords in PostgreSQL 17. Consider renaming these objects before upgrading.</font>" >> $html
    echo "`$PSQLCL --html -c "$KEYWORDSQL"|sed '$d'|sed '$d' ` " >>$html
  fi
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

#AWS docs
echo "<font face="verdana" color="#ff6600">AWS documentations for Aurora/RDS Postgres upgrade: </font>" >>$html
echo "<br>" >> $html
echo "<font face="verdana" color="#0099cc">&nbsp;&nbsp;&#x2022;&nbsp;&nbsp;<a href="https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.html" target="_blank">Upgrading the PostgreSQL DB engine for Aurora PostgreSQL</a>: AWS user guide discusses about Aurora Postgres cluster minor/major version upgrade steps, and upgrading Postgres extensions."  >>$html
echo "<br>" >> $html
echo "<font face="verdana" color="#0099cc">&nbsp;&nbsp;&#x2022;&nbsp;&nbsp;<a href="https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.PostgreSQL.html" target="_blank">Upgrading the PostgreSQL DB engine for Amazon RDS</a>: AWS user guide discusses about RDS Postgres minor/major version upgrade steps, and upgrading Postgres extensions."  >>$html
echo "<br>" >> $html
echo "<font face="verdana" color="#0099cc">&nbsp;&nbsp;&#x2022;&nbsp;&nbsp;<a href="https://aws.amazon.com/blogs/database/upgrade-amazon-aurora-postgresql-and-amazon-rds-for-postgresql-version-10/" target="_blank">Upgrading the PostgreSQL DB engine for Amazon RDS</a>: AWS data blog discusses about Aurora and RDS Postgres version 10 EOL."  >>$html
echo "<br>" >> $html
echo "<font face="verdana" color="#0099cc">&nbsp;&nbsp;&#x2022;&nbsp;&nbsp;<a href="https://aws.amazon.com/blogs/database/best-practices-for-upgrading-amazon-rds-to-major-and-minor-versions-of-postgresql/" target="_blank">Best practices for upgrading Amazon RDS to major and minor versions of PostgreSQL</a>: AWS data blog discusses about RDS Postgres upgrade best practices."  >>$html
echo "<br>" >> $html

#footer
echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#0099cc"><small>Note: While modifying any database configuration, parameters, please consult/review with your DBA/DB expert. Results may vary depending on the workloads and expectations. Also, before applying modifications, learn about them at <a href="https://www.postgresql.org/docs/current/pgstatstatements.html" target="_blank">PostgreSQL official docs</a>. Before making any changes in production, its recommended to test those in testing environment thoroughly. If you have any feedback about this tool, please provide it to your AWS representative.<small></font>" >> $html

echo "<br>" >> $html
echo "<font face="verdana" color="#d3d3d3"><small>End of report. Script version V05</small></font>" >> $html
echo "<br>" >> $html
echo "<br>" >> $html

echo "</td></tr></table></body></html>" >> $html

sleep 1
echo "Report `pwd`/$html created!"


