const SITE_URL = 'https://find.oiloil.org';
const FONT = '-apple-system, BlinkMacSystemFont, \'Segoe UI\', \'PingFang SC\', \'Microsoft YaHei\', Arial, sans-serif';

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]!);
}

export function licenseEmailHTML(key: string, replyable = false): string {
  const activationURL = escapeHTML(`oilfind://activate?key=${encodeURIComponent(key)}`);
  // Break only the visual line; copying the key keeps its original characters.
  const keyHTML = escapeHTML(key).replaceAll('-', '-<wbr>');
  const reply = replyable ? `
                <tr><td style="padding:24px 0 0;">
                  <p lang="zh-CN" style="margin:0;color:#606773;font-size:13px;line-height:21px;">有问题，或 14 天内需要退款，直接回复这封邮件。</p>
                  <p lang="en" style="margin:5px 0 0;color:#606773;font-size:13px;line-height:21px;">Questions, or a refund within 14 days? Just reply to this email.</p>
                </td></tr>` : '';

  return `<!DOCTYPE html>
<html lang="zh-CN" xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light">
    <meta name="supported-color-schemes" content="light">
    <title>你的 Oil Find Pro 授权码 / Your Oil Find Pro license key</title>
    <style>
      @media screen and (max-width:480px) {
        .mail-gutter { padding:20px 12px !important; }
        .mail-content { padding:28px 22px !important; }
        .mail-title { font-size:24px !important; }
      }
    </style>
  </head>
  <body style="margin:0;padding:0;width:100%;background-color:#eef1f5;color:#1d1d1f;font-family:${FONT};-webkit-text-size-adjust:100%;">
    <div style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">你的 Oil Find Pro 授权码。一个授权可以在 3 台 Mac 上使用。 / Your Oil Find Pro license key. One license works on up to 3 Macs.</div>
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#eef1f5" style="width:100%;background-color:#eef1f5;">
      <tr><td class="mail-gutter" align="center" style="padding:40px 16px;">
        <!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;max-width:600px;table-layout:fixed;">
          <tr><td class="mail-content" bgcolor="#ffffff" style="padding:40px;background-color:#ffffff;border-radius:20px;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;table-layout:fixed;">
              <tr><td align="center">
                <img src="${SITE_URL}/assets/icon.png" width="64" height="64" alt="Oil Find" style="display:block;width:64px;height:64px;border:0;margin:0 auto;">
                <h1 class="mail-title" lang="zh-CN" style="margin:20px 0 0;color:#1d1d1f;font-size:28px;line-height:36px;font-weight:600;letter-spacing:-0.5px;">你的 Oil Find Pro 授权码</h1>
                <p lang="en" style="margin:6px 0 0;color:#606773;font-size:16px;line-height:24px;">Your Oil Find Pro license key</p>
                <p lang="zh-CN" style="margin:20px 0 0;color:#606773;font-size:15px;line-height:24px;">感谢购买 Oil Find Pro。</p>
                <p lang="en" style="margin:2px 0 0;color:#606773;font-size:14px;line-height:22px;">Thanks for buying Oil Find Pro.</p>
              </td></tr>
              <tr><td style="padding:28px 0 0;">
                <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;table-layout:fixed;">
                  <tr><td bgcolor="#f5f7fa" style="padding:18px 20px;background-color:#f5f7fa;border:1px solid #e2e7ef;border-radius:12px;text-align:center;">
                    <p style="margin:0 0 9px;color:#606773;font-size:12px;line-height:18px;">授权码 / License key</p>
                    <code id="license-key" style="display:block;color:#1d1d1f;font-family:ui-monospace,'SF Mono',Menlo,Consolas,monospace;font-size:14px;line-height:24px;letter-spacing:0.2px;word-wrap:break-word;overflow-wrap:break-word;word-break:normal;">${keyHTML}</code>
                  </td></tr>
                </table>
              </td></tr>
              <tr><td align="center" style="padding:20px 0 0;">
                <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;">
                  <tr><td align="center" bgcolor="#2f7cf6" style="background-color:#2f7cf6;border-radius:12px;">
                    <a id="activate-link" href="${activationURL}" style="display:block;padding:14px 20px;border:1px solid #2f7cf6;border-radius:12px;color:#ffffff;font-size:16px;line-height:23px;font-weight:600;text-align:center;text-decoration:none;">
                      <span lang="zh-CN">在 Oil Find 中激活</span><br><span lang="en" style="font-size:13px;line-height:20px;font-weight:400;">Activate in Oil Find</span>
                    </a>
                  </td></tr>
                </table>
              </td></tr>
              <tr><td style="padding:24px 0 0;">
                <p lang="zh-CN" style="margin:0;color:#606773;font-size:14px;line-height:23px;">点上面的按钮，Oil Find 会直接激活 Pro。也可以把授权码粘贴到 Oil Find 设置里的 Pro 分区。</p>
                <p lang="en" style="margin:8px 0 0;color:#606773;font-size:13px;line-height:21px;">Click the button above and Oil Find activates Pro right away. You can also paste the key into the Pro section of Oil Find’s settings.</p>
              </td></tr>
              <tr><td style="padding:24px 0 0;">
                <p lang="zh-CN" style="margin:0;color:#606773;font-size:13px;line-height:21px;">一个授权可以在 3 台 Mac 上使用。</p>
                <p lang="en" style="margin:5px 0 0;color:#606773;font-size:13px;line-height:21px;">One license works on up to 3 Macs.</p>
              </td></tr>${reply}
            </table>
          </td></tr>
          <tr><td align="center" style="padding:22px 0 0;">
            <a href="${SITE_URL}/" style="color:#606773;font-size:12px;line-height:20px;text-decoration:none;">find.oiloil.org</a>
          </td></tr>
        </table>
        <!--[if mso]></td></tr></table><![endif]-->
      </td></tr>
    </table>
  </body>
</html>`;
}
