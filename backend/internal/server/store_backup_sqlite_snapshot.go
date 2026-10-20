package server

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strings"
)

// copySQLiteDatabase writes a consistent snapshot of the live database to
// path, or replaces the live database's content with the snapshot at path.
//
// The pure Go driver exposes no online backup API, so the snapshot uses
// VACUUM INTO and the restore rebuilds the schema and rows from the attached
// snapshot inside one transaction on the primary connection. Both run on the
// store's existing pools: read pools observe the restored content after the
// commit, as they did with sqlite3_backup, and nothing has to be reopened.
func (s *GormStore) copySQLiteDatabase(path string, restore bool) error {
	sqlDB, err := s.db.DB()
	if err != nil {
		return err
	}
	ctx := context.Background()
	conn, err := sqlDB.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if !restore {
		// VACUUM INTO requires a missing or empty destination file.
		_ = os.Remove(path)
		_, err := conn.ExecContext(ctx, "VACUUM INTO ?", path)
		return err
	}
	return restoreSQLiteSnapshot(ctx, conn, path)
}

const sqliteRestoreSchema = "tokenhub_restore_src"

type sqliteSchemaObject struct {
	kind string
	name string
	sql  string
}

func restoreSQLiteSnapshot(ctx context.Context, conn *sql.Conn, path string) (err error) {
	if _, err := conn.ExecContext(ctx, "ATTACH DATABASE ? AS "+sqliteRestoreSchema, path); err != nil {
		return err
	}
	defer func() {
		if _, detachErr := conn.ExecContext(ctx, "DETACH DATABASE "+sqliteRestoreSchema); detachErr != nil && err == nil {
			err = detachErr
		}
	}()
	// Rows are copied table by table, so references are only consistent once
	// every table is in place. foreign_keys cannot change inside a
	// transaction and is restored for the connection's later users.
	if _, err := conn.ExecContext(ctx, "PRAGMA foreign_keys = OFF"); err != nil {
		return err
	}
	defer func() {
		if _, pragmaErr := conn.ExecContext(ctx, "PRAGMA foreign_keys = ON"); pragmaErr != nil && err == nil {
			err = pragmaErr
		}
	}()
	source, err := sqliteSchemaObjects(ctx, conn, sqliteRestoreSchema)
	if err != nil {
		return fmt.Errorf("read backup schema: %w", err)
	}
	live, err := sqliteSchemaObjects(ctx, conn, "main")
	if err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(ctx, "ROLLBACK")
		}
	}()
	// Dropping a table also drops its indexes and triggers.
	for _, kind := range []string{"view", "trigger", "table"} {
		for _, object := range live {
			if object.kind != kind {
				continue
			}
			if _, err := conn.ExecContext(ctx, fmt.Sprintf("DROP %s IF EXISTS main.%s", strings.ToUpper(kind), quoteSQLiteIdentifier(object.name))); err != nil {
				return err
			}
		}
	}
	for _, object := range source {
		if object.kind != "table" {
			continue
		}
		if _, err := conn.ExecContext(ctx, object.sql); err != nil {
			return fmt.Errorf("recreate table %s: %w", object.name, err)
		}
		name := quoteSQLiteIdentifier(object.name)
		if _, err := conn.ExecContext(ctx, fmt.Sprintf("INSERT INTO main.%s SELECT * FROM %s.%s", name, sqliteRestoreSchema, name)); err != nil {
			return fmt.Errorf("restore table %s: %w", object.name, err)
		}
	}
	// AUTOINCREMENT counters live in sqlite_sequence, which SQLite creates
	// with the first AUTOINCREMENT table and which cannot be dropped.
	hasSequence, err := sqliteTableExists(ctx, conn, sqliteRestoreSchema, "sqlite_sequence")
	if err != nil {
		return err
	}
	if hasSequence {
		if _, err := conn.ExecContext(ctx, "DELETE FROM main.sqlite_sequence"); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, "INSERT INTO main.sqlite_sequence (name, seq) SELECT name, seq FROM "+sqliteRestoreSchema+".sqlite_sequence"); err != nil {
			return err
		}
	}
	for _, kind := range []string{"index", "view", "trigger"} {
		for _, object := range source {
			if object.kind != kind {
				continue
			}
			if _, err := conn.ExecContext(ctx, object.sql); err != nil {
				return fmt.Errorf("recreate %s %s: %w", kind, object.name, err)
			}
		}
	}
	var userVersion int64
	if err := conn.QueryRowContext(ctx, "PRAGMA "+sqliteRestoreSchema+".user_version").Scan(&userVersion); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, fmt.Sprintf("PRAGMA main.user_version = %d", userVersion)); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, "COMMIT"); err != nil {
		return err
	}
	committed = true
	return nil
}

// sqliteSchemaObjects lists user-defined schema objects in creation order.
// Internal sqlite_* objects and automatic indexes (NULL sql) are skipped;
// SQLite recreates them with their owning tables.
func sqliteSchemaObjects(ctx context.Context, conn *sql.Conn, schema string) ([]sqliteSchemaObject, error) {
	rows, err := conn.QueryContext(ctx, fmt.Sprintf(
		"SELECT type, name, sql FROM %s.sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite\\_%%' ESCAPE '\\' ORDER BY rowid",
		schema,
	))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var objects []sqliteSchemaObject
	for rows.Next() {
		var object sqliteSchemaObject
		if err := rows.Scan(&object.kind, &object.name, &object.sql); err != nil {
			return nil, err
		}
		objects = append(objects, object)
	}
	return objects, rows.Err()
}

func sqliteTableExists(ctx context.Context, conn *sql.Conn, schema string, table string) (bool, error) {
	var count int
	err := conn.QueryRowContext(ctx, fmt.Sprintf("SELECT COUNT(*) FROM %s.sqlite_master WHERE type = 'table' AND name = ?", schema), table).Scan(&count)
	return count > 0, err
}

func quoteSQLiteIdentifier(name string) string {
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}
