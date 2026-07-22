# Amazon RDS & Aurora PostgreSQL DBA Toolkit

A collection of diagnostic scripts for Amazon RDS for PostgreSQL and Amazon Aurora PostgreSQL. These tools help database administrators, developers, and site reliability engineers assess database health, identify performance issues, and validate upgrade readiness.

> **Important:** These tools are sample code provided for educational and diagnostic purposes. Validate in a non-production environment first. Review all output before making changes to production databases.

## Tools

### 1. PostgreSQL Health Check (`health-check/`)

A comprehensive health check script that generates an HTML report covering 20+ diagnostic areas.

**What it checks:**
- Instance configuration and version currency
- Top 10 biggest tables (data + index sizes)
- Table bloat and dead tuple analysis
- Unused and duplicate indexes
- Vacuum and autovacuum status
- Transaction ID (XID) age and wraparound risk
- Sequence exhaustion risk
- Tables without primary keys
- CloudWatch metric snapshots (CPU, memory, IOPS, connections)
- Key parameter settings and recommendations

**How to run:**
```bash
# 1. Copy script to an EC2 instance with psql and AWS CLI configured
# 2. Make executable
chmod +x health-check/postgres_health_check.sh

# 3. Run the script
./health-check/postgres_health_check.sh

# 4. Follow the prompts:
#    - Enter RDS/Aurora endpoint
#    - Enter port (default 5432)
#    - Enter database name
#    - Enter master username and password
#    - Enter company name (no spaces)

# 5. Output: CompanyName_InstanceName_report_MM-DD-YY.html
```

**Prerequisites:**
- Amazon EC2 Linux instance with network access to your RDS/Aurora instance
- `psql` client installed
- AWS CLI configured (for CloudWatch metrics)
- Database user with SELECT access on all tables
- Works with PostgreSQL 13 and newer versions

**Sample report:** See `health-check/sample-reports/` for an example output.

---

### 2. Pre-Upgrade Check (`pre-upgrade-check/`)

Validates readiness for PostgreSQL major version upgrades by checking for known blockers and compatibility issues.

**What it checks:**
- Target version availability
- Unsupported `reg*` data types
- Open prepared transactions
- Logical replication slots
- `unknown` data types
- `sql_identifier` usage
- Extension compatibility
- Instance class support
- Storage capacity
- Read replica configuration
- Views dependent on system catalogs

**How to run:**
```bash
chmod +x pre-upgrade-check/pg_upgrade_pre_check.sh
./pre-upgrade-check/pg_upgrade_pre_check.sh
```

**Sample reports:** See `pre-upgrade-check/sample-reports/` for Aurora and RDS examples.

---

## Supported Engines

| Engine | Health Check | Pre-Upgrade Check |
|--------|-------------|-------------------|
| Amazon RDS for PostgreSQL | Yes | Yes |
| Amazon Aurora PostgreSQL | Yes | Yes |

## Security Considerations

- Scripts execute **read-only** queries against system catalogs and statistics views
- No data is modified, no DDL is executed
- Database credentials are entered interactively (not stored)
- Reports may contain table names, sizes, and configuration details — handle accordingly

## Related Tools

- [PostgreSQL DBA MCP Server for AWS DevOps Agent](https://github.com/aws-samples/sample-devops-agent-tools/pull/31) — AI-powered diagnostics via natural language using the same diagnostic queries

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
