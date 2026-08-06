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

# Database scope selection
echo ""
echo "Check databases:"
echo "1) Single database (current: $DBNAME)"
echo "2) All user databases (iterate automatically)"
echo -n "Enter your choice (1 or 2): "
read DB_SCOPE_CHOICE
DB_SCOPE_CHOICE=${DB_SCOPE_CHOICE:-1}

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

# Build database list based on scope choice
if [ "$DB_SCOPE_CHOICE" == "2" ]
then
  DB_LIST=`$PSQLCL -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('rdsadmin') ORDER BY datname;"`
  echo "Databases to check: $DB_LIST"
else
  DB_LIST="$DBNAME"
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
echo "<br>" >> $html
# Show actual affected tables/columns
REGSQL_DETAIL="SELECT n.nspname AS schema, c.relname AS table_name, a.attname AS column_name, a.atttypid::regtype::text AS data_type FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN ('pg_catalog.regproc'::pg_catalog.regtype,'pg_catalog.regprocedure'::pg_catalog.regtype,'pg_catalog.regoper'::pg_catalog.regtype,'pg_catalog.regoperator'::pg_catalog.regtype,'pg_catalog.regconfig'::pg_catalog.regtype,'pg_catalog.regdictionary'::pg_catalog.regtype) AND c.relnamespace = n.oid AND n.nspname NOT IN ('pg_catalog', 'information_schema');"
echo "<br><font face="verdana" color="red"><b>Affected tables and columns:</b></font><br>" >> $html
echo "`$PSQLCL --html -c "$REGSQL_DETAIL"|sed '$d'|sed '$d' ` " >>$html
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

# Check for pending maintenance actions
echo "<font face="verdana" color="#ff6600">18. Check for pending maintenance actions: </font>" >>$html
echo "<br>" >> $html
if [ "$DBTYPE" == "aurora-postgresql" ]
then
  # For Aurora, get the cluster ARN first
  CLUSTER_ARN=`aws rds describe-db-clusters --db-cluster-identifier $CLUSNAME --region $REGNAME --query 'DBClusters[0].DBClusterArn' --output text 2>/dev/null`
  if [ -n "$CLUSTER_ARN" ] && [ "$CLUSTER_ARN" != "None" ]
  then
    PENDING_MAINT=`aws rds describe-pending-maintenance-actions --resource-identifier $CLUSTER_ARN --region $REGNAME --query 'PendingMaintenanceActions[*].PendingMaintenanceActionDetails[*].{Action:Action,AutoApplyDate:AutoAppliedAfterDate,CurrentApplyDate:CurrentApplyDate,Description:Description}' --output table 2>/dev/null`
  fi
else
  # For RDS, get the instance ARN
  INSTANCE_ARN=`aws rds describe-db-instances --db-instance-identifier $RDSNAME --region $REGNAME --query 'DBInstances[0].DBInstanceArn' --output text 2>/dev/null`
  if [ -n "$INSTANCE_ARN" ] && [ "$INSTANCE_ARN" != "None" ]
  then
    PENDING_MAINT=`aws rds describe-pending-maintenance-actions --resource-identifier $INSTANCE_ARN --region $REGNAME --query 'PendingMaintenanceActions[*].PendingMaintenanceActionDetails[*].{Action:Action,AutoApplyDate:AutoAppliedAfterDate,CurrentApplyDate:CurrentApplyDate,Description:Description}' --output table 2>/dev/null`
  fi
fi

if [ -z "$PENDING_MAINT" ] || echo "$PENDING_MAINT" | grep -q "None"
then
  echo "<font face="verdana" color="green">No pending maintenance actions found. The upgrade will not trigger additional maintenance tasks that could extend downtime.</font>" >> $html
else
  echo "<font face="verdana" color="orange"><b>WARNING:</b> Pending maintenance actions detected. These may be applied during the upgrade restart, potentially extending the downtime window beyond what the upgrade alone requires. Review and apply these separately before upgrading if you want predictable upgrade duration:</font>" >> $html
  echo "<br>" >> $html
  echo "<pre>$PENDING_MAINT</pre>" >> $html
fi
echo "<br>" >> $html
echo "<br>" >> $html

# Multi-database pre-upgrade check (per-database issues across all databases)
if [ "$DB_SCOPE_CHOICE" == "2" ]
then
echo "<font face="verdana" color="#ff6600">--- Per-Database Pre-Upgrade Summary (All Databases) ---</font>" >>$html
echo "<br>" >> $html
echo "<font face="verdana" color="#808080">Checking per-database upgrade blockers across all user databases...</font>" >> $html
echo "<br><br>" >> $html

for CHECKDB in $DB_LIST
do
  # Build per-database psql command
  case $AUTH_CHOICE in
    1) DBPSQLCL="psql -h $EP -p $RDSPORT -U $MASTERUSER -d $CHECKDB" ;;
    2) DBPSQLCL="psql \"host=$EP port=$RDSPORT dbname=$CHECKDB user=$MASTERUSER password=$TOKEN sslmode=verify-full sslrootcert=$REGNAME-bundle.pem\"" ;;
  esac

  echo "<font face="verdana" color="#0099cc"><b>Database: $CHECKDB</b></font>" >>$html
  echo "<br>" >> $html

  # Check reg* data types in this database
  DBREGCNT=`$DBPSQLCL -c "SELECT count(*) FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN ('pg_catalog.regproc'::pg_catalog.regtype,'pg_catalog.regprocedure'::pg_catalog.regtype,'pg_catalog.regoper'::pg_catalog.regtype,'pg_catalog.regoperator'::pg_catalog.regtype,'pg_catalog.regconfig'::pg_catalog.regtype,'pg_catalog.regdictionary'::pg_catalog.regtype) AND c.relnamespace = n.oid AND n.nspname NOT IN ('pg_catalog', 'information_schema');" 2>/dev/null | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ -n "$DBREGCNT" ] && [ "$DBREGCNT" -gt "0" ] 2>/dev/null
  then
    echo "<font face="verdana" color="red">&nbsp;&nbsp;&#x2716; reg* data types: $DBREGCNT unsupported reg* columns found (UPGRADE BLOCKER)</font>" >> $html
    echo "<br>" >> $html
    echo "`$DBPSQLCL --html -c "SELECT n.nspname AS schema, c.relname AS table_name, a.attname AS column_name, a.atttypid::regtype::text AS data_type FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid JOIN pg_catalog.pg_attribute a ON c.oid = a.attrelid WHERE NOT a.attisdropped AND a.atttypid IN ('pg_catalog.regproc'::pg_catalog.regtype,'pg_catalog.regprocedure'::pg_catalog.regtype,'pg_catalog.regoper'::pg_catalog.regtype,'pg_catalog.regoperator'::pg_catalog.regtype,'pg_catalog.regconfig'::pg_catalog.regtype,'pg_catalog.regdictionary'::pg_catalog.regtype) AND c.relnamespace = n.oid AND n.nspname NOT IN ('pg_catalog', 'information_schema');" 2>/dev/null |sed '$d'|sed '$d' ` " >>$html
  else
    echo "<font face="verdana" color="green">&nbsp;&nbsp;&#x2714; reg* data types: None found</font>" >> $html
  fi
  echo "<br>" >> $html

  # Check sql_identifier in this database
  DBSQLID=`$DBPSQLCL -c "SELECT count(*) FROM pg_attribute WHERE atttypid::regtype::text LIKE '%sql_identifier' AND attrelid IN (SELECT oid FROM pg_class WHERE relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname NOT IN ('information_schema','oracle','pg_catalog')));" 2>/dev/null | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ -n "$DBSQLID" ] && [ "$DBSQLID" -gt "0" ] 2>/dev/null
  then
    echo "<font face="verdana" color="orange">&nbsp;&nbsp;&#x26A0; sql_identifier: $DBSQLID columns found</font>" >> $html
  else
    echo "<font face="verdana" color="green">&nbsp;&nbsp;&#x2714; sql_identifier: None found</font>" >> $html
  fi
  echo "<br>" >> $html

  # Check extensions in this database
  DBEXTCNT=`$DBPSQLCL -c "SELECT COUNT(*) FROM pg_catalog.pg_extension e LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace WHERE n.nspname NOT LIKE 'pg_catalog';" 2>/dev/null | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ -n "$DBEXTCNT" ] && [ "$DBEXTCNT" -gt "0" ] 2>/dev/null
  then
    echo "<font face="verdana" color="orange">&nbsp;&nbsp;&#x2139; Extensions: $DBEXTCNT user extensions installed (verify compatibility with target version)</font>" >> $html
    echo "<br>" >> $html
    echo "`$DBPSQLCL --html -c "SELECT e.extname AS name, e.extversion AS version FROM pg_catalog.pg_extension e LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace WHERE n.nspname NOT LIKE 'pg_catalog' ORDER BY e.extname;" 2>/dev/null |sed '$d'|sed '$d' ` " >>$html
  else
    echo "<font face="verdana" color="green">&nbsp;&nbsp;&#x2714; Extensions: No user extensions</font>" >> $html
  fi
  echo "<br>" >> $html

  # Check views on system catalogs in this database
  DBVIEWCNT=`$DBPSQLCL -c "SELECT count(*) FROM pg_catalog.pg_class c LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('v','m') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast' AND pg_catalog.pg_table_is_visible(c.oid) AND pg_catalog.pg_get_userbyid(c.relowner) NOT LIKE 'rdsadmin';" 2>/dev/null | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ -n "$DBVIEWCNT" ] && [ "$DBVIEWCNT" -gt "0" ] 2>/dev/null
  then
    echo "<font face="verdana" color="orange">&nbsp;&nbsp;&#x26A0; Views: $DBVIEWCNT user views found (review for system catalog dependencies post-upgrade)</font>" >> $html
  else
    echo "<font face="verdana" color="green">&nbsp;&nbsp;&#x2714; Views: No user views dependent on system catalogs</font>" >> $html
  fi
  echo "<br><br>" >> $html

done
echo "<br>" >> $html
fi

#Version-pair-specific upgrade checks
echo "<font face="verdana" color="#ff6600">18. Version-specific upgrade considerations ($DBVER → $TDBVER): </font>" >>$html
echo "<br>" >> $html

# Extract major versions for comparison
MAJOR_FROM=$(echo $DBVER | cut -d. -f1)
MAJOR_TO=$(echo $TDBVER | cut -d. -f1)

# --- Upgrading FROM 12/13 TO 14+ : password_encryption default change ---
if [ "$MAJOR_FROM" -le "13" ] && [ "$MAJOR_TO" -ge "14" ]
then
  echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18a. password_encryption default changes (md5 → scram-sha-256 in PG14): </font>" >>$html
  echo "<br>" >> $html
  PWENC=`$PSQLCL -c "SHOW password_encryption;" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ "$PWENC" == "md5" ]
  then
    echo "<font face="verdana" color="orange">Current password_encryption is 'md5'. In PG14+, the default changes to 'scram-sha-256'. After upgrade, newly created passwords will use SCRAM. Ensure all client libraries support SCRAM authentication (libpq 10+, JDBC 42.2.0+). Existing MD5 passwords continue to work until reset.</font>" >> $html
  else
    echo "<font face="verdana" color="green">password_encryption is already '$PWENC'. No compatibility concern for this upgrade.</font>" >> $html
  fi
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

# --- Upgrading FROM 12/13 TO 14+ : vacuum_cleanup_index_scale_factor removed ---
if [ "$MAJOR_FROM" -le "13" ] && [ "$MAJOR_TO" -ge "14" ]
then
  echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18b. Removed parameter: vacuum_cleanup_index_scale_factor (removed in PG14): </font>" >>$html
  echo "<br>" >> $html
  VCISF=`$PSQLCL -c "SELECT name, setting FROM pg_settings WHERE name='vacuum_cleanup_index_scale_factor';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ -z "$VCISF" ] || [ "$VCISF" == "(0rows)" ]
  then
    echo "<font face="verdana" color="green">vacuum_cleanup_index_scale_factor is not set or already removed. No issue.</font>" >> $html
  else
    echo "<font face="verdana" color="orange">vacuum_cleanup_index_scale_factor is set in the current version. This parameter is removed in PG14. It will be silently dropped during upgrade. If you relied on this for index cleanup tuning, use vacuum_index_cleanup per-table storage parameter instead.</font>" >> $html
  fi
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

# --- Upgrading TO 15+ : hash_mem_multiplier default change (1.0 → 2.0) ---
if [ "$MAJOR_FROM" -le "14" ] && [ "$MAJOR_TO" -ge "15" ]
then
  echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18c. hash_mem_multiplier default changes (1.0 → 2.0 in PG15): </font>" >>$html
  echo "<br>" >> $html
  HMM=`$PSQLCL -c "SHOW hash_mem_multiplier;" 2>/dev/null | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  WORKMEM=`$PSQLCL -c "SHOW work_mem;" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  MAXCONN=`$PSQLCL -c "SHOW max_connections;" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ -z "$HMM" ] || [ "$HMM" == "1" ] || [ "$HMM" == "1.0" ]
  then
    echo "<font face="verdana" color="orange">hash_mem_multiplier is at 1.0 (PG14 default). After upgrading to PG15+, the default changes to 2.0. Hash operations (hash joins, hash aggregates) will use up to 2x more memory per operation. Current work_mem=$WORKMEM with max_connections=$MAXCONN. Review your memory budget: worst-case hash memory doubles. If you experience OOM after upgrade, explicitly set hash_mem_multiplier=1.0 in the parameter group to restore old behavior.</font>" >> $html
  else
    echo "<font face="verdana" color="green">hash_mem_multiplier is explicitly set to $HMM. This explicit value will carry through the upgrade. No unexpected change.</font>" >> $html
  fi
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

# --- Upgrading TO 18+ : max_parallel_workers_per_gather default change (2 → 0) ---
if [ "$MAJOR_TO" -ge "18" ]
then
  echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18d. max_parallel_workers_per_gather default changes (2 → 0 in PG18): </font>" >>$html
  echo "<br>" >> $html
  MPWPG=`$PSQLCL -c "SHOW max_parallel_workers_per_gather;" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ "$MPWPG" == "2" ] || [ "$MPWPG" == "0" ]
  then
    if [ "$MPWPG" == "2" ]
    then
      echo "<font face="verdana" color="orange"><b>IMPORTANT:</b> max_parallel_workers_per_gather is at the current default (2). In PG18, this default changes to 0 (parallel query disabled by default). If your workload relies on parallel queries (analytics, reporting, large aggregates), you MUST explicitly set max_parallel_workers_per_gather=2 (or higher) in your parameter group before upgrading. Otherwise, parallel queries will stop working after upgrade and performance may regress significantly for analytical workloads.</font>" >> $html
    else
      echo "<font face="verdana" color="green">max_parallel_workers_per_gather is already 0. PG18 default matches. No change expected.</font>" >> $html
    fi
  else
    echo "<font face="verdana" color="green">max_parallel_workers_per_gather is explicitly set to $MPWPG. This explicit value will carry through the upgrade.</font>" >> $html
  fi
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

# --- Upgrading FROM 15 TO 16+ : ICU collation version tracking strictness ---
if [ "$MAJOR_FROM" -le "15" ] && [ "$MAJOR_TO" -ge "16" ]
then
  echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18d-i. PostgreSQL 16 ICU collation version tracking: </font>" >>$html
  echo "<br>" >> $html
  echo "<font face="verdana" color="orange">PostgreSQL 16 introduces stricter ICU collation version tracking. After upgrade, the system will detect if the underlying ICU library version changed, which may require REINDEX on indexes using ICU collations. Run: SELECT indexrelid::regclass, collname FROM pg_index i JOIN pg_depend d ON d.objid = i.indexrelid JOIN pg_collation c ON c.oid = d.refobjid WHERE c.collprovider = 'i'; to identify affected indexes. Post-upgrade, check pg_index for indisvalid = false entries.</font>" >> $html
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

# --- Upgrading FROM 15 TO 16+ : vacuum_buffer_usage_limit new parameter ---
if [ "$MAJOR_FROM" -le "15" ] && [ "$MAJOR_TO" -ge "16" ]
then
  echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18d-ii. New parameter in PG16: vacuum_buffer_usage_limit (default 256kB): </font>" >>$html
  echo "<br>" >> $html
  echo "<font face="verdana" color="orange">PostgreSQL 16 introduces vacuum_buffer_usage_limit (default 256kB) which limits how much of the shared buffer pool VACUUM can use. This prevents vacuum from evicting frequently-accessed cached data. If you have custom vacuum tuning that expects vacuum to freely use the buffer cache, review this parameter after upgrade. For most workloads, the default is appropriate.</font>" >> $html
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

# --- Upgrading TO 16+ : Logical replication from standby ---
if [ "$MAJOR_TO" -ge "16" ]
then
  LOGREPCNT=`$PSQLCL -c "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_type='logical';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
  if [ "$LOGREPCNT" -gt "0" ]
  then
    echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18d-iii. Logical replication behavior change in PG16: </font>" >>$html
    echo "<br>" >> $html
    echo "<font face="verdana" color="orange">You have $LOGREPCNT logical replication slot(s). PostgreSQL 16 introduces logical replication from standbys. If using logical replication, review your slot configuration post-upgrade. Subscribers should be paused during the upgrade window and resumed after confirming slot health on the new version.</font>" >> $html
    echo "<br>" >> $html
    echo "<br>" >> $html
  fi
fi

# --- Upgrading TO 17+ : New reserved keywords ---
if [ "$MAJOR_FROM" -le "16" ] && [ "$MAJOR_TO" -ge "17" ]
then
  echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18d-iv. PostgreSQL 17 behavioral changes: </font>" >>$html
  echo "<br>" >> $html
  echo "<font face="verdana" color="orange">PostgreSQL 17 introduces: 1) io_combine_limit parameter (default 128kB) affecting large sequential scan performance. 2) Incremental backup support via summarize_wal (default off). 3) Streaming I/O infrastructure changes that may alter I/O patterns. 4) pg_stat_statements query IDs may change — capture baselines before upgrade. If you have monitoring dashboards that track by query_id, they will break across the version boundary.</font>" >> $html
  echo "<br>" >> $html
  echo "<br>" >> $html
fi

# --- Upgrading any version: Check random_page_cost and effective_io_concurrency (Aurora recommendations) ---
echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18d-v. Parameter review opportunity (post-upgrade best practice): </font>" >>$html
echo "<br>" >> $html
RPC=`$PSQLCL -c "SHOW random_page_cost;" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
EIC=`$PSQLCL -c "SHOW effective_io_concurrency;" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
PARAM_ISSUES=""
if [ "$RPC" == "4" ]
then
  PARAM_ISSUES="${PARAM_ISSUES}random_page_cost=4.0 (recommend 1.1 for Aurora/RDS SSD storage). "
fi
if [ "$EIC" == "1" ]
then
  PARAM_ISSUES="${PARAM_ISSUES}effective_io_concurrency=1 (recommend 200 for Aurora SSD storage). "
fi
if [ -n "$PARAM_ISSUES" ]
then
  echo "<font face="verdana" color="orange">Post-upgrade parameter tuning opportunity: ${PARAM_ISSUES}These are upstream defaults designed for spinning disks. Aurora/RDS uses SSD storage. Consider updating after upgrade for better query performance. Both are dynamic (no restart needed).</font>" >> $html
else
  echo "<font face="verdana" color="green">random_page_cost ($RPC) and effective_io_concurrency ($EIC) are already tuned for SSD storage. No action needed.</font>" >> $html
fi
echo "<br>" >> $html
echo "<br>" >> $html

# --- Upgrading any version: pg_stat_statements data loss warning ---
echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18e. pg_stat_statements data will be cleared: </font>" >>$html
echo "<br>" >> $html
PGSSCNT=`$PSQLCL -c "SELECT COUNT(*) FROM pg_stat_statements;" 2>/dev/null | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
if [ -n "$PGSSCNT" ] && [ "$PGSSCNT" -gt "0" ] 2>/dev/null
then
  echo "<font face="verdana" color="orange">pg_stat_statements has $PGSSCNT entries. This data is stored in shared memory and will be lost during the upgrade restart. Recommendation: Snapshot your top queries before upgrade (SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 100) to preserve performance baselines for comparison after upgrade. Query IDs may also change between major versions.</font>" >> $html
else
  echo "<font face="verdana" color="green">pg_stat_statements is empty or not installed. No data loss concern.</font>" >> $html
fi
echo "<br>" >> $html
echo "<br>" >> $html

# --- Upgrading any version: Check for pending parameter changes ---
echo "<font face="verdana" color="#ff6600">&nbsp;&nbsp;18f. Check for pending parameter changes (applied during upgrade restart): </font>" >>$html
echo "<br>" >> $html
PENDCNT=`$PSQLCL -c "SELECT COUNT(*) FROM pg_settings WHERE pending_restart = true;" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
if [ "$PENDCNT" -gt "0" ]
then
  echo "<font face="verdana" color="orange"><b>WARNING:</b> $PENDCNT parameter(s) are pending restart. These will be applied during the upgrade restart. Verify these are intentional before upgrading:</font>" >> $html
  echo "`$PSQLCL --html -c "SELECT name, setting, reset_val, source, context FROM pg_settings WHERE pending_restart = true ORDER BY name;"|sed '$d'|sed '$d' ` " >>$html
else
  echo "<font face="verdana" color="green">No pending parameter changes. Upgrade restart will not apply unexpected parameter modifications.</font>" >> $html
fi
echo "<br>" >> $html
echo "<br>" >> $html

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


