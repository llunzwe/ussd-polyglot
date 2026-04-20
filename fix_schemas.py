import re
import os
import glob

SCHEMA_DIR = "/home/eng/Documents/ussd-polyglot/postgres-schema"

def fix_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    original = content
    basename = os.path.basename(filepath)
    
    # 1. Fix FK references to app.application_registry in early migrations
    if basename < "V030":
        content = re.sub(
            r"REFERENCES\s+app\.application_registry\s*\(application_id\)",
            "",
            content
        )
    
    # 2. Fix partial indexes with NOW()
    def fix_now_index(match):
        full = match.group(0)
        full = re.sub(r"\s+WHERE\s+[^;]+", "", full)
        return full
    
    content = re.sub(
        r"CREATE INDEX IF NOT EXISTS \w+\s+ON\s+[^)]+\)\s+WHERE[^;]*NOW\(\)[^;]*;",
        fix_now_index,
        content
    )
    
    # 3. Fix V013 severity vs alert_severity
    if basename == "V013__observability_metrics.sql":
        content = content.replace(
            "ON observability.alerts(status, severity)",
            "ON observability.alerts(status, alert_severity)"
        )
    
    # 4. Add ltree extension in V011
    if basename == "V011__core_agent_relationships.sql":
        if "CREATE EXTENSION IF NOT EXISTS ltree;" not in content:
            content = content.replace(
                "BEGIN;\n\n-- =============================================================================\n-- CREATE TABLE: agent_relationships",
                "BEGIN;\n\nCREATE EXTENSION IF NOT EXISTS ltree;\n\n-- =============================================================================\n-- CREATE TABLE: agent_relationships"
            )
    
    # 5. Fix unprotected TimescaleDB compression sections
    # Find blocks starting with TIMESCALEDB header and containing add_compression_policy
    pattern = re.compile(
        r"((?:--\s*={5,}\n--\s*TIMESCALEDB[^=]*--\s*={5,}\n))"
        r"(ALTER TABLE[^;]+SET\s*\(\s*timescaledb\.compress[^)]+\);\n"
        r"SELECT add_compression_policy\([^)]+\);)",
        re.DOTALL
    )
    def wrap_ts(match):
        header = match.group(1)
        body = match.group(2)
        if "DO $$" not in body:
            return f"{header}DO $$\nBEGIN\n{body}\nEXCEPTION WHEN OTHERS THEN\n    RAISE NOTICE 'TimescaleDB feature skipped: %', SQLERRM;\nEND;\n$$;"
        return match.group(0)
    content = pattern.sub(wrap_ts, content)
    
    # 6. Fix hypertable tables with single-column UUID PRIMARY KEY
    # Find all create_hypertable calls in the file
    hypertable_calls = re.findall(
        r"create_hypertable\(\s*'([^']+)'\s*,\s*'([^']+)'",
        content
    )
    
    for table_name, time_col in hypertable_calls:
        # Find CREATE TABLE for this table
        table_re = re.escape(table_name)
        # Look for "CREATE TABLE IF NOT EXISTS table_name ( ... )"
        table_match = re.search(
            rf"(CREATE TABLE IF NOT EXISTS\s+{table_re}\s*\()(.*?)(\);)",
            content,
            re.DOTALL
        )
        if table_match:
            table_prefix = table_match.group(1)
            table_body = table_match.group(2)
            table_suffix = table_match.group(3)
            
            # Check if there's a single-column UUID PRIMARY KEY
            pk_match = re.search(r"(\w+)\s+UUID\s+PRIMARY KEY", table_body)
            if pk_match:
                pk_col = pk_match.group(1)
                # Replace "UUID PRIMARY KEY" with "UUID" in the table body
                new_body = table_body.replace(
                    f"{pk_col} UUID PRIMARY KEY",
                    f"{pk_col} UUID"
                )
                # Add composite PK constraint before closing )
                # Find last comma or just before the final content
                pk_constraint = f"    CONSTRAINT pk_{table_name.replace('.', '_')}_{pk_col}_{time_col} PRIMARY KEY ({pk_col}, {time_col})"
                new_body = new_body.rstrip() + f",\n{pk_constraint}"
                
                full_table = table_prefix + table_body + table_suffix
                new_full_table = table_prefix + new_body + table_suffix
                content = content.replace(full_table, new_full_table, 1)
    
    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"Fixed: {basename}")
    else:
        print(f"OK: {basename}")

for filepath in sorted(glob.glob(os.path.join(SCHEMA_DIR, "*.sql"))):
    fix_file(filepath)

print("\nDone!")
