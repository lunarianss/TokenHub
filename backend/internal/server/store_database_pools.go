package server

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	gormlogger "gorm.io/gorm/logger"
)

// SQLite writes stay serialized. Small, read-only WAL pools prevent auditing
// and analytics from occupying every connection needed by authentication,
// routing, settings refreshes and readiness checks.
const sqliteCriticalReadConnections = 2

type namedDatabasePool struct {
	name string
	db   *gorm.DB
}

func (s *GormStore) databasePools() []namedDatabasePool {
	pools := make([]namedDatabasePool, 0, 3)
	seen := make(map[*sql.DB]bool)
	for _, pool := range []namedDatabasePool{{"primary", s.db}, {"read", s.readDB}, {"analytics", s.analyticsDB}} {
		if pool.db != nil {
			if db, err := pool.db.DB(); err == nil {
				if seen[db] {
					continue
				}
				seen[db] = true
			}
			pools = append(pools, pool)
		}
	}
	return pools
}

func (s *GormStore) criticalReadDatabase() *gorm.DB {
	if s.readDB != nil {
		return s.readDB
	}
	return s.db
}

func (s *GormStore) withAnalyticsReadSnapshot(ctx context.Context, read func(*gorm.DB) error) error {
	db := s.analyticsDB.WithContext(ctx)
	if s.dbDriver == "postgres" {
		return db.Transaction(read, &sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true})
	}
	if s.analyticsDB.Statement.ConnPool == s.db.Statement.ConnPool {
		// Private in-memory SQLite has only one connection. Holding it excludes
		// every writer and keeps the snapshot stable without a transaction.
		// A transaction tied to ctx would discard that sole connection on
		// cancellation and destroy the database. Connection still honors ctx
		// while waiting for the pool; queries retain their own request context.
		return db.Connection(func(conn *gorm.DB) error {
			return read(conn.Session(&gorm.Session{NewDB: true}))
		})
	}
	return db.Transaction(read)
}

// Pragmas the store enforces on every connection. They replace any caller
// supplied value for the same pragma, whichever DSN spelling carried it.
var sqliteEnforcedPragmas = []string{"busy_timeout", "foreign_keys", "journal_mode", "query_only"}

// Connection options understood by mattn/go-sqlite3, the cgo driver used by
// earlier releases, mapped to the pragma each one set. The pure Go driver
// only reads _pragma, so deployments that still carry the old spelling keep
// their behavior instead of having the option silently ignored.
var sqliteLegacyPragmaOptions = []struct {
	pragma  string
	options []string
}{
	{"auto_vacuum", []string{"_auto_vacuum", "_vacuum"}},
	{"busy_timeout", []string{"_busy_timeout", "_timeout"}},
	{"case_sensitive_like", []string{"_case_sensitive_like", "_cslike"}},
	{"defer_foreign_keys", []string{"_defer_foreign_keys", "_defer_fk"}},
	{"foreign_keys", []string{"_foreign_keys", "_fk"}},
	{"ignore_check_constraints", []string{"_ignore_check_constraints"}},
	{"journal_mode", []string{"_journal_mode", "_journal"}},
	{"locking_mode", []string{"_locking_mode", "_locking"}},
	{"query_only", []string{"_query_only"}},
	{"recursive_triggers", []string{"_recursive_triggers", "_rt"}},
	{"secure_delete", []string{"_secure_delete"}},
	{"synchronous", []string{"_synchronous", "_sync"}},
	{"writable_schema", []string{"_writable_schema"}},
	{"cache_size", []string{"_cache_size"}},
}

// Driver DSN options are applied whenever database/sql opens a connection,
// including replacements after cancellation or connection lifetime expiry.
// The driver runs each _pragma value in order as `PRAGMA <value>`, so the
// enforced pragmas are appended last and in mattn/go-sqlite3's former order:
// journal_mode must switch to WAL before query_only forbids the write.
func sqliteConnectionDSN(dsn string, readOnly bool) (string, error) {
	path, rawQuery, _ := strings.Cut(dsn, "?")
	query, err := url.ParseQuery(rawQuery)
	if err != nil {
		return "", fmt.Errorf("invalid SQLite connection options: %w", err)
	}
	pragmas := make([]string, 0, len(query["_pragma"])+len(sqliteEnforcedPragmas))
	for _, pragma := range query["_pragma"] {
		if !slices.Contains(sqliteEnforcedPragmas, sqlitePragmaName(pragma)) {
			pragmas = append(pragmas, pragma)
		}
	}
	for _, legacy := range sqliteLegacyPragmaOptions {
		// The first spelling is canonical; mattn/go-sqlite3 let an alias
		// override it, which is why aliases are read last here.
		value := ""
		for _, option := range legacy.options {
			if candidate := query.Get(option); candidate != "" {
				value = candidate
			}
			query.Del(option)
		}
		if value == "" || slices.Contains(sqliteEnforcedPragmas, legacy.pragma) {
			continue
		}
		if !sqlitePragmaValuePattern.MatchString(value) {
			return "", fmt.Errorf("invalid SQLite connection option for %s: %q", legacy.pragma, value)
		}
		pragmas = append(pragmas, legacy.pragma+"("+value+")")
	}
	busyTimeout, queryOnly := "5000", "0"
	if readOnly {
		busyTimeout, queryOnly = "1000", "1"
	}
	pragmas = append(pragmas, "busy_timeout("+busyTimeout+")", "foreign_keys(1)")
	if sqliteSupportsWAL(dsn) {
		pragmas = append(pragmas, "journal_mode(WAL)")
	}
	pragmas = append(pragmas, "query_only("+queryOnly+")")
	query["_pragma"] = pragmas
	// "sqlite" is the only accepted format and already the default. The
	// driver stops reading options after _time_format, which would drop the
	// _txlock below.
	query.Del("_time_format")
	if readOnly {
		if sqliteSupportsWAL(dsn) {
			// Shared-cache table locks bypass WAL snapshot isolation. Disk
			// readers need private caches to remain usable during writes.
			// SQLite honors this on file: URIs; the driver strips options
			// from bare paths, which already open with a private cache.
			query.Set("cache", "private")
		}
		// Read transactions must remain deferred even when the write DSN was
		// configured to acquire its writer lock immediately.
		query.Set("_txlock", "deferred")
	}
	return path + "?" + query.Encode(), nil
}

var sqlitePragmaValuePattern = regexp.MustCompile(`^-?[A-Za-z0-9_]+$`)

// sqlitePragmaName returns the lower-case pragma name of a _pragma value such
// as "busy_timeout(5000)" or "journal_mode = WAL".
func sqlitePragmaName(pragma string) string {
	name := strings.TrimSpace(pragma)
	if end := strings.IndexAny(name, "(= "); end >= 0 {
		name = name[:end]
	}
	return strings.ToLower(name)
}

func openCriticalReadDatabase(driver, dsn string) (*gorm.DB, error) {
	// Private/shared in-memory SQLite databases use different locking and
	// connection-lifetime semantics; preserve their existing primary pool.
	if driver != "sqlite" || !sqliteSupportsWAL(dsn) {
		return nil, nil
	}
	return openSQLiteReadDatabase(dsn, sqliteCriticalReadConnections)
}

func openSQLiteReadDatabase(dsn string, maxOpen int) (*gorm.DB, error) {
	dsn, err := sqliteConnectionDSN(dsn, true)
	if err != nil {
		return nil, err
	}
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{
		TranslateError: true,
		Logger:         gormlogger.Default.LogMode(gormlogger.Silent),
	})
	if err != nil {
		return nil, err
	}
	pool, err := db.DB()
	if err != nil {
		return nil, err
	}
	pool.SetMaxOpenConns(maxOpen)
	pool.SetMaxIdleConns(maxOpen)
	return db, nil
}

func openAnalyticsDatabase(driver string, dsn string, config Config, primary *gorm.DB) (*gorm.DB, error) {
	if driver == "sqlite" {
		// A private in-memory database belongs to its connection. Opening a
		// separate pool creates an empty database, so analytics must share the
		// existing primary pool without enabling query_only on its writer.
		if sqliteDatabaseIsConnectionLocal(dsn) {
			return primary, nil
		}
		return openSQLiteReadDatabase(dsn, 1)
	}
	if driver != "postgres" {
		return nil, fmt.Errorf("unsupported analytics database driver: %s", driver)
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
		TranslateError: true,
		Logger:         gormlogger.Default.LogMode(gormlogger.Silent),
	})
	if err != nil {
		return nil, err
	}
	pool, err := db.DB()
	if err != nil {
		return nil, err
	}
	poolSize := min(2, maxInt(1, defaultInt(config.DBMaxOpenConns, 25)))
	pool.SetMaxOpenConns(poolSize)
	pool.SetMaxIdleConns(1)
	pool.SetConnMaxLifetime(time.Duration(defaultInt(config.DBConnMaxLifetimeMinutes, 30)) * time.Minute)
	return db, nil
}

func sqliteSupportsWAL(dsn string) bool {
	path, options := sqliteDatabaseLocation(dsn)
	return path != "" && path != ":memory:" && options.Get("mode") != "memory" && options.Get("vfs") != "memdb"
}

func sqliteDatabaseIsConnectionLocal(dsn string) bool {
	path, options := sqliteDatabaseLocation(dsn)
	if path == "" || path == ":memory:" || options.Get("mode") == "memory" {
		return path == "" || options.Get("cache") != "shared"
	}
	// memdb shares named stores with a leading slash or backslash, or through
	// SQLite's shared cache. Other names belong to the opening connection.
	if options.Get("vfs") == "memdb" {
		sharedName := len(path) > 1 && (path[0] == '/' || path[0] == '\\')
		return !sharedName && options.Get("cache") != "shared"
	}
	return false
}

// Match SQLite URI decoding without changing case. The driver removes query
// options from non-file DSNs before opening SQLite, so mode/cache have no
// effect there; vfs is passed separately and still applies to bare DSNs.
func sqliteDatabaseLocation(dsn string) (string, url.Values) {
	path, rawQuery, _ := strings.Cut(dsn, "?")
	if !strings.HasPrefix(path, "file:") {
		options, _ := url.ParseQuery(rawQuery)
		options.Del("mode")
		options.Del("cache")
		return path, options
	}
	parsed, err := url.Parse(dsn)
	if err != nil {
		return path, nil
	}
	path = parsed.Path
	if parsed.Opaque != "" {
		path, err = url.PathUnescape(parsed.Opaque)
		if err != nil {
			return "", nil
		}
	}
	return path, parsed.Query()
}
