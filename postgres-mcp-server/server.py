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

# Optional AWS SDK (gracefully degrade if not installed)
try:
    import boto3
    AWS_AVAILABLE = True
except ImportError:
    AWS_AVAILABLE = False

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
            "round(100.0 * n_tup_ins / NULLIF(n_tup_ins + n_tup_upd + n_tup_del, 0), 2) AS insert_pct, "
            "n_tup_ins + n_tup_upd + n_tup_del AS total_ops "
            "FROM pg_stat_user_tables "
            "WHERE (n_tup_ins + n_tup_upd + n_tup_del) > 0 "
            "ORDER BY coalesce(n_tup_upd,0) + coalesce(n_tup_del,0) DESC LIMIT 10"
        ),
    },
}


# ============================================================
# Tool Definitions
# ============================================================

def _flat_queries() -> dict:
    """Flatten the nested QUERY_ALLOWLIST into a single dict keyed by query ID."""
    flat = {}
    for cat_id, cat_dict in QUERY_ALLOWLIST.items():
        for key, val in cat_dict.items():
            if key.startswith("_"):
                continue
            flat[key] = val
    return flat


@mcp.tool()
def list_health_queries() -> str:
    """List all available diagnostic queries organized by category."""
    lines = []
    for cat_id in sorted(QUERY_ALLOWLIST.keys(), key=lambda x: float(x)):
        cat = QUERY_ALLOWLIST[cat_id]
        cat_name = cat.get("_category", f"Category {cat_id}")
        lines.append(f"\n## Category {cat_id}: {cat_name}")
        for qid in sorted(
            [k for k in cat if not k.startswith("_")], key=lambda x: float(x)
        ):
            lines.append(f"  - **{qid}**: {cat[qid]['name']}")
    return "\n".join(lines)


@mcp.tool()
def execute_health_query(query_id: str) -> str:
    """
    Execute a predefined diagnostic query by its ID (e.g., '1.1', '7.3', '10.1').
    Use list_health_queries() to see all available query IDs.
    """
    flat = _flat_queries()
    if query_id not in flat:
        return f"Error: Query ID '{query_id}' not found. Use list_health_queries() to see available IDs."
    query = flat[query_id]
    try:
        conn = _get_connection()
        results = _execute_query(conn, query["sql"])
        conn.close()
        return _format_results_table(results, f"{query_id}: {query['name']}")
    except Exception as e:
        return f"Error executing query {query_id}: {str(e)}"


@mcp.tool()
def run_health_check() -> str:
    """
    Run a quick health triage: cache hit ratio, dead tuples, connections,
    XID wraparound risk, and unused indexes. Returns a summary report.
    """
    triage_queries = ["6.3", "5.2", "3.1", "7.3", "8.1"]
    results = []
    try:
        conn = _get_connection()
        for qid in triage_queries:
            flat = _flat_queries()
            if qid in flat:
                query = flat[qid]
                rows = _execute_query(conn, query["sql"])
                results.append(_format_results_table(rows, f"{qid}: {query['name']}"))
        conn.close()
    except Exception as e:
        return f"Error running health check: {str(e)}"
    return "\n\n---\n\n".join(results)


@mcp.tool()
def explain_query(sql: str) -> str:
    """
    Run EXPLAIN (not EXECUTE) on a SELECT query to show the execution plan.
    Only SELECT statements are allowed.
    """
    stripped = sql.strip().rstrip(";")
    if not stripped.upper().startswith("SELECT"):
        return "Error: Only SELECT queries can be explained. Provide a SELECT statement."
    try:
        conn = _get_connection()
        explain_sql = f"EXPLAIN (FORMAT TEXT, VERBOSE, COSTS, BUFFERS) {stripped}"
        rows = conn.run(explain_sql)
        conn.close()
        plan_lines = [row[0] for row in rows]
        return "```\n" + "\n".join(plan_lines) + "\n```"
    except Exception as e:
        return f"Error explaining query: {str(e)}"


# ============================================================
# AWS-Aware Tools (require boto3 + AWS credentials)
# These tools gracefully return an error message if boto3
# is not installed or AWS credentials are not configured.
# ============================================================

# Instance class to memory mapping (GiB)
INSTANCE_MEMORY_MAP = {
    "db.t3.micro": 1, "db.t3.small": 2, "db.t3.medium": 4, "db.t3.large": 8,
    "db.t3.xlarge": 16, "db.t3.2xlarge": 32,
    "db.t4g.micro": 1, "db.t4g.small": 2, "db.t4g.medium": 4, "db.t4g.large": 8,
    "db.t4g.xlarge": 16, "db.t4g.2xlarge": 32,
    "db.m5.large": 8, "db.m5.xlarge": 16, "db.m5.2xlarge": 32, "db.m5.4xlarge": 64,
    "db.m5.8xlarge": 128, "db.m5.12xlarge": 192, "db.m5.16xlarge": 256, "db.m5.24xlarge": 384,
    "db.m6g.large": 8, "db.m6g.xlarge": 16, "db.m6g.2xlarge": 32, "db.m6g.4xlarge": 64,
    "db.m6g.8xlarge": 128, "db.m6g.12xlarge": 192, "db.m6g.16xlarge": 256,
    "db.m6i.large": 8, "db.m6i.xlarge": 16, "db.m6i.2xlarge": 32, "db.m6i.4xlarge": 64,
    "db.m6i.8xlarge": 128, "db.m6i.12xlarge": 192, "db.m6i.16xlarge": 256,
    "db.m7g.large": 8, "db.m7g.xlarge": 16, "db.m7g.2xlarge": 32, "db.m7g.4xlarge": 64,
    "db.m7g.8xlarge": 128, "db.m7g.12xlarge": 192, "db.m7g.16xlarge": 256,
    "db.r5.large": 16, "db.r5.xlarge": 32, "db.r5.2xlarge": 64, "db.r5.4xlarge": 128,
    "db.r5.8xlarge": 256, "db.r5.12xlarge": 384, "db.r5.16xlarge": 512, "db.r5.24xlarge": 768,
    "db.r6g.large": 16, "db.r6g.xlarge": 32, "db.r6g.2xlarge": 64, "db.r6g.4xlarge": 128,
    "db.r6g.8xlarge": 256, "db.r6g.12xlarge": 384, "db.r6g.16xlarge": 512,
    "db.r6i.large": 16, "db.r6i.xlarge": 32, "db.r6i.2xlarge": 64, "db.r6i.4xlarge": 128,
    "db.r6i.8xlarge": 256, "db.r6i.12xlarge": 384, "db.r6i.16xlarge": 512,
    "db.r7g.large": 16, "db.r7g.xlarge": 32, "db.r7g.2xlarge": 64, "db.r7g.4xlarge": 128,
    "db.r7g.8xlarge": 256, "db.r7g.12xlarge": 384, "db.r7g.16xlarge": 512,
    "db.x2g.large": 32, "db.x2g.xlarge": 64, "db.x2g.2xlarge": 128,
    "db.x2g.4xlarge": 256, "db.x2g.8xlarge": 512, "db.x2g.12xlarge": 768, "db.x2g.16xlarge": 1024,
}


def _get_aws_region():
    """Get AWS region from env or default."""
    return os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))


def _detect_instance_from_host():
    """Try to extract RDS/Aurora instance identifier from PGHOST."""
    host = DB_HOST
    # RDS endpoint format: <instance-id>.<random>.region.rds.amazonaws.com
    # Aurora endpoint: <cluster-id>.cluster-<random>.region.rds.amazonaws.com
    if "rds.amazonaws.com" in host:
        parts = host.split(".")
        return parts[0]  # instance or cluster identifier
    return None


@mcp.tool()
def get_instance_info(instance_id: str = "") -> str:
    """
    Get RDS/Aurora instance details: engine, version, instance class, RAM, storage.
    If instance_id is not provided, attempts to detect from PGHOST endpoint.
    Requires AWS credentials and boto3.
    """
    if not AWS_AVAILABLE:
        return "Error: boto3 not installed. Run: pip install boto3"
    if not instance_id:
        instance_id = _detect_instance_from_host()
        if not instance_id:
            return "Error: Could not detect instance ID from PGHOST. Provide instance_id explicitly."

    region = _get_aws_region()
    try:
        rds = boto3.client("rds", region_name=region)
        # Try as DB instance first
        try:
            resp = rds.describe_db_instances(DBInstanceIdentifier=instance_id)
            inst = resp["DBInstances"][0]
            instance_class = inst["DBInstanceClass"]
            engine = inst["Engine"]
            version = inst["EngineVersion"]
            storage = inst.get("AllocatedStorage", "N/A")
            ram_gib = INSTANCE_MEMORY_MAP.get(instance_class, "Unknown")
            cluster_id = inst.get("DBClusterIdentifier", "N/A")
            az = inst.get("AvailabilityZone", "N/A")
            status = inst.get("DBInstanceStatus", "N/A")

            lines = [
                f"**Instance:** {instance_id}",
                f"**Engine:** {engine} {version}",
                f"**Instance Class:** {instance_class}",
                f"**RAM:** {ram_gib} GiB",
                f"**Storage:** {storage} GB",
                f"**Cluster:** {cluster_id}",
                f"**AZ:** {az}",
                f"**Status:** {status}",
            ]
            return "\n".join(lines)
        except rds.exceptions.DBInstanceNotFoundFault:
            pass

        # Try as Aurora cluster
        try:
            resp = rds.describe_db_clusters(DBClusterIdentifier=instance_id)
            cluster = resp["DBClusters"][0]
            engine = cluster["Engine"]
            version = cluster["EngineVersion"]
            members = cluster.get("DBClusterMembers", [])

            lines = [
                f"**Cluster:** {instance_id}",
                f"**Engine:** {engine} {version}",
                f"**Status:** {cluster.get('Status', 'N/A')}",
                f"**Members:** {len(members)}",
            ]
            # Get instance details for first member
            if members:
                writer = [m for m in members if m.get("IsClusterWriter")]
                member_id = writer[0]["DBInstanceIdentifier"] if writer else members[0]["DBInstanceIdentifier"]
                resp2 = rds.describe_db_instances(DBInstanceIdentifier=member_id)
                inst = resp2["DBInstances"][0]
                instance_class = inst["DBInstanceClass"]
                ram_gib = INSTANCE_MEMORY_MAP.get(instance_class, "Unknown")
                lines.append(f"**Writer Instance:** {member_id}")
                lines.append(f"**Instance Class:** {instance_class}")
                lines.append(f"**RAM:** {ram_gib} GiB")
            return "\n".join(lines)
        except rds.exceptions.DBClusterNotFoundFault:
            return f"Error: No RDS instance or Aurora cluster found with identifier '{instance_id}' in region {region}."
    except Exception as e:
        return f"Error querying RDS API: {str(e)}"


@mcp.tool()
def get_parameter_recommendations(instance_id: str = "") -> str:
    """
    Get parameter tuning recommendations based on actual instance RAM and engine type.
    Compares current database settings against best practices for the specific platform.
    Requires AWS credentials and boto3.
    """
    if not AWS_AVAILABLE:
        return "Error: boto3 not installed. Run: pip install boto3"
    if not instance_id:
        instance_id = _detect_instance_from_host()
        if not instance_id:
            return "Error: Could not detect instance ID from PGHOST. Provide instance_id explicitly."

    region = _get_aws_region()
    try:
        rds = boto3.client("rds", region_name=region)
        # Get instance info
        try:
            resp = rds.describe_db_instances(DBInstanceIdentifier=instance_id)
            inst = resp["DBInstances"][0]
        except rds.exceptions.DBInstanceNotFoundFault:
            # Try cluster, get writer
            resp = rds.describe_db_clusters(DBClusterIdentifier=instance_id)
            cluster = resp["DBClusters"][0]
            members = cluster.get("DBClusterMembers", [])
            writer = [m for m in members if m.get("IsClusterWriter")]
            member_id = writer[0]["DBInstanceIdentifier"] if writer else members[0]["DBInstanceIdentifier"]
            resp = rds.describe_db_instances(DBInstanceIdentifier=member_id)
            inst = resp["DBInstances"][0]

        engine = inst["Engine"]
        instance_class = inst["DBInstanceClass"]
        ram_gib = INSTANCE_MEMORY_MAP.get(instance_class, 0)
        ram_mb = ram_gib * 1024
        is_aurora = "aurora" in engine

        # Get current settings from database
        conn = _get_connection()
        params = _execute_query(conn, (
            "SELECT name, setting, unit FROM pg_settings "
            "WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem',"
            "'effective_cache_size','random_page_cost','max_connections')"
        ))
        conn.close()

        current = {}
        for p in params:
            name = p["name"]
            setting = int(p["setting"]) if p["setting"].isdigit() else p["setting"]
            unit = p.get("unit", "")
            if unit == "8kB":
                current[name] = setting * 8 / 1024  # Convert to MB
            elif unit == "kB":
                current[name] = setting / 1024  # Convert to MB
            else:
                current[name] = setting

        # Calculate recommendations
        recommendations = []
        recommendations.append(f"**Instance:** {instance_class} ({ram_gib} GiB RAM)")
        recommendations.append(f"**Engine:** {engine}")
        recommendations.append("")

        # shared_buffers
        if is_aurora:
            recommended_sb = int(ram_mb * 0.75)
            recommendations.append(f"| shared_buffers | {int(current.get('shared_buffers', 0))} MB | {recommended_sb} MB | 75% RAM (Aurora default, managed) |")
        else:
            recommended_sb = int(ram_mb * 0.25)
            recommendations.append(f"| shared_buffers | {int(current.get('shared_buffers', 0))} MB | {recommended_sb} MB | 25% RAM for RDS |")

        # effective_cache_size
        if is_aurora:
            recommended_ecs = recommended_sb
            recommendations.append(f"| effective_cache_size | {int(current.get('effective_cache_size', 0))} MB | {recommended_ecs} MB | = shared_buffers on Aurora (no OS cache) |")
        else:
            recommended_ecs = int(ram_mb * 0.75)
            recommendations.append(f"| effective_cache_size | {int(current.get('effective_cache_size', 0))} MB | {recommended_ecs} MB | 75% RAM for RDS |")

        # work_mem
        max_conn = current.get("max_connections", 100)
        # Heuristic: RAM / (max_connections * 4) but minimum 4MB, max 256MB
        recommended_wm = min(256, max(4, int(ram_mb / (max_conn * 4))))
        recommendations.append(f"| work_mem | {int(current.get('work_mem', 0))} MB | {recommended_wm} MB | RAM/(max_conn*4), range 4-256 MB |")

        # maintenance_work_mem
        recommended_mwm = min(2048, int(ram_mb * 0.05))
        recommendations.append(f"| maintenance_work_mem | {int(current.get('maintenance_work_mem', 0))} MB | {recommended_mwm} MB | 5% RAM, max 2 GB |")

        # random_page_cost
        rpc = current.get("random_page_cost", 4)
        if is_aurora:
            recommendations.append(f"| random_page_cost | {rpc} | 1.1 | SSD storage (Aurora) |")
        else:
            recommendations.append(f"| random_page_cost | {rpc} | 1.1 | SSD storage (gp2/gp3/io1) |")

        header = "| Parameter | Current | Recommended | Reason |\n| --- | --- | --- | --- |"
        return "\n".join(recommendations[:3]) + "\n" + header + "\n" + "\n".join(recommendations[3:])

    except Exception as e:
        return f"Error generating recommendations: {str(e)}"


@mcp.tool()
def get_slow_queries_from_logs(instance_id: str = "", minutes: int = 60) -> str:
    """
    Query CloudWatch Logs for slow queries logged by log_min_duration_statement.
    Searches the PostgreSQL log group for the specified RDS/Aurora instance.
    Returns the top slow queries from the last N minutes (default: 60).
    Requires AWS credentials and boto3.
    """
    if not AWS_AVAILABLE:
        return "Error: boto3 not installed. Run: pip install boto3"
    if not instance_id:
        instance_id = _detect_instance_from_host()
        if not instance_id:
            return "Error: Could not detect instance ID from PGHOST. Provide instance_id explicitly."

    region = _get_aws_region()
    try:
        logs = boto3.client("logs", region_name=region)

        # Try common log group patterns
        log_groups_to_try = [
            f"/aws/rds/cluster/{instance_id}/postgresql",
            f"/aws/rds/instance/{instance_id}/postgresql",
        ]

        log_group = None
        for lg in log_groups_to_try:
            try:
                logs.describe_log_groups(logGroupNamePrefix=lg)
                log_group = lg
                break
            except Exception:
                continue

        if not log_group:
            return (
                f"Error: No CloudWatch log group found for '{instance_id}'. "
                f"Tried: {', '.join(log_groups_to_try)}. "
                "Ensure PostgreSQL logging is enabled and published to CloudWatch."
            )

        import time
        end_time = int(time.time() * 1000)
        start_time = end_time - (minutes * 60 * 1000)

        # CloudWatch Logs Insights query for slow queries
        query = (
            "fields @timestamp, @message "
            "| filter @message like /duration:/ "
            "| sort @timestamp desc "
            "| limit 25"
        )

        response = logs.start_query(
            logGroupName=log_group,
            startTime=start_time,
            endTime=end_time,
            queryString=query,
        )
        query_id = response["queryId"]

        # Poll for results (max 15 seconds)
        import time as time_mod
        for _ in range(15):
            time_mod.sleep(1)
            result = logs.get_query_results(queryId=query_id)
            if result["status"] == "Complete":
                break

        if result["status"] != "Complete":
            return "Error: CloudWatch Logs Insights query timed out."

        results = result.get("results", [])
        if not results:
            return f"No slow queries found in the last {minutes} minutes in {log_group}."

        lines = [f"**Slow Queries (last {minutes} min) from {log_group}**\n"]
        lines.append("| Timestamp | Duration | Query |")
        lines.append("| --- | --- | --- |")
        for row in results[:25]:
            fields = {f["field"]: f["value"] for f in row}
            msg = fields.get("@message", "")
            ts = fields.get("@timestamp", "")
            # Extract duration from message
            duration = ""
            if "duration:" in msg:
                parts = msg.split("duration:")
                if len(parts) > 1:
                    duration = parts[1].split(" ms")[0].strip() + " ms"
            query_text = msg[-150:] if len(msg) > 150 else msg
            lines.append(f"| {ts[:19]} | {duration} | {query_text[:100]} |")

        return "\n".join(lines)

    except Exception as e:
        return f"Error querying CloudWatch Logs: {str(e)}"


# ============================================================
# Entry Point
# ============================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="PostgreSQL DBA MCP Server")
    parser.add_argument("--host", default=os.environ.get("PGHOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("PGPORT", "5432")))
    parser.add_argument("--database", default=os.environ.get("PGDATABASE", "postgres"))
    parser.add_argument("--user", default=os.environ.get("PGUSER", "postgres"))
    parser.add_argument("--password", default=os.environ.get("PGPASSWORD", ""))
    args = parser.parse_args()

    # Override globals with command-line args
    DB_HOST = args.host
    DB_PORT = args.port
    DB_NAME = args.database
    DB_USER = args.user
    DB_PASSWORD = args.password

    mcp.run(transport="stdio")
