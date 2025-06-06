#!/bin/bash
# Restricting mails from sending when there is no sufficient storage in the senders mailbox

echo "Setting up checking storage quota script"

echo "Creating a directory..."

mkdir -p /usr/local/lib/roundcubemail/plugins/sendquota

echo "Writing script into the file"

cat > /usr/local/lib/roundcubemail/plugins/sendquota/sendquota.php <<'EOF'
<?php
class sendquota extends rcube_plugin {
    public $task = 'mail';

    function init() {
        $this->include_script('sendquota.js');
        $this->register_action('plugin.quota_check', [$this, 'quota_check']);
    }

    function quota_check() {
    $rcmail = rcmail::get_instance();
    //$rcmail->storage_init();
    //var_dump("User quota".$rcmail->storage->get_quota("surya"));

    // Force plugin to run in AJAX mode
    if (!$rcmail->output->ajax_call) {
        $rcmail->output->ajax_call = true;
    }

    $user = $rcmail->user->get_username();
    list($local, $domain) = explode('@', $user);

    $file = "/home/user-data/mail/mailboxes/$domain/$local/maildirsize";

    $quota = 0;
    $used = 0;
    if (file_exists($file)) {
        $lines = file($file);
        $quota = intval(explode('S', $lines[0])[0]);
        foreach (array_slice($lines, 1) as $line) {
            list($size, ) = explode(' ', $line);
            $used += intval($size);
        }
    }

    // Clean output buffering and explicitly return JSON
    header('Content-Type: application/json');
    echo json_encode([
        'quota' => $quota,
        'used' => $used,
        'remaining' => max(0, $quota - $used)
    ]);
    exit;
}

}
?>

EOF

cat > /usr/local/lib/roundcubemail/plugins/sendquota/sendquota.js <<EOF

window.rcmail && rcmail.addEventListener('init', function() {
  const target = document.querySelector("#attachment-list");
  if (!target) {
    console.warn("#attachment-list not found");
    return;
  }

  const observer = new MutationObserver(async function () {
    const attachmentList = document.querySelectorAll("#attachment-list li");
    let totalSize = 0;

    for (const item of attachmentList) {
      const sizeText = item.querySelector('.attachment-size')?.textContent || "";
      const match = sizeText.match(/([\d.]+)\s*([KMGT]?B)/i);
      if (!match) continue;

      let size = parseFloat(match[1]);
      const unit = match[2].toUpperCase();

      const unitMap = {
        B: 1,
        KB: 1024,
        MB: 1024 * 1024,
        GB: 1024 * 1024 * 1024,
      };
      if (unit in unitMap) {
        totalSize += size * unitMap[unit];
      }
    }

    try {
      const resp = await fetch('/mail/?_task=mail&_action=plugin.quota_check', {
        headers: {
          'X-Requested-With': 'XMLHttpRequest',
          'Accept': 'application/json'
        }
      });

      const contentType = resp.headers.get("content-type") || "";
      if (!contentType.includes("application/json")) {
        throw new Error("Expected JSON, got something else");
      }

      const data = await resp.json();      
      const remaining = data.remaining || 0;

      if (totalSize > remaining) {
        alert("Your attachments exceed your remaining mailbox quota.");        

        const last = document.querySelector("#attachment-list li:last-child a.delete");
        last?.click();
      }
    } catch (err) {
      console.error("Quota check failed:", err);
    }
  });

  // Observe attachment list mutations
  observer.observe(target, { childList: true, subtree: false });
});

EOF

echo "Changing file permissions"

chown www-data:www-data /opt/mail-policies/sender_quota_policy.py
chmod 755 /opt/mail-policies/sender_quota_policy.py
chmod +x /opt/mail-policies/sender_quota_policy.py
