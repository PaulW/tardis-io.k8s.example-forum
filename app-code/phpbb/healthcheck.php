<?php
/**
 * The readiness check for phpBB.
 *
 * Served by nginx at /readyz. It returns 200 when the forum can reach
 * its database, and 503 otherwise. It is used as the Kubernetes
 * readinessProbe, so a pod with a broken database is pulled out of the
 * Service endpoints without being restarted.
 *
 * The livenessProbe uses /healthz instead, which nginx answers
 * directly. That is deliberate: a database outage must not cause a
 * restart loop.
 */

header('Content-Type: text/plain');

$host = getenv('PHPBB_DB_HOST') ?: '127.0.0.1';
$port = (int) (getenv('PHPBB_DB_PORT') ?: 3306);
$name = getenv('PHPBB_DB_NAME') ?: 'phpbb';
$user = getenv('PHPBB_DB_USER') ?: 'phpbb';
$pass = getenv('PHPBB_DB_PASS') ?: '';

mysqli_report(MYSQLI_REPORT_OFF);

$link = @new mysqli($host, $user, $pass, $name, $port);

if ($link->connect_errno) {
    http_response_code(503);
    echo "NOT READY: the database is unreachable\n";
    exit(0);
}

// The forum also needs its tables. A reachable but empty database
// means the install has not run yet, and the forum would answer with
// an error page rather than with a board.
//
// The table prefix is used to build the query, so the expected table
// name is derived from it. A prepared statement avoids any quoting
// issue with the database name.
$prefix = getenv('PHPBB_TABLE_PREFIX') ?: 'phpbb_';
$pattern = $prefix . '%';

$stmt = $link->prepare(
    'SELECT COUNT(*) FROM information_schema.tables '
    . 'WHERE table_schema = ? AND table_name LIKE ?'
);

// bind_param takes its arguments by reference, so both have to be
// variables. Passing an expression is a fatal error.
$stmt->bind_param('ss', $name, $pattern);
$stmt->execute();
$stmt->bind_result($tables);
$stmt->fetch();
$stmt->close();

if (!$tables) {
    http_response_code(503);
    echo "NOT READY: the database has no phpBB tables\n";
    exit(0);
}

http_response_code(200);
echo "READY: {$tables} tables\n";
