<?php
/**
 * Check for the compound index on phpbb_sessions.
 *
 * The index is on (session_user_id, session_time). It is the most
 * important index on the board. Without it, the query that counts
 * the guest sessions does a full table scan of the whole session
 * table on every page load, for every user.
 *
 * In March 2026 that query scanned 345,991 rows on the old forum.
 * The database sat at 45 threads and load 35, and it fell to 1 to 3
 * threads once the index was added.
 *
 * The loss of the index is silent. The forum does not break, it just
 * gets slow, so it is checked by the verify suite.
 *
 * The index is looked up by its columns, not by its name. phpBB
 * 3.3.19 calls it session_user_time, and the March fix called it
 * idx_session_user_time, and the name is not what matters.
 *
 * Usage: php check-session-index.php
 * Output: "yes", "no", or "noconnection"
 */

$host = getenv('PHPBB_DB_HOST') ?: '127.0.0.1';
$port = (int) (getenv('PHPBB_DB_PORT') ?: 3306);
$name = getenv('PHPBB_DB_NAME') ?: 'phpbb';
$user = getenv('PHPBB_DB_USER') ?: 'phpbb';
$pass = getenv('PHPBB_DB_PASS') ?: '';

$mysqli = @new mysqli($host, $user, $pass, $name, $port);
if ($mysqli->connect_errno) {
    echo "noconnection\n";
    exit(0);
}

$table = ($mysqli->real_escape_string('phpbb_sessions'));
$sql = "SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = '{$table}'
        ORDER BY INDEX_NAME, SEQ_IN_INDEX";

$result = $mysqli->query($sql);
if (!$result) {
    echo "no\n";
    exit(0);
}

// Group the columns of each index, in order.
$indexes = array();
while ($row = $result->fetch_assoc()) {
    $index = $row['INDEX_NAME'];
    if (!isset($indexes[$index])) {
        $indexes[$index] = array();
    }
    $indexes[$index][] = $row['COLUMN_NAME'];
}

// The index must have session_user_id first and session_time second.
$wanted = array('session_user_id', 'session_time');
foreach ($indexes as $index => $columns) {
    if (count($columns) < 2) {
        continue;
    }
    if ($columns[0] === $wanted[0] && $columns[1] === $wanted[1]) {
        echo "yes\n";
        exit(0);
    }
}

echo "no\n";
