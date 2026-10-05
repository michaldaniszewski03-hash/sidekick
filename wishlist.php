<?php
/*
 * Sidekick's wishlist (the form on index.html, #wishlist).
 *
 * Upload next to index.html. It needs only PHP: no database. The list is a
 * CSV file in a private folder, `sidekick-wishlist`, made next to the
 * website's folder (outside it, so nobody can open it from the web), or,
 * where that isn't allowed, inside it behind a "deny all" .htaccess.
 * Open list.csv with FileZilla (or any spreadsheet) to see who signed up.
 *
 * Signing up puts the address on the list and emails "Got your email!
 * We'll remind you when Sidekick comes out." (the owner's words), with a
 * link that removes it again.
 *
 *   POST  wishlist.php            email, devices, t (page time), website (a trap)
 *   GET   wishlist.php?remove=…   removes, then back to the page
 *
 * On localhost (php -S localhost:8000) emails aren't sent: they're saved
 * in sidekick-wishlist/outbox, so the whole flow can be tried offline.
 */

// The address the emails come from: a mailbox you made for
// getsidekick.app in OVHcloud (Web Cloud → Emails).
const FROM = 'info@getsidekick.app';
const FROM_NAME = 'Sidekick';
const SITE = 'https://getsidekick.app';
// Also tell FROM about each new sign-up ("New on the wishlist: …").
const NOTIFY_OWNER = true;

const MAX_PER_HOUR = 5;        // sign-ups per visitor (by a hash of their IP)

ini_set('display_errors', '0');
header('X-Robots-Tag: noindex, nofollow');
header('Cache-Control: no-store');

$local = in_array($_SERVER['SERVER_NAME'] ?? '', ['localhost', '127.0.0.1'], true);
$site = $local ? 'http://' . $_SERVER['HTTP_HOST'] : SITE;

function data_dir(): string {
    $outside = dirname(__DIR__) . '/sidekick-wishlist';
    if ((is_dir($outside) || @mkdir($outside, 0700)) && is_writable($outside)) {
        return $outside;
    }
    $inside = __DIR__ . '/sidekick-wishlist';
    if (!is_dir($inside) && !@mkdir($inside, 0700)) {
        throw new RuntimeException('No folder for the wishlist');
    }
    if (!file_exists("$inside/.htaccess")) {
        file_put_contents("$inside/.htaccess",
            "<IfModule mod_authz_core.c>\n  Require all denied\n</IfModule>\n"
            . "<IfModule !mod_authz_core.c>\n  Deny from all\n</IfModule>\n");
    }
    return $inside;
}

function reply(int $code, array $body): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($body);
    exit;
}

function back(string $state): void {
    global $site;
    header('Location: ' . $site . '/?wishlist=' . $state . '#wishlist', true, 303);
    exit;
}

const COLUMNS = ['email', 'devices', 'joined', 'token', 'emailed'];

/** Runs [$change] on the list (email => row) under a lock, and saves it. */
function with_list(callable $change) {
    $dir = data_dir();
    $lock = fopen("$dir/.lock", 'c');
    flock($lock, LOCK_EX);
    try {
        $rows = [];
        $file = "$dir/list.csv";
        if (is_readable($file) && ($h = fopen($file, 'r'))) {
            fgetcsv($h, 0, ',', '"', '');  // the header
            while (($r = fgetcsv($h, 0, ',', '"', '')) !== false) {
                if (count($r) === count(COLUMNS)) {
                    $row = array_combine(COLUMNS, $r);
                    $rows[$row['email']] = $row;
                }
            }
            fclose($h);
        }
        $result = $change($rows);
        $tmp = "$file.tmp";
        $h = fopen($tmp, 'w');
        fputcsv($h, COLUMNS, ',', '"', '');
        foreach ($rows as $row) {
            fputcsv($h, array_values($row), ',', '"', '');
        }
        fclose($h);
        rename($tmp, $file);
        @chmod($file, 0600);
        return $result;
    } finally {
        flock($lock, LOCK_UN);
        fclose($lock);
    }
}

/** At most MAX_PER_HOUR tries an hour from one visitor. Only a salted hash
 *  of the IP is kept, and only for the hour. */
function allowed(): bool {
    $dir = data_dir();
    $saltFile = "$dir/.salt";
    if (!file_exists($saltFile)) {
        file_put_contents($saltFile, bin2hex(random_bytes(16)));
    }
    $key = hash('sha256', file_get_contents($saltFile) . ($_SERVER['REMOTE_ADDR'] ?? ''));
    $file = "$dir/limits.json";
    $h = fopen($file, 'c+');
    flock($h, LOCK_EX);
    $limits = json_decode(stream_get_contents($h) ?: '{}', true) ?: [];
    $now = time();
    foreach ($limits as $k => $times) {
        $limits[$k] = array_values(array_filter($times, fn($t) => $now - $t < 3600));
        if (!$limits[$k]) unset($limits[$k]);
    }
    $ok = count($limits[$key] ?? []) < MAX_PER_HOUR;
    if ($ok) $limits[$key][] = $now;
    ftruncate($h, 0);
    rewind($h);
    fwrite($h, json_encode($limits));
    flock($h, LOCK_UN);
    fclose($h);
    return $ok;
}

function send_welcome(string $email, string $token): bool {
    global $local, $site;
    $remove = "$site/wishlist.php?remove=$token";
    $subject = 'Got your email!';
    $body = "Hi!\r\n\r\n"
        . "Got your email! We'll remind you when Sidekick comes out.\r\n\r\n"
        . "Sidekick makes your phone and computer work as one: send files both ways, share\r\n"
        . "your clipboard, use your phone as a touchpad, mirror its screen and more, on\r\n"
        . "Windows, Mac, Android and iPhone. Free, with no account.\r\n\r\n"
        . "That's the only email you'll get until then. We never share your address.\r\n\r\n"
        . "Changed your mind? Remove your email from the list:\r\n"
        . "$remove\r\n\r\n"
        . "Sidekick\r\ngetsidekick.app\r\n";
    if ($local) {
        $out = data_dir() . '/outbox';
        @mkdir($out, 0700);
        return file_put_contents("$out/" . date('Ymd-His') . "-$email.txt", "To: $email\r\nSubject: $subject\r\n\r\n$body") !== false;
    }
    $headers = implode("\r\n", [
        'From: ' . FROM_NAME . ' <' . FROM . '>',
        'Reply-To: ' . FROM,
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=UTF-8',
        'Content-Transfer-Encoding: 8bit',
        'List-Unsubscribe: <' . $remove . '>',
    ]);
    return mail($email, $subject, $body, $headers, '-f' . FROM);
}

/** A short note to FROM about a new sign-up (never shown to the visitor). */
function notify_owner(string $email, array $devices, bool $sent): void {
    global $local;
    $count = with_list(fn(array &$rows) => count($rows));
    $subject = "New on the wishlist: $email";
    $body = "$email joined the Sidekick wishlist.\r\n"
        . 'Devices: ' . ($devices ? implode(', ', $devices) : 'not picked') . "\r\n"
        . "People on the list now: $count\r\n"
        . ($sent ? '' : "\r\nThe \"Got your email!\" email couldn't be sent to them.\r\n")
        . "\r\nThe whole list: sidekick-wishlist/list.csv on the hosting (FileZilla).\r\n";
    if ($local) {
        $out = data_dir() . '/outbox';
        @mkdir($out, 0700);
        file_put_contents("$out/" . date('Ymd-His') . '-owner.txt', "To: " . FROM . "\r\nSubject: $subject\r\n\r\n$body");
        return;
    }
    $headers = implode("\r\n", [
        'From: ' . FROM_NAME . ' wishlist <' . FROM . '>',
        'Reply-To: ' . $email,
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=UTF-8',
        'Content-Transfer-Encoding: 8bit',
    ]);
    @mail(FROM, $subject, $body, $headers, '-f' . FROM);
}

function by_token(array &$rows, string $token): ?string {
    if (!preg_match('/^[a-f0-9]{32}$/', $token)) return null;
    foreach ($rows as $k => $row) {
        if (hash_equals($row['token'], $token)) return $k;
    }
    return null;
}

try {
    if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['remove'])) {
        $token = (string) $_GET['remove'];
        with_list(function (array &$rows) use ($token) {
            $k = by_token($rows, $token);
            if ($k !== null) unset($rows[$k]);
        });
        back('removed');
    }

    if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
        header('Location: /#wishlist', true, 303);
        exit;
    }

    // Bots fill in the hidden "website" field, or post the instant the page
    // loads: they're told it worked, and nothing happens.
    $loaded = (int) ($_POST['t'] ?? 0) / 1000;
    if (($_POST['website'] ?? '') !== '' || $loaded <= 0 || time() - $loaded < 2) {
        reply(200, ['ok' => true, 'status' => 'joined']);
    }

    $email = strtolower(trim((string) ($_POST['email'] ?? '')));
    if (strlen($email) > 254 || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
        reply(400, ['ok' => false, 'error' => 'email']);
    }
    $devices = array_values(array_intersect(
        explode(',', (string) ($_POST['devices'] ?? '')),
        ['Windows', 'Mac', 'Android', 'iPhone']
    ));

    if (!allowed()) {
        reply(429, ['ok' => false, 'error' => 'busy']);
    }

    [$status, $token] = with_list(function (array &$rows) use ($email, $devices) {
        if (isset($rows[$email])) {
            if ($devices) $rows[$email]['devices'] = implode(' ', $devices);
            return ['already', null];
        }
        $token = bin2hex(random_bytes(16));
        $rows[$email] = ['email' => $email, 'devices' => implode(' ', $devices), 'joined' => gmdate('Y-m-d H:i:s'),
                         'token' => $token, 'emailed' => ''];
        return ['joined', $token];
    });

    // On the list either way; the email says so. If it can't be sent now,
    // the address stays on the list (list.csv shows "emailed" empty).
    $sent = false;
    if ($token !== null) {
        $sent = send_welcome($email, $token);
        if ($sent) {
            with_list(function (array &$rows) use ($email) {
                if (isset($rows[$email])) $rows[$email]['emailed'] = gmdate('Y-m-d H:i:s');
            });
        } else {
            error_log("Sidekick wishlist: couldn't email $email");
        }
        if (NOTIFY_OWNER) notify_owner($email, $devices, $sent);
    }
    reply(200, ['ok' => true, 'status' => $status, 'emailed' => $sent]);
} catch (Throwable $e) {
    error_log('Sidekick wishlist: ' . $e->getMessage());
    reply(500, ['ok' => false, 'error' => 'server']);
}
