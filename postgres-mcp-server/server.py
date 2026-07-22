"""
PostgreSQL DBA MCP Server (Open Source / Local)

A query-allowlist MCP server providing safe, read-only diagnostic access
to any PostgreSQL instance (Amazon RDS, Aurora, self-managed, on-premises).

Safety: Only predefined diagnostic queries are permitted. No dynamic SQL.
Transport: stdio (for local AI tools like Kiro, Claude Desktop, Cursor)

Usage:
    python server.py --host <hostname> --port <port> --database <db> --user <user>

Author: Vivek Singh (https://www.linkedin.com/in/vivek-singh-4149aa19/)
"""

import os
import sys
import argparse
import pg8000.native
from fastmcp import FastMCP

# Initialize MCP server
mcp = FastMCP(
    "postgresql-dba-mcp",
    instructions=(
        "Read-only diagnostic access to PostgreSQL instances (RDS, Aurora, or self-managed). "
        "Provides tools for running predefined health check queries across 11 categories: "
        "server info, system configuration, current activity, replication, storage/bloat, "
        "performance (pg_stat_statements), vacuum/maintenance, index optimization, "
        "composite health scoring, pre-upgrade checks, and extended health checks. "
        "Only allowlisted queries are permitted.\n\n"
        "CRITICAL SAFETY RULES:\n"
        "1. NEVER recommend VACUUM FULL. Use pg_repack instead.\n"
        "2. ALWAYS recommend CREATE INDEX CONCURRENTLY.\n"
        "3. NEVER kill autovacuum workers.\n"
        "4. For connection issues, recommend pooling (PgBouncer) not higher max_connections.\n"
        "5. Use pg_cancel_backend() before pg_terminate_backend().\n"
        "6. For RDS/Aurora SSD storage: random_page_cost = 1.1.\n"
        "7. shared_buffers: RDS = 25% RAM, Aurora = 75% RAM (default), self-managed = 25% RAM.\n"
        "8. Aurora ignores checkpoint/WAL parameters (do not tune them on Aurora)."
    ),
)


# ============================================================
# Connection Configuration (from environment or command line)
# ============================================================

DB_HOST = os.environ.get("PGHOST", "localhost")
DB_PORT = int(os.environ.get("PGPORT", "5432"))
DB_NAME = os.environ.get("PGDATABASE", "postgres")
DB_USER = os.environ.get("PGUSER", "postgres")
DB_PASSWORD = os.environ.get("PGPASSWORD", "")


def _get_connection():
    """Create a pg8000 connection using environment/config credentials."""
    import ssl
    try:
        # Try with SSL first (required for RDS/Aurora)
        ssl_ctx = ssl.create_default_context()
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = ssl.CERT_NONE
        return pg8000.native.Connection(
            host=DB_HOST, port=DB_PORT, database=DB_NAME,
            user=DB_USER, password=DB_PASSWORD,
            ssl_context=ssl_ctx, timeout=15,
        )
    except Exception:
        # Fall back to no SSL (self-managed PostgreSQL)
        return pg8000.native.Connection(
            host=DB_HOST, port=DB_PORT, database=DB_NAME,
            user=DB_USER, password=DB_PASSWORD,
            timeout=15,
        )


def _execute_query(conn, sql: str) -> list[dict]:
    """Execute a query and return results as list of dicts."""
    rows = conn.run(sql)
    if not rows:
        return []
    columns = [col["name"] for col in conn.columns]
    return [dict(zip(columns, row)) for row in rows]


def _format_results_table(results: list[dict], query_name: str) -> str:
    """Format query results as a markdown table."""
    if not results:
        return f"**{query_name}**: No rows returned."
    columns = list(results[0].keys())
    header = "| " + " | ".join(columns) + " |"
    separator = "| " + " | ".join(["---"] * len(columns)) + " |"
    rows = []
    for row in results[:100]:
        values = [str(row[col] if row[col] is not None else "NULL")[:100] for col in columns]
        rows.append("| " + " | ".join(values) + " |")
    table = f"**{query_name}**\n\n" + "\n".join([header, separator] + rows)
    if len(results) > 100:
        table += f"\n\n*Showing 100 of {len(results)} total rows.*"
    return table
QUERY_ALLOWLIST: dict[str, dict[str, dict]] = {
    "1": {
        "_category": "Server Information",
        "1.1": {
            "name": "PostgreSQL Version",
            "sql": "SELECT version()",
        },
        "1.2": {
            "name": "Server Uptime",
            "sql": "SELECT pg_postmaster_start_time(), now() - pg_postmaster_start_time() AS uptime",
        },
        "1.3": {
            "name": "Database Size",
            "sql": (
                "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size "
                "FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC"
            ),
        },
    },
    "2": {
        "_category": "System Configuration",
        "2.1": {
            "name": "Key Parameters",
            "sql": (
                "SELECT name, setting, unit, source, context "
                "FROM pg_settings "
                "WHERE name IN ("
                "'shared_buffers','work_mem','maintenance_work_mem','effective_cache_size',"
                "'random_page_cost','seq_page_cost','effective_io_concurrency',"
                "'checkpoint_timeout','max_wal_size','min_wal_size','wal_buffers',"
                "'max_connections','jit','default_statistics_target',"
                "'autovacuum_vacuum_cost_delay','autovacuum_vacuum_scale_factor',"
                "'autovacuum_analyze_scale_factor','autovacuum_max_workers',"
                "'vacuum_cost_limit','idle_in_transaction_session_timeout',"
                "'statement_timeout','lock_timeout','ssl','password_encryption',"
                "'log_min_duration_statement','log_connections','log_disconnections'"
                ") ORDER BY name"
            ),
        },
        "2.2": {
            "name": "Memory Settings (Computed)",
            "sql": (
                "SELECT name, setting, unit, "
                "pg_size_pretty(setting::bigint * "
                "CASE unit WHEN '8kB' THEN 8192 WHEN 'kB' THEN 1024 "
                "WHEN 'MB' THEN 1048576 ELSE 1 END) AS pretty_value "
                "FROM pg_settings "
                "WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem',"
                "'effective_cache_size','wal_buffers') ORDER BY name"
            ),
        },
    },
    "3": {
        "_category": "Current Activity",
        "3.1": {
            "name": "Connection Summary",
            "sql": (
                "SELECT state, count(*) AS count "
                "FROM pg_stat_activity "
                "WHERE backend_type = 'client backend' "
                "GROUP BY state ORDER BY count DESC"
            ),
        },
        "3.2": {
            "name": "Long Running Queries (>30s)",
            "sql": (
                "SELECT pid, now() - query_start AS duration, state, "
                "left(query, 200) AS query_snippet "
                "FROM pg_stat_activity "
                "WHERE state != 'idle' "
                "AND query_start < now() - interval '30 seconds' "
                "AND backend_type = 'client backend' "
                "ORDER BY duration DESC LIMIT 20"
            ),
        },
        "3.3": {
            "name": "Lock Waits",
            "sql": (
                "SELECT blocked.pid AS blocked_pid, "
                "blocked.query AS blocked_query, "
                "blocking.pid AS blocking_pid, "
                "blocking.query AS blocking_query, "
                "now() - blocked.query_start AS wait_duration "
                "FROM pg_stat_activity blocked "
                "JOIN pg_locks bl ON bl.pid = blocked.pid "
                "JOIN pg_locks lk ON lk.locktype = bl.locktype "
                "AND lk.database IS NOT DISTINCT FROM bl.database "
                "AND lk.relation IS NOT DISTINCT FROM bl.relation "
                "AND lk.page IS NOT DISTINCT FROM bl.page "
                "AND lk.tuple IS NOT DISTINCT FROM bl.tuple "
                "AND lk.virtualxid IS NOT DISTINCT FROM bl.virtualxid "
                "AND lk.transactionid IS NOT DISTINCT FROM bl.transactionid "
                "AND lk.classid IS NOT DISTINCT FROM bl.classid "
                "AND lk.objid IS NOT DISTINCT FROM bl.objid "
                "AND lk.objsubid IS NOT DISTINCT FROM bl.objsubid "
                "AND lk.pid != bl.pid "
                "JOIN pg_stat_activity blocking ON blocking.pid = lk.pid "
                "WHERE NOT bl.granted LIMIT 20"
            ),
        },
        "3.4": {
            "name": "Connection Counts by User and Database",
            "sql": (
                "SELECT usename, datname, state, count(*) "
                "FROM pg_stat_activity "
                "WHERE backend_type = 'client backend' "
                "GROUP BY usename, datname, state "
                "ORDER BY count DESC LIMIT 30"
            ),
        },
    },
}

# Category 4: Replication
QUERY_ALLOWLIST["4"] = {
    "_category": "Replication",
    "4.1": {
        "name": "Replication Status",
        "sql": (
            "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, "
            "replay_lsn, "
            "pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes, "
            "write_lag, flush_lag, replay_lag "
            "FROM pg_stat_replication"
        ),
    },
    "4.2": {
        "name": "Replication Slots",
        "sql": (
            "SELECT slot_name, slot_type, active, "
            "pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes, "
            "pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_size "
            "FROM pg_replication_slots"
        ),
    },
}

# Category 5: Storage & Bloat
QUERY_ALLOWLIST["5"] = {
    "_category": "Storage and Bloat",
    "5.1": {
        "name": "Top 20 Tables by Size",
        "sql": (
            "SELECT schemaname, relname, "
            "pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size, "
            "pg_size_pretty(pg_relation_size(schemaname || '.' || relname)) AS table_size, "
            "pg_size_pretty(pg_indexes_size(schemaname || '.' || relname)) AS index_size, "
            "n_live_tup, n_dead_tup "
            "FROM pg_stat_user_tables "
            "ORDER BY pg_total_relation_size(schemaname || '.' || relname) DESC "
            "LIMIT 20"
        ),
    },
    "5.2": {
        "name": "Table Bloat Estimate",
        "sql": (
            "SELECT schemaname, relname, n_live_tup, n_dead_tup, "
            "CASE WHEN n_live_tup > 0 "
            "THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2) "
            "ELSE 0 END AS dead_tuple_pct, "
            "pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size "
            "FROM pg_stat_user_tables "
            "WHERE n_dead_tup > 1000 "
            "ORDER BY n_dead_tup DESC LIMIT 20"
        ),
    },
    "5.3": {
        "name": "Tablespace Usage",
        "sql": (
            "SELECT spcname, pg_size_pretty(pg_tablespace_size(spcname)) AS size "
            "FROM pg_tablespace ORDER BY pg_tablespace_size(spcname) DESC"
        ),
    },
}

# Category 6: Performance (pg_stat_statements)
QUERY_ALLOWLIST["6"] = {
    "_category": "Performance",
    "6.1": {
        "name": "Top 20 Queries by Total Time",
        "sql": (
            "SELECT queryid, left(query, 200) AS query_snippet, "
            "calls, round(total_exec_time::numeric, 2) AS total_ms, "
            "round(mean_exec_time::numeric, 2) AS mean_ms, "
            "rows, "
            "round((shared_blks_hit * 100.0 / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 2) "
            "AS cache_hit_pct "
            "FROM pg_stat_statements "
            "WHERE userid != 10 "
            "ORDER BY total_exec_time DESC LIMIT 20"
        ),
    },
    "6.2": {
        "name": "Top 20 Queries by Mean Time",
        "sql": (
            "SELECT queryid, left(query, 200) AS query_snippet, "
            "calls, round(mean_exec_time::numeric, 2) AS mean_ms, "
            "round(total_exec_time::numeric, 2) AS total_ms, "
            "rows "
            "FROM pg_stat_statements "
            "WHERE calls > 10 AND userid != 10 "
            "ORDER BY mean_exec_time DESC LIMIT 20"
        ),
    },
    "6.3": {
        "name": "Cache Hit Ratio (Overall)",
        "sql": (
            "SELECT "
            "sum(blks_hit) AS blocks_hit, "
            "sum(blks_read) AS blocks_read, "
            "round(sum(blks_hit) * 100.0 / NULLIF(sum(blks_hit) + sum(blks_read), 0), 2) "
            "AS cache_hit_pct "
            "FROM pg_stat_database"
        ),
    },
    "6.4": {
        "name": "Index Hit Ratio",
        "sql": (
            "SELECT "
            "sum(idx_blks_hit) AS index_blocks_hit, "
            "sum(idx_blks_read) AS index_blocks_read, "
            "round(sum(idx_blks_hit) * 100.0 / "
            "NULLIF(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2) AS index_hit_pct "
            "FROM pg_statio_user_indexes"
        ),
    },
}

# Category 7: Vacuum & Maintenance
QUERY_ALLOWLIST["7"] = {
    "_category": "Vacuum and Maintenance",
    "7.1": {
        "name": "Tables Needing Vacuum (Most Dead Tuples)",
        "sql": (
            "SELECT schemaname, relname, n_live_tup, n_dead_tup, "
            "last_vacuum, last_autovacuum, last_analyze, last_autoanalyze, "
            "vacuum_count, autovacuum_count "
            "FROM pg_stat_user_tables "
            "ORDER BY n_dead_tup DESC LIMIT 20"
        ),
    },
    "7.2": {
        "name": "Tables Never Vacuumed",
        "sql": (
            "SELECT schemaname, relname, n_live_tup, n_dead_tup, "
            "last_vacuum, last_autovacuum "
            "FROM pg_stat_user_tables "
            "WHERE last_vacuum IS NULL AND last_autovacuum IS NULL "
            "AND n_live_tup > 1000 "
            "ORDER BY n_dead_tup DESC LIMIT 20"
        ),
    },
    "7.3": {
        "name": "Transaction ID Age (Wraparound Risk)",
        "sql": (
            "SELECT datname, age(datfrozenxid) AS xid_age, "
            "current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age, "
            "round(100.0 * age(datfrozenxid) / "
            "current_setting('autovacuum_freeze_max_age')::bigint, 2) AS pct_toward_wraparound "
            "FROM pg_database "
            "WHERE datistemplate = false "
            "ORDER BY age(datfrozenxid) DESC"
        ),
    },
}

# Category 8: Index Optimization
QUERY_ALLOWLIST["8"] = {
    "_category": "Index Optimization",
    "8.1": {
        "name": "Unused Indexes",
        "sql": (
            "SELECT schemaname, relname, indexrelname, "
            "pg_size_pretty(pg_relation_size(indexrelid)) AS index_size, "
            "idx_scan, idx_tup_read "
            "FROM pg_stat_user_indexes "
            "WHERE idx_scan = 0 "
            "AND indexrelid NOT IN "
            "(SELECT conindid FROM pg_constraint WHERE contype IN ('p','u')) "
            "ORDER BY pg_relation_size(indexrelid) DESC LIMIT 20"
        ),
    },
    "8.2": {
        "name": "Duplicate Indexes",
        "sql": (
            "SELECT pg_size_pretty(sum(pg_relation_size(idx))::bigint) AS size, "
            "(array_agg(idx))[1] AS idx1, (array_agg(idx))[2] AS idx2, "
            "count(*) AS num_duplicates "
            "FROM ("
            "  SELECT indexrelid::regclass AS idx, "
            "  (indrelid::text || E'\\n' || indclass::text || E'\\n' || "
            "  indkey::text || E'\\n' || coalesce(indexprs::text,'') || E'\\n' || "
            "  coalesce(indpred::text,'')) AS key "
            "  FROM pg_index"
            ") sub "
            "GROUP BY key HAVING count(*) > 1 "
            "ORDER BY sum(pg_relation_size(idx)) DESC LIMIT 10"
        ),
    },
    "8.3": {
        "name": "Index Scan vs Sequential Scan Ratio",
        "sql": (
            "SELECT schemaname, relname, "
            "seq_scan, idx_scan, "
            "CASE WHEN (seq_scan + idx_scan) > 0 "
            "THEN round(100.0 * idx_scan / (seq_scan + idx_scan), 2) "
            "ELSE 0 END AS idx_scan_pct, "
            "n_live_tup "
            "FROM pg_stat_user_tables "
            "WHERE n_live_tup > 10000 "
            "ORDER BY seq_scan DESC LIMIT 20"
        ),
    },
}

# Category 9: Composite Health Score
QUERY_ALLOWLIST["9"] = {
    "_category": "Summary Health Score",
    "9.1": {
        "name": "Composite Health Metrics",
        "sql": (
            "SELECT "
            "'cache_hit_ratio' AS metric, "
            "round(sum(blks_hit) * 100.0 / NULLIF(sum(blks_hit) + sum(blks_read), 0), 2)::text AS value "
            "FROM pg_stat_database WHERE datname = current_database() "
            "UNION ALL "
            "SELECT 'dead_tuple_ratio', "
            "round(sum(n_dead_tup) * 100.0 / NULLIF(sum(n_live_tup) + sum(n_dead_tup), 0), 2)::text "
            "FROM pg_stat_user_tables "
            "UNION ALL "
            "SELECT 'active_connections', count(*)::text "
            "FROM pg_stat_activity WHERE backend_type = 'client backend' "
            "UNION ALL "
            "SELECT 'max_connections', current_setting('max_connections') "
            "UNION ALL "
            "SELECT 'xid_age_pct', "
            "round(100.0 * max(age(datfrozenxid)) / "
            "current_setting('autovacuum_freeze_max_age')::bigint, 2)::text "
            "FROM pg_database WHERE datistemplate = false "
            "UNION ALL "
            "SELECT 'uptime_hours', "
            "round(extract(epoch FROM now() - pg_postmaster_start_time()) / 3600, 1)::text"
        ),
    },
}


# ============================================================
# Database Connection Helper
# ============================================================

def _get_db_credentials(secret_arn: str) -> dict:
    """Retrieve database credentials from Secrets Manager."""
    response = secretsmanager_client.get_secret_value(SecretId=secret_arn)
    return json.loads(response["SecretString"])


def _get_connection(instance_endpoint: str, port: int, database: str, secret_arn: str):
    """Create a pg8000 connection using credentials from Secrets Manager."""
    import logging
    import ssl
    logger = logging.getLogger(__name__)
    
    logger.info(f"Getting credentials from Secrets Manager: {secret_arn[:50]}...")
QUERY_ALLOWLIST["10"] = {
    "_category": "Pre-Upgrade Checks",
    "10.1": {
        "name": "Open Prepared Transactions",
        "sql": "SELECT gid, prepared, owner, database FROM pg_catalog.pg_prepared_xacts",
    },
    "10.2": {
        "name": "Unsupported reg* Data Types",
        "sql": (
            "SELECT n.nspname AS schema, c.relname AS table_name, a.attname AS column_name, "
            "a.atttypid::regtype::text AS data_type "
            "FROM pg_catalog.pg_class c "
            "JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid "
            "JOIN pg_catalog.pg_attribute a ON c.oid = a.attrelid "
            "WHERE NOT a.attisdropped "
            "AND a.atttypid IN ("
            "'pg_catalog.regproc'::pg_catalog.regtype,"
            "'pg_catalog.regprocedure'::pg_catalog.regtype,"
            "'pg_catalog.regoper'::pg_catalog.regtype,"
            "'pg_catalog.regoperator'::pg_catalog.regtype,"
            "'pg_catalog.regconfig'::pg_catalog.regtype,"
            "'pg_catalog.regdictionary'::pg_catalog.regtype) "
            "AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        ),
    },
    "10.3": {
        "name": "Logical Replication Slots",
        "sql": (
            "SELECT slot_name, slot_type, active, database, "
            "pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes "
            "FROM pg_replication_slots WHERE slot_type = 'logical'"
        ),
    },
    "10.4": {
        "name": "Unknown Data Types",
        "sql": (
            "SELECT table_schema, table_name, column_name, data_type "
            "FROM information_schema.columns "
            "WHERE data_type ILIKE 'unknown'"
        ),
    },
    "10.5": {
        "name": "sql_identifier Data Type Usage",
        "sql": (
            "SELECT pg_namespace.nspname AS schema, pg_class.relname AS table_name, "
            "attname AS column_name "
            "FROM pg_attribute "
            "JOIN pg_class ON attrelid = oid "
            "JOIN pg_namespace ON relnamespace = pg_namespace.oid "
            "WHERE atttypid::regtype::text LIKE '%sql_identifier' "
            "AND nspname NOT IN ('information_schema', 'oracle')"
        ),
    },
    "10.6": {
        "name": "Extensions Installed (for upgrade compatibility)",
        "sql": (
            "SELECT e.extname AS name, e.extversion AS version, "
            "n.nspname AS schema "
            "FROM pg_catalog.pg_extension e "
            "LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace "
            "ORDER BY e.extname"
        ),
    },
    "10.7": {
        "name": "Views Dependent on System Catalogs",
        "sql": (
            "SELECT n.nspname AS schema, c.relname AS name, "
            "CASE c.relkind WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' END AS type, "
            "pg_catalog.pg_get_userbyid(c.relowner) AS owner "
            "FROM pg_catalog.pg_class c "
            "LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
            "WHERE c.relkind IN ('v','m') "
            "AND n.nspname NOT IN ('pg_catalog','information_schema') "
            "AND n.nspname !~ '^pg_toast' "
            "AND pg_catalog.pg_table_is_visible(c.oid) "
            "AND pg_catalog.pg_get_userbyid(c.relowner) NOT LIKE 'rdsadmin' "
            "ORDER BY 1, 2"
        ),
    },
    "10.8": {
        "name": "Current User Privileges",
        "sql": (
            "SELECT r.rolname, r.rolsuper, r.rolcreaterole, r.rolcreatedb, "
            "ARRAY(SELECT b.rolname FROM pg_catalog.pg_auth_members m "
            "JOIN pg_catalog.pg_roles b ON m.roleid = b.oid "
            "WHERE m.member = r.oid) AS member_of "
            "FROM pg_catalog.pg_roles r WHERE r.rolname = current_user"
        ),
    },
}


# ============================================================
# Category 11: Extended Health Checks (from v2 health_check skill)
# ============================================================

QUERY_ALLOWLIST["11"] = {
    "_category": "Extended Health Checks",
    "11.1": {
        "name": "Tables Without Primary Key",
        "sql": (
            "SELECT n.nspname AS schema_name, c.relname AS table_name, "
            "pg_size_pretty(pg_total_relation_size(c.oid)) AS table_size "
            "FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid "
            "WHERE c.relkind = 'r' "
            "AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast') "
            "AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = c.oid AND contype = 'p') "
            "ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 15"
        ),
    },
    "11.2": {
        "name": "Invalid Indexes",
        "sql": (
            "SELECT n.nspname AS schema_name, c.relname AS index_name, "
            "t.relname AS table_name, "
            "pg_size_pretty(pg_relation_size(c.oid)) AS index_size "
            "FROM pg_class c "
            "JOIN pg_index i ON c.oid = i.indexrelid "
            "JOIN pg_class t ON i.indrelid = t.oid "
            "JOIN pg_namespace n ON c.relnamespace = n.oid "
            "WHERE NOT i.indisvalid "
            "ORDER BY pg_relation_size(c.oid) DESC"
        ),
    },
    "11.3": {
        "name": "Sequences Near Exhaustion (>30% used)",
        "sql": (
            "SELECT schemaname AS schema_name, sequencename AS sequence_name, "
            "data_type, last_value, max_value, "
            "ROUND(100.0 * last_value / max_value, 2) AS pct_used "
            "FROM pg_sequences WHERE last_value IS NOT NULL "
            "AND ROUND(100.0 * last_value / max_value, 2) > 30 "
            "ORDER BY pct_used DESC LIMIT 10"
        ),
    },
    "11.4": {
        "name": "Database Transaction ID Age",
        "sql": (
            "SELECT datname, age(datfrozenxid) AS age, "
            "2147483647 - age(datfrozenxid) AS remaining_until_wraparound "
            "FROM pg_database ORDER BY age DESC LIMIT 5"
        ),
    },
    "11.5": {
        "name": "Table Transaction ID Age (Top 10)",
        "sql": (
            "SELECT c.relnamespace::regnamespace AS schema_name, "
            "c.relname AS table_name, "
            "greatest(age(c.relfrozenxid), age(t.relfrozenxid)) AS age, "
            "2147483647 - greatest(age(c.relfrozenxid), age(t.relfrozenxid)) AS remaining "
            "FROM pg_class c "
            "LEFT JOIN pg_class t ON c.reltoastrelid = t.oid "
            "WHERE c.relkind IN ('r','m') "
            "ORDER BY age DESC LIMIT 10"
        ),
    },
    "11.6": {
        "name": "UPDATE/DELETE Heavy Tables",
        "sql": (
            "SELECT relname, "
            "round(100.0 * n_tup_upd / NULLIF(n_tup_ins + n_tup_upd + n_tup_del, 0), 2) AS update_pct, "
            "round(100.0 * n_tup_del / NULLIF(n_tup_ins + n_tup_upd + n_tup_del, 0), 2) AS delete_pct, "
