# PostgreSQL DBA MCP Server (Open Source / Local)

An open-source MCP (Model Context Protocol) server that provides safe, read-only diagnostic access to PostgreSQL through AI-powered tools such as Kiro, Claude Desktop, or Cursor.

**Works with:** Amazon RDS for PostgreSQL, Amazon Aurora PostgreSQL, and self-managed PostgreSQL (on premises, EC2, Docker, or another cloud).

## What It Does

Instead of manually running SQL queries and interpreting results, ask your AI assistant questions such as:

- "Run a health check on my database"
- "Are there any tables with bloat?"
- "Show me unused indexes wasting storage"
- "What's the cache hit ratio?"
- "Run parameter tuning for my Aurora PostgreSQL cluster `my-cluster`"
- "Show slow queries and auto_explain plans from CloudWatch Logs for the last 60 minutes"
- "Run all pre-upgrade checks for my database"
- "Explain this query's execution plan: `SELECT ...`"

The MCP server runs 39 predefined, read-only diagnostic queries across 11 categories. It does not accept dynamic SQL and does not modify database or AWS resources.

## Security Model

- **Query allowlist only**: the AI cannot generate or execute arbitrary SQL.
- **Read-only**: database queries are `SELECT` statements against system catalogs and statistics views.
- **No customer-table reads**: queries use `pg_stat_*`, `pg_catalog`, and `information_schema` metadata.
- **AWS-aware tools are read-only**: RDS and CloudWatch operations retrieve metadata or logs only.
- **Safe for production diagnostics**: the MCP cannot change database parameters, reboot instances, delete resources, or execute DDL/DML.

## Quick Start

### Prerequisites

All installations require:

- Python 3.10+
- Network access from the MCP host to the PostgreSQL endpoint
- A database user with the catalog and statistics privileges required by the read-only checks

The AWS-aware tools (`get_instance_info`, `get_parameter_recommendations`, and `get_slow_queries_from_logs`) also require:

- `boto3` (installed by `requirements.txt`)
- Valid AWS credentials available to the MCP server process
- `AWS_REGION` for the target database
- A least-privilege AWS profile with `rds:DescribeDBInstances` and `rds:DescribeDBClusters`
- For CloudWatch slow-query analysis: `logs:DescribeLogGroups`, `logs:StartQuery`, and `logs:GetQueryResults`

Use temporary credentials or an approved credential process where available. Do not store access keys or session tokens in MCP configuration files.

### Install

```bash
# Recommended: use a virtual environment
python3 -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate

pip install -r requirements.txt
```

### Configure a Direct Database Connection

Set the PostgreSQL connection details through environment variables:

```bash
export PGHOST=your-db-endpoint.region.rds.amazonaws.com
export PGPORT=5432
export PGDATABASE=postgres
export PGUSER=your_readonly_user
export PGPASSWORD=your_password

# Required only for AWS-aware tools
export AWS_REGION=us-west-2
export AWS_PROFILE=your-approved-readonly-profile
```

Or pass PostgreSQL connection values on the command line:

```bash
python server.py --host localhost --port 5432 --database mydb --user myuser --password mypass
```

### Connect Through an Existing Private-Network Tunnel

The MCP does not create or manage SSH, SSM, or VPN tunnels. When the database endpoint is private, start an approved tunnel before launching or reconnecting the MCP server and keep it running for the diagnostic session.

For example, if an approved tunnel forwards local port `5433` to the PostgreSQL endpoint on port `5432`:

```bash
# Run the approved tunnel command in a separate terminal.
# Example shape only; obtain the bastion and authentication details from the service owner.
ssh -L 5433:your-db-endpoint.region.rds.amazonaws.com:5432 your-approved-bastion -N

# Verify the local tunnel from the MCP host.
nc -vz -w 5 127.0.0.1 5433
```

Configure the MCP to connect through that listener:

```bash
export PGHOST=127.0.0.1
export PGPORT=5433
```

When `PGHOST` is a local tunnel address, AWS-aware tools cannot infer the RDS or Aurora identifier from the hostname. Supply the cluster or instance identifier explicitly in the request, for example: `Run parameter tuning for Aurora cluster my-cluster`.

## Add to Your AI Tool

### Kiro

Edit `~/.kiro/settings/mcp.json`:

```json
{
  "mcpServers": {
    "postgresql-dba": {
      "command": "/path/to/postgres-mcp-server/.venv/bin/python3",
      "args": ["/path/to/postgres-mcp-server/server.py"],
      "env": {
        "PGHOST": "your-db-endpoint",
        "PGPORT": "5432",
        "PGDATABASE": "postgres",
        "PGUSER": "readonly_user",
        "PGPASSWORD": "your_password",
        "AWS_REGION": "us-west-2",
        "AWS_PROFILE": "your-approved-readonly-profile"
      }
    }
  }
}
```

For a local tunnel, use `127.0.0.1` and the local forwarded port for `PGHOST` and `PGPORT`. After changing the configuration or refreshing credentials, reconnect the MCP server in Kiro.

> **Note:** Use the full path to the virtual-environment Python binary so MCP can find installed dependencies. Do not commit a configuration file that contains database passwords.

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "postgresql-dba": {
      "command": "/path/to/postgres-mcp-server/.venv/bin/python3",
      "args": ["/path/to/postgres-mcp-server/server.py"],
      "env": {
        "PGHOST": "your-db-endpoint",
        "PGPORT": "5432",
        "PGDATABASE": "postgres",
        "PGUSER": "readonly_user",
        "PGPASSWORD": "your_password",
        "AWS_REGION": "us-west-2",
        "AWS_PROFILE": "your-approved-readonly-profile"
      }
    }
  }
}
```

### Cursor

Edit `.cursor/mcp.json` in your project root:

```json
{
  "mcpServers": {
    "postgresql-dba": {
      "command": "/path/to/postgres-mcp-server/.venv/bin/python3",
      "args": ["/path/to/postgres-mcp-server/server.py"],
      "env": {
        "PGHOST": "your-db-endpoint",
        "PGPORT": "5432",
        "PGDATABASE": "postgres",
        "PGUSER": "readonly_user",
        "PGPASSWORD": "your_password",
        "AWS_REGION": "us-west-2",
        "AWS_PROFILE": "your-approved-readonly-profile"
      }
    }
  }
}
```

## Available Tools

| Tool | Description |
|------|-------------|
| `execute_health_query` | Run any of 39 predefined diagnostic queries by category and ID. |
| `list_health_queries` | List the available predefined queries. |
| `run_health_check` | Run the five-query health triage. |
| `explain_query` | Run `EXPLAIN` for a supplied `SELECT` statement without executing it. |
| `get_instance_info` | Retrieve RDS or Aurora engine, version, instance class, RAM, and status. Requires AWS credentials. |
| `get_parameter_recommendations` | Compare live settings with platform-aware recommendations. Requires AWS credentials and database connectivity. |
| `get_slow_queries_from_logs` | Read slow-query and `auto_explain` evidence from CloudWatch Logs. Requires AWS credentials, database connectivity, and published PostgreSQL logs. |

## Diagnostic Categories (39 queries)

| Category | Queries | Covers |
|----------|---------|--------|
| 1. Server Information | 1.1-1.3 | Version, uptime, database sizes |
| 2. System Configuration | 2.1-2.2 | Key parameters, memory settings |
| 3. Current Activity | 3.1-3.4 | Connections, long queries, locks |
| 4. Replication | 4.1-4.2 | Replication status, slot lag |
| 5. Storage and Bloat | 5.1-5.3 | Table sizes, dead tuples, tablespaces |
| 6. Performance | 6.1-6.4 | Top queries, cache hit ratio |
| 7. Vacuum and Maintenance | 7.1-7.3 | Vacuum needs, transaction ID wraparound |
| 8. Index Optimization | 8.1-8.3 | Unused indexes, duplicate indexes, scan ratios |
| 9. Summary Health Score | 9.1 | Composite health metrics |
| 10. Pre-Upgrade Checks | 10.1-10.8 | Common blockers, extensions, replication slots, and catalog compatibility checks |
| 11. Extended Health Checks | 11.1-11.6 | Primary keys, invalid indexes, sequence use, transaction ID age, and write-heavy tables |

## Slow Queries From CloudWatch Logs

Use a log-specific request when you want existing slow-query evidence rather than an estimated `EXPLAIN` result:

> Show slow queries and auto_explain plans from CloudWatch Logs for Aurora cluster `my-cluster` from the last 60 minutes.

The database must have `log_min_duration_statement` enabled, and actual plans require `auto_explain` to be loaded through `shared_preload_libraries`. PostgreSQL logs must be exported to CloudWatch Logs. If the logging prerequisites are not met, the tool reports the limitation and falls back to cumulative `pg_stat_statements` evidence when available.

For an estimated plan for a known query, provide the query text:

> Explain this query's execution plan: `SELECT ...`

The MCP rejects `EXPLAIN ANALYZE` because it would execute the query.

## Pre-Upgrade Checks

Category 10 runs eight read-only checks for common PostgreSQL major-version upgrade blockers:

- open prepared transactions
- unsupported `reg*` data types
- logical replication slots
- unknown data types
- `sql_identifier` usage
- installed extensions
- views dependent on system catalogs
- current user privileges

Use a request such as:

> Run all pre-upgrade checks for Aurora cluster `my-cluster`.

These checks provide generic readiness evidence. They do not certify a particular target version or replace Aurora's official pre-upgrade validation, extension compatibility review, or a rehearsed upgrade on a restored test environment. For a target-specific request such as an Aurora PostgreSQL 16 to 18 upgrade, confirm that the target engine version and every required extension are supported before scheduling the upgrade.

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
| DBA knowledge | Built-in platform-aware recommendations and upgrade checks | None (AI must determine guidance) |
| Scope | DBA diagnostics | General database access |
| Risk | Minimal (cannot run arbitrary SQL) | Higher (AI can submit expensive queries) |

## Contributors and Contributing

- See [component contributors](CONTRIBUTORS.md) for authorship and attribution.
- See the repository [contribution guidelines](../CONTRIBUTING.md) to report issues or propose changes.

## Disclaimer

This is sample code, not intended for production use without additional review and testing. Validate in a non-production environment first.

## License

MIT No Attribution. See [LICENSE](../LICENSE).
