<?php
/*
 * Checks that the hosting can run the wishlist (wishlist.php): PHP, a
 * private folder for the list, and sending email. Upload it next to
 * wishlist.php, open https://getsidekick.app/wishlist-check.php once, then
 * delete it. It only ever emails the wishlist's own address (FROM).
 */
ini_set('display_errors', '0');
header('X-Robots-Tag: noindex, nofollow');
header('Cache-Control: no-store');
header('Content-Type: text/html; charset=utf-8');

$from = 'info@getsidekick.app';
$src = @file_get_contents(__DIR__ . '/wishlist.php');
if ($src && preg_match("/const FROM = '([^']+)'/", $src, $m)) $from = $m[1];

$checks = [];
$checks[] = ['PHP ' . PHP_VERSION, version_compare(PHP_VERSION, '7.4', '>='), 'wishlist.php needs PHP 7.4 or newer (OVHcloud: Web Cloud → Hosting → General information → PHP version).'];
$checks[] = ['wishlist.php is uploaded', (bool) $src, 'Upload wishlist.php to the same folder as this file (www).'];

$outside = dirname(__DIR__) . '/sidekick-wishlist';
$inside = __DIR__ . '/sidekick-wishlist';
$folder = null;
foreach ([$outside, $inside] as $dir) {
    if ((is_dir($dir) || @mkdir($dir, 0700)) && is_writable($dir)) { $folder = $dir; break; }
}
$writes = $folder && @file_put_contents("$folder/.check", 'ok') !== false;
if ($writes) @unlink("$folder/.check");
$checks[] = [
    $folder === $outside ? 'A private folder for the list, next to www (not reachable from the web)'
        : ($folder ? 'A folder for the list inside www (protected by .htaccess)' : 'A folder for the list'),
    $writes,
    "The hosting doesn't let PHP save files. Check the folder permissions in FileZilla (www should be 705 or 755).",
];
$checks[] = ['PHP can send email (mail)', function_exists('mail'), 'This plan has no email sending for PHP; tell Claude, there are other ways.'];

$sent = null;
if (isset($_POST['send']) && function_exists('mail')) {
    $headers = "From: Sidekick <$from>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8";
    $sent = mail($from, 'Sidekick wishlist: test email', "It works! The wishlist on getsidekick.app can send email.\r\n\r\nSent at " . gmdate('Y-m-d H:i:s') . " UTC by wishlist-check.php. Delete that file from the hosting now.\r\n", $headers, "-f$from");
}
$all = !in_array(false, array_column($checks, 1), true);
?><!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Wishlist check</title>
<style>
body{font:16px/1.5 system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 16px;background:#fbf8ff;color:#1c1b20}
li{margin:10px 0;list-style:none}.ok{color:#146c2e}.bad{color:#b3261e}small{display:block;color:#5d5a66}
button{font:inherit;padding:10px 18px;border-radius:12px;border:0;background:#6750a4;color:#fff;cursor:pointer}
.box{padding:16px;border-radius:16px;background:#ece6f6;margin-top:20px}
</style></head><body>
<h1>Sidekick wishlist check</h1>
<ul><?php foreach ($checks as [$what, $ok, $fix]): ?>
<li class="<?= $ok ? 'ok' : 'bad' ?>"><?= $ok ? '✔' : '✘' ?> <?= htmlspecialchars($what) ?><?php if (!$ok): ?><small><?= htmlspecialchars($fix) ?></small><?php endif ?></li>
<?php endforeach ?></ul>
<div class="box">
<?php if ($sent === true): ?>
  <b class="ok">Test email sent to <?= htmlspecialchars($from) ?>.</b>
  <p>It should arrive within a few minutes (look in spam too). If it does, the wishlist works: delete this file (wishlist-check.php) from the hosting.</p>
<?php elseif ($sent === false): ?>
  <b class="bad">The hosting refused to send the email.</b>
  <p>Check that the mailbox <?= htmlspecialchars($from) ?> exists in OVHcloud (Web Cloud → Emails), then try again.</p>
<?php else: ?>
  <p>Send a test email to <b><?= htmlspecialchars($from) ?></b>:</p>
<?php endif ?>
  <form method="post"><button name="send" value="1">Send a test email</button></form>
</div>
<p><?= $all ? 'Everything the wishlist needs is here.' : 'Fix the ✘ items above, then reload this page.' ?></p>
</body></html>
