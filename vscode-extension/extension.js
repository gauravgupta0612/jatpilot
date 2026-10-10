// JarPilot for IBM i — VS Code extension (jarpilot) v1.0.0
// Runs ssh/scp in an integrated terminal so password / host-key prompts just work.
const vscode = require('vscode');
const path = require('path');
const crypto = require('crypto');
const fs = require('fs');

const cfg = () => vscode.workspace.getConfiguration('jarpilot');
const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;          // quote for remote sh
const lq = (s) => (process.platform === 'win32' ? `"${s}"` : shq(s)); // quote for local shell

let terminal;
function term() {
  if (!terminal || terminal.exitStatus !== undefined) terminal = vscode.window.createTerminal('JarPilot');
  terminal.show();
  return terminal;
}

async function ensureConfig() {
  const c = cfg();
  if (c.get('host') && c.get('user') && c.get('target')) return true;
  const pick = await vscode.window.showWarningMessage('JarPilot: IBM i connection not configured.', 'Configure now');
  if (pick) await configure();
  return !!(cfg().get('host') && cfg().get('user') && cfg().get('target'));
}

async function configure() {
  const c = cfg();
  const ask = async (key, prompt) => {
    const v = await vscode.window.showInputBox({ prompt, value: String(c.get(key) ?? ''), ignoreFocusOut: true });
    if (v !== undefined) await c.update(key, key === 'port' ? Number(v) || 22 : v, vscode.ConfigurationTarget.Global);
  };
  await ask('host', 'IBM i host name / IP');
  await ask('user', 'IBM i user profile (SSH)');
  await ask('port', 'SSH port');
  await ask('target', 'Target IFS directory for JARs');
  vscode.window.showInformationMessage('JarPilot configuration saved.');
}

function sshParts() {
  const c = cfg();
  const key = c.get('keyFile') ? ` -i ${lq(c.get('keyFile'))}` : '';
  return {
    ssh: `ssh -p ${c.get('port')}${key}`,
    scp: `scp -P ${c.get('port')}${key}`,
    remote: `${c.get('user')}@${c.get('host')}`,
    staging: c.get('staging') || '/tmp/jarpilot',
  };
}

function remoteCmd(action, extra) {
  const c = cfg();
  const { staging } = sshParts();
  let cmd = `/QOpenSys/usr/bin/sh ${shq(staging + '/jarpilot.sh')} ${action} --target ${shq(c.get('target'))}`;
  if (action === 'install') cmd += ` --public-aut ${shq(c.get('publicAut'))} --keep ${c.get('keepBackups')}`;
  if (c.get('owner')) cmd += ` --owner ${shq(c.get('owner'))}`;
  if (c.get('restartCommand') && action !== 'status') cmd += ` --restart ${shq(c.get('restartCommand'))}`;
  return cmd + (extra || '');
}

function run(ctx, steps) {
  const { ssh, scp, remote, staging } = sshParts();
  const script = path.join(ctx.extensionPath, 'resources', 'jarpilot.sh');
  const lines = [
    `${ssh} ${remote} "mkdir -p ${staging}"`,
    `${scp} ${lq(script)} ${remote}:${staging}/jarpilot.sh`,
    ...steps(ssh, scp, remote, staging),
  ];
  const sep = process.platform === 'win32' ? '; ' : ' && ';
  term().sendText(lines.join(sep));
}

async function installFromPc(ctx, uri) {
  if (!(await ensureConfig())) return;
  if (!uri) {
    const pick = await vscode.window.showOpenDialog({ filters: { 'Java archive': ['jar'] }, canSelectMany: false });
    if (!pick) return;
    uri = pick[0];
  }
  const local = uri.fsPath;
  const name = await vscode.window.showInputBox({ prompt: 'Installed JAR name on IBM i', value: path.basename(local), ignoreFocusOut: true });
  if (!name) return;
  const sha = crypto.createHash('sha256').update(fs.readFileSync(local)).digest('hex');
  const ok = await vscode.window.showWarningMessage(
    `Install ${path.basename(local)} as ${cfg().get('target')}/${name} on ${cfg().get('host')}?`, { modal: true }, 'Install');
  if (!ok) return;
  run(ctx, (ssh, scp, remote, staging) => {
    const rjar = `${staging}/${path.basename(local)}`;
    return [
      `${scp} ${lq(local)} ${remote}:${rjar}`,
      `${ssh} ${remote} ${lq(remoteCmd('install', ` --jar ${shq(rjar)} --name ${shq(name)} --sha256 ${sha}`))}`,
    ];
  });
}

async function installFromIfs(ctx) {
  if (!(await ensureConfig())) return;
  const ifs = await vscode.window.showInputBox({ prompt: 'Full IFS path of the JAR already on IBM i', placeHolder: '/home/USER/app.jar', ignoreFocusOut: true });
  if (!ifs) return;
  const name = await vscode.window.showInputBox({ prompt: 'Installed JAR name', value: path.posix.basename(ifs), ignoreFocusOut: true });
  if (!name) return;
  run(ctx, (ssh, _scp, remote) => [`${ssh} ${remote} ${lq(remoteCmd('install', ` --jar ${shq(ifs)} --name ${shq(name)}`))}`]);
}

async function rollback(ctx) {
  if (!(await ensureConfig())) return;
  const name = await vscode.window.showInputBox({ prompt: 'JAR name to roll back (e.g. app.jar)', ignoreFocusOut: true });
  if (!name) return;
  const ok = await vscode.window.showWarningMessage(`Restore previous version of ${name}?`, { modal: true }, 'Rollback');
  if (!ok) return;
  run(ctx, (ssh, _scp, remote) => [`${ssh} ${remote} ${lq(remoteCmd('rollback', ` --name ${shq(name)}`))}`]);
}

async function status(ctx) {
  if (!(await ensureConfig())) return;
  run(ctx, (ssh, _scp, remote) => [`${ssh} ${remote} ${lq(remoteCmd('status'))}`]);
}

function activate(ctx) {
  const reg = (id, fn) => ctx.subscriptions.push(vscode.commands.registerCommand(id, (...a) => fn(ctx, ...a)));
  reg('jarpilot.installFromPc', installFromPc);
  reg('jarpilot.installFromIfs', installFromIfs);
  reg('jarpilot.rollback', rollback);
  reg('jarpilot.status', status);
  reg('jarpilot.configure', configure);
}
function deactivate() {}
module.exports = { activate, deactivate };
