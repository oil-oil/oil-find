#!/bin/bash
# The user runs this locally. Secrets are never passed as command-line arguments.
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
command -v node >/dev/null || { echo '请先安装 Node.js 22，再运行本脚本。' >&2; exit 1; }
command -v vercel >/dev/null || { echo '请先安装 Vercel CLI，并在 site/ 完成 vercel login 和 vercel link。' >&2; exit 1; }
node --input-type=module <<'NODE'
import { spawnSync } from 'node:child_process';
import { chmodSync, closeSync, lstatSync, mkdtempSync, openSync, readFileSync, readSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const file = '.env.production.local';
let terminal;
let echoDisabled = false;
for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
  process.once(signal, () => {
    if (terminal !== undefined && echoDisabled) spawnSync('stty', ['echo'], { stdio: [terminal, 'ignore', 'ignore'] });
    process.exit(code);
  });
}
function message(text) { process.stdout.write(`${text}\n`); }
function prompt(text) {
  process.stdout.write(text);
  const result = spawnSync('stty', ['-echo'], { stdio: [terminal, 'ignore', 'ignore'] });
  if (result.status !== 0) throw new Error('无法关闭终端回显；请在 macOS 本机终端运行。');
  echoDisabled = true;
  try {
    const bytes = [], byte = Buffer.alloc(1);
    while (readSync(terminal, byte, 0, 1, null)) {
      if (byte[0] === 10 || byte[0] === 13) { message(''); return Buffer.from(bytes).toString('utf8').trim(); }
      bytes.push(byte[0]);
      if (bytes.length > 8192) throw new Error('输入过长；请只按回车，然后让脚本读取剪贴板。');
    }
    throw new Error('终端输入已结束；请重新运行脚本。');
  } finally {
    spawnSync('stty', ['echo'], { stdio: [terminal, 'ignore', 'ignore'] });
    echoDisabled = false;
  }
}
function clipboard(name, pattern) {
  for (;;) {
    prompt(`复制 ${name} 后按回车（不要粘贴到终端）：`);
    const copied = spawnSync('pbpaste', [], { encoding: 'utf8', maxBuffer: 16384, stdio: ['ignore', 'pipe', 'ignore'] });
    const value = copied.stdout?.trim() ?? '';
    if (copied.status === 0 && pattern.test(value)) {
      spawnSync('pbcopy', [], { input: '', stdio: ['pipe', 'ignore', 'ignore'] });
      return value;
    }
    message(`${name} 前缀或格式不正确；请重新复制对应正式密钥。未保存该输入。`);
  }
}
function save(values) {
  const info = lstatSync(file);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('环境文件必须是普通文件；请检查 .env.production.local。');
  chmodSync(file, 0o600);
  let contents = readFileSync(file, 'utf8');
  for (const [name, value] of Object.entries(values)) {
    contents = contents.split('\n').filter(line => !line.startsWith(`${name}=`)).join('\n').replace(/\n*$/, '\n');
    contents += `${name}=${value}\n`;
  }
  const directory = mkdtempSync('.secrets-');
  try {
    const temporary = join(directory, 'environment');
    writeFileSync(temporary, contents, { flag: 'wx', mode: 0o600 });
    renameSync(temporary, file);
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
try {
  const info = lstatSync(file);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('请先运行正式密钥生成脚本，检查环境文件和备份。');
  terminal = openSync('/dev/tty', 'r+');
  message('此脚本会在本机保存密钥，并同步到已关联的 Vercel 项目的 production 环境；不会部署。');
  message('请先确认 site/ 关联的 Vercel 项目正确。所有输入均关闭终端回显，成功读取后清空剪贴板。');
  message('Stripe 正式后台 → 开发者 → API 密钥 → 创建受限密钥：');
  message('https://dashboard.stripe.com/acct_1ULhOSALDA53GHXZ/apikeys');
  message('最小权限：Checkout Sessions 写（含读）、Customers 写（含读）、Payment Intents 读、Charges 读。其他权限保持无；无需 Webhook Endpoints 权限。');
  const stripe = clipboard('Stripe API 密钥', /^(sk_live_|rk_live_)[A-Za-z0-9]+$/);
  save({ STRIPE_SECRET_KEY: stripe });
  message('Webhook：打开下方已重建端点，由你本人复制签名密钥；请勿把密钥发给 AI。');
  message('https://dashboard.stripe.com/acct_1ULhOSALDA53GHXZ/workbench/webhooks/we_1UOVdtALDA53GHXZU0tWHHpR');
  const webhook = clipboard('webhook 签名密钥', /^whsec_[A-Za-z0-9]+$/);
  save({ STRIPE_WEBHOOK_SECRET: webhook });
  message('Resend：https://resend.com/api-keys → Create API key；权限只选 Sending access，域名限定 oiloil.org。');
  const resend = clipboard('Resend API key', /^re_[A-Za-z0-9_\-]+$/);
  save({ RESEND_API_KEY: resend });
  for (;;) {
    const replyTo = prompt('买家回复邮箱 MAIL_REPLY_TO（输入邮箱，回车跳过并保留已有设置）：');
    if (!replyTo) break;
    if (/^[^\s@=]+@[^\s@=]+\.[^\s@=]+$/.test(replyTo)) { save({ MAIL_REPLY_TO: replyTo }); break; }
    message('邮箱格式不正确；请重新输入，或按回车跳过。');
  }
  message('本机录入完成，开始同步 production 环境变量。');
  const push = spawnSync('bash', ['scripts/push-env.sh', '--no-deploy'], { stdio: 'inherit' });
  if (push.status !== 0) throw new Error('同步未完成；本机密钥已保存。修复 Vercel 登录或项目关联后运行 bash scripts/push-env.sh --no-deploy。');
} catch (error) {
  // Never print system exceptions, clipboard contents, or child-process output.
  const safe = error instanceof Error && /^(无法关闭|输入过长|终端输入|环境文件必须|请先运行|同步未完成)/.test(error.message);
  message(safe ? error.message : '录入未完成。请检查 macOS 终端、文件权限和剪贴板，再重新运行；已保存的密钥仍保留在本机。');
  process.exitCode = 1;
} finally {
  if (terminal !== undefined) {
    if (echoDisabled) spawnSync('stty', ['echo'], { stdio: [terminal, 'ignore', 'ignore'] });
    closeSync(terminal);
  }
}
NODE
