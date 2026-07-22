# PostgreSQL DBA MCP Server (Open Source / Local)

An open-source MCP (Model Context Protocol) server that provides safe, read-only diagnostic access to any PostgreSQL instance through AI-powered tools like Kiro, Claude Desktop, or Cursor.

**Works with:** Amazon RDS for PostgreSQL, Amazon Aurora PostgreSQL, self-managed PostgreSQL (on-premises, EC2, Docker, any cloud).

## What It Does

Instead of manually running SQL queries and interpreting results, ask your AI assistant questions like:

- "Run a health check on my database"
- "Are there any tables with bloat?"
- "Show me unused indexes wasting storage"
- "What's the cache hit ratio?"
- "Is my database ready for a major version upgrade?"
- "Explain this slow query's execution plan"

The MCP server runs 39 predefined, read-only diagnostic queries across 11 categories. No dynamic SQL, no writes, safe for production.

## Security Model

- **Query-allowlist only**: the AI cannot generate or execute arbitrary SQL
- **Read-only**: only SELECT queries against system catalogs and statistics views
- **No data access**: queries only touch pg_stat_*, pg_catalog, and information_schema
- **Safe for production**: even if the AI is prompt-injected, it can only run the 39 vetted queries

## Quick Start

### Prerequisites

- Python 3.10+
- Network access to your PostgreSQL instance
- A database user with SELECT privileges on system catalogs

### Install

```bash
pip install -r requirements.txt
```

### Configure

Set connection details via environment variables:

```bash
export PGHOST=your-db-endpoint.region.rds.amazonaws.com
export PGPORT=5432
export PGDATABASE=postgres
export PGUSER=your_readonly_user
export PGPASSWORD=your_password
```

Or pass via command line:

```bash
python server.py --host localhost --port 5432 --database mydb --user myuser --password mypass
```

### Add to Your AI Tool

#### Kiro

Edit `~/.kiro/settings/mcp.json`:

```json
{
  "mcpServers": {
    "postgresql-dba": {
      "command": "python3",
      "args": ["/path/to/mcp-server/server.py"],
      "env": {
        "PGHOST": "your-db-endpoint",
        "PGPORT": "5432",
        "PGDATABASE": "postgres",
        "PGUSER": "readonly_user",
        "PGPASSWORD": "your_password"
      }
    }
  }
}
```

#### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "postgresql-dba": {
      "command": "python3",
      "args": ["/path/to/mcp-server/server.py"],
      "env": {
        "PGHOST": "your-db-endpoint",
        "PGPORT": "5432",
        "PGDATABASE": "postgres",
        "PGUSER": "readonly_user",
        "PGPASSWORD": "your_password"
      }
    }
  }
}
```

#### Cursor

Edit `.cursor/mcp.json` in your project root:

```json
{
  "mcpServers": {
    "postgresql-dba": {
      "command": "python3",
      "args": ["/path/to/mcp-server/server.py"],
      "env": {
        "PGHOST": "your-db-endpoint",
        "PGPORT": "5432",
        "PGDATABASE": "postgres",
        "PGUSER": "readonly_user",
        "PGPASSWORD": "your_password"
      }
    }
  }
}
```

## Available Tools

| Tool | Description |
|------|-------------|
| `execute_health_query` | Run any of 39 predefined queries by category/ID |
| `list_health_queries` | Show all available diagnostic queries |
| `run_health_check` | Quick 5-query health triage |
| `explain_query` | EXPLAIN plan for SELECT queries (never executes) |

## Diagnostic Categories (39 queries)

| Category | Queries | Covers |
|----------|---------|--------|
| 1. Server Information | 1.1-1.3 | Version, uptime, database sizes |
| 2. System Configuration | 2.1-2.2 | Key parameters, memory settings |
| 3. Current Activity | 3.1-3.4 | Connections, long queries, locks |
| 4. Replication | 4.1-4.2 | Replication status, slot lag |
| 5. Storage and Bloat | 5.1-5.3 | Table sizes, dead tuples, tablespaces |
| 6. Performance | 6.1-6.4 | Top queries, cache hit ratio |
| 7. Vacuum & Maintenance | 7.1-7.3 | Vacuum needs, XID wraparound |
| 8. Index Optimization | 8.1-8.3 | Unused/duplicate indexes, scan ratios |
| 9. Composite Health | 9.1 | Aggregated health metrics |
| 10. Pre-Upgrade Checks | 10.1-10.8 | Upgrade blockers, extensions, reg* types |
| 11. Extended Health | 11.1-11.6 | No-PK tables, invalid indexes, XID age |

## Database User Setup

Create a read-only user for the MCP server:

```sql
-- PostgreSQL 14+
CREATE USER mcp_readonly WITH PASSWORD 'your_secure_password';
GRANT pg_read_all_data TO mcp_readonly;

-- PostgreSQL 13 and earlier
CREATE USER mcp_readonly WITH PASSWORD 'your_secure_password';
GRANT CONNECT ON DATABASE mydb TO mcp_readonly;
GRANT USAGE ON SCHEMA public TO mcp_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO mcp_readonly;
```

## How It Differs from AWS Labs postgres-mcp-server

| | This Tool | AWS Labs postgres-mcp-server |
|---|---|---|
| SQL access | 39 predefined queries only | AI generates any SQL |
| Safety | Allowlist (strict) | Blocklist (best-effort) |
| DBA knowledge | Built-in (thresholds, decision trees) | None (AI must figure it out) |
| Scope | DBA diagnostics | General database access |
| Risk | Minimal (can't run arbitrary SQL) | Higher (AI could run expensive queries) |

## Disclaimer

This is sample code, not intended for production use without additional review and testing. Validate in a non-production environment first.

## License

MIT No Attribution. See [LICENSE](../LICENSE).
