// JarPilot for IBM i — VS Code extension (jarpilot) v1.1.0
// Runs ssh/scp in an integrated terminal so password / host-key prompts just work.
const vscode = require('vscode');
const path = require('path');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');

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

// ---------------------------------------------------------------------------
// Server setup (any server setup JAR delivered for IBM i)
// The wizard runs on IBM i in the terminal (ssh -t): Steps 3-9 are asked there and
// every answer is checked so the new server never reuses an existing library,
// install directory, instance name or port.
// ---------------------------------------------------------------------------
function serverCmd(action, extra) {
  const { staging } = sshParts();
  return `/QOpenSys/usr/bin/sh ${shq(staging + '/jarpilot.sh')} ${action} --host ${shq(cfg().get('host'))}` + (extra || '');
}

async function installServer(ctx, uri) {
  if (!(await ensureConfig())) return;
  let local, ifs;
  if (uri) local = uri.fsPath;
  else {
    const src = await vscode.window.showQuickPick(
      ['Setup JAR is on this PC (upload to IFS)', 'Setup JAR is already on the IFS'], { placeHolder: 'Step 1 - where is the setup JAR?' });
    if (!src) return;
    if (src.startsWith('Setup JAR is on this PC')) {
      const pick = await vscode.window.showOpenDialog({ filters: { 'Java archive': ['jar'] }, canSelectMany: false });
      if (!pick) return;
      local = pick[0].fsPath;
    } else {
      ifs = await vscode.window.showInputBox({ prompt: 'Full IFS path of the setup JAR', placeHolder: '/tmp/setup-server.jar', ignoreFocusOut: true });
      if (!ifs) return;
    }
  }
  const mode = await vscode.window.showQuickPick(
    [{ label: 'Auto', description: 'JarPilot answers the installer with the checked values', v: '' },
     { label: 'Manual', description: 'I type the answers in the installer myself', v: ' --manual' }],
    { placeHolder: 'How should the vendor installer be answered?' });
  if (!mode) return;
  const ok = await vscode.window.showInformationMessage(
    `Install server from ${path.basename(local || ifs)} on ${cfg().get('host')}? You will answer Steps 3-9 in the JarPilot terminal (use QSECOFR or equivalent).`,
    { modal: true }, 'Start setup');
  if (!ok) return;
  run(ctx, (ssh, scp, remote, staging) => {
    const rjar = local ? `${staging}/${path.basename(local)}` : ifs;
    const lines = [];
    if (local) lines.push(`${scp} ${lq(local)} ${remote}:${rjar}`);
    lines.push(`${ssh} -t ${remote} ${lq(serverCmd('server-setup', ` --jar ${shq(rjar)}${mode.v}`))}`);
    return lines;
  });
}

async function startServer(ctx) {
  if (!(await ensureConfig())) return;
  const lib = await vscode.window.showInputBox({ prompt: 'Server library (added with ADDLIBLE)', ignoreFocusOut: true });
  if (!lib) return;
  const inst = await vscode.window.showInputBox({ prompt: 'Instance name', ignoreFocusOut: true });
  if (!inst) return;
  const sc = await vscode.window.showInputBox({ prompt: 'CL command that starts the server (&INSTANCE = instance name)', placeHolder: 'STRMYSVR INSTANCE(&INSTANCE)', ignoreFocusOut: true });
  if (!sc) return;
  const port = await vscode.window.showInputBox({ prompt: 'HTTP port', value: '5257', ignoreFocusOut: true });
  if (!port) return;
  run(ctx, (ssh, _scp, remote) => [`${ssh} ${remote} ${lq(serverCmd('server-start', ` --lib ${shq(lib)} --instance ${shq(inst)} --start-cmd ${shq(sc)} --http-port ${Number(port)}`))}`]);
}

function httpGet(url, ms) {
  return new Promise((resolve) => {
    const req = http.get(url, { timeout: ms }, (res) => { res.resume(); resolve(res.statusCode); });
    req.on('timeout', () => { req.destroy(); resolve(0); });
    req.on('error', () => resolve(0));
  });
}

async function checkServer() {
  if (!(await ensureConfig())) return;
  const port = await vscode.window.showInputBox({ prompt: 'Server HTTP port', value: '5257', ignoreFocusOut: true });
  if (!port) return;
  const url = `http://${cfg().get('host')}:${Number(port)}/about`;
  const code = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: `Checking ${url}` },
    async () => { for (let i = 0; i < 12; i++) { const c = await httpGet(url, 5000); if (c === 200) return c; await new Promise((r) => setTimeout(r, 5000)); } return 0; });
  if (code === 200) {
    const open = await vscode.window.showInformationMessage(`Server is up: ${url}`, 'Open in browser');
    if (open) vscode.env.openExternal(vscode.Uri.parse(url));
  } else {
    vscode.window.showWarningMessage(`No answer from ${url}. Check the instance job log, the port, or the firewall.`);
  }
}

function activate(ctx) {
  const reg = (id, fn) => ctx.subscriptions.push(vscode.commands.registerCommand(id, (...a) => fn(ctx, ...a)));
  reg('jarpilot.installFromPc', installFromPc);
  reg('jarpilot.installFromIfs', installFromIfs);
  reg('jarpilot.rollback', rollback);
  reg('jarpilot.status', status);
  reg('jarpilot.configure', configure);
  reg('jarpilot.installServer', installServer);
  reg('jarpilot.startServer', startServer);
  reg('jarpilot.checkServer', checkServer);
}
function deactivate() {}
module.exports = { activate, deactivate };
