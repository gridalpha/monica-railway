<?php
/**
 * Create the application's database and a role scoped to it, using the root
 * URL Railway exposes on its managed MySQL service.
 *
 * Exit codes: 0 = the scoped role is usable, 3 = it is not (caller should fall
 * back to root for this boot), anything else = the database is unreachable.
 */

function env_or(string $name, ?string $default = null): ?string
{
    $v = getenv($name);
    return ($v === false || $v === '') ? $default : $v;
}

function out(string $msg): void
{
    fwrite(STDERR, "[railway] {$msg}\n");
}

$url = parse_url(env_or('MYSQL_URL'));
if (! $url || ! isset($url['host'])) {
    out('MYSQL_URL could not be parsed; skipping provisioning.');
    exit(1);
}

$rootUser = urldecode($url['user'] ?? 'root');
$rootPass = urldecode($url['pass'] ?? '');
$host     = $url['host'];
$port     = (int) ($url['port'] ?? 3306);

$database = env_or('DB_DATABASE', 'monica');
$appUser  = env_or('DB_USERNAME', 'monica');
$appPass  = env_or('DB_PASSWORD');

// Identifiers are interpolated into DDL, so accept only names that cannot
// change the shape of a statement. Passwords go through real_escape_string.
foreach (['DB_DATABASE' => $database, 'DB_USERNAME' => $appUser] as $key => $value) {
    if (! preg_match('/^[A-Za-z0-9_]{1,32}$/', (string) $value)) {
        out("FATAL: {$key} must match [A-Za-z0-9_]{1,32}; got '{$value}'.");
        exit(2);
    }
}
if ($appPass === null) {
    out('FATAL: DB_PASSWORD is unset.');
    exit(2);
}

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);

$root = null;
for ($attempt = 1; $attempt <= 30; $attempt++) {
    try {
        $root = new mysqli($host, $rootUser, $rootPass, '', $port);
        break;
    } catch (\mysqli_sql_exception $e) {
        out("waiting for MySQL ({$attempt}/30): " . $e->getMessage());
        sleep(2);
    }
}
if ($root === null) {
    out('FATAL: MySQL never became reachable.');
    exit(4);
}
out('MySQL server version: ' . $root->server_info);

$escapedPass = $root->real_escape_string($appPass);

$root->query("CREATE DATABASE IF NOT EXISTS `{$database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
$root->query("CREATE USER IF NOT EXISTS '{$appUser}'@'%' IDENTIFIED BY '{$escapedPass}'");
// Re-assert the password so a rotated DB_PASSWORD variable takes effect rather
// than silently leaving the app locked out of its own database.
$root->query("ALTER USER '{$appUser}'@'%' IDENTIFIED BY '{$escapedPass}'");
$root->query("GRANT ALL PRIVILEGES ON `{$database}`.* TO '{$appUser}'@'%'");
$root->query('FLUSH PRIVILEGES');

// Read the grants back rather than trusting the GRANT: a least-privilege setup
// that quietly did nothing looks identical to one that worked.
$grants = $root->query("SHOW GRANTS FOR '{$appUser}'@'%'");
while ($row = $grants->fetch_row()) {
    out('grant: ' . $row[0]);
}
$root->close();

// Prove the role can actually connect and use its database before the app
// stakes its boot on it.
try {
    $app = new mysqli($host, $appUser, $appPass, $database, $port);
    $app->query('SELECT 1');
    $app->close();
    out("scoped role '{$appUser}' verified against database '{$database}'.");
    exit(0);
} catch (\mysqli_sql_exception $e) {
    out("scoped role unusable: " . $e->getMessage());
    file_put_contents('/tmp/railway-db-fallback.env', implode("\n", [
        'DB_HOST=' . $host,
        'DB_PORT=' . $port,
        'DB_DATABASE=' . $database,
        'DB_USERNAME=' . $rootUser,
        'DB_PASSWORD=' . $rootPass,
        '',
    ]));
    exit(3);
}
