// Runs the production storage helper with real host files. OHOS URI/permission/UI behavior
// still needs device testing; the adapter only replaces the platform's file API.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.HPS2_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = path.resolve(__dirname, '../app-hps2/entry/src/main/ets/common/GameStorage.ets');
let failCopy = false;
const adapter = {
  OpenMode: { CREATE: fs.constants.O_CREAT, READ_WRITE: fs.constants.O_RDWR,
    TRUNC: fs.constants.O_TRUNC, READ_ONLY: fs.constants.O_RDONLY },
  openSync: (p, mode) => ({ fd: fs.openSync(p, mode, 0o600) }),
  closeSync: file => fs.closeSync(typeof file === 'number' ? file : file.fd),
  statSync: p => typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p),
  lstatSync: p => fs.lstatSync(p),
  accessSync: p => fs.existsSync(p),
  listFileSync: p => fs.readdirSync(p),
  readTextSync: p => fs.readFileSync(p, 'utf8'),
  writeSync: (fd, value) => fs.writeSync(fd, value),
  renameSync: (a, b) => fs.renameSync(a, b),
  unlinkSync: p => fs.unlinkSync(p),
  async copyFile(src, dst) {
    // Exercise the fd route: URI conversion must not be needed by this helper.
    const data = fs.readFileSync(src);
    fs.writeFileSync(dst, failCopy ? data.subarray(0, 2) : data);
    if (failCopy) throw new Error('simulated storage full');
  }
};
const compiled = ts.transpileModule(fs.readFileSync(source, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const mod = { exports: {} };
vm.runInNewContext(compiled, {
  exports: mod.exports,
  require: name => {
    assert.equal(name, '@ohos.file.fs');
    return { default: adapter };
  }
}, { filename: source });
const { GameStorage, resolveBootImage } = mod.exports;
// Run the actual page's startBoot method as well: null must be checked at the
// call site, otherwise a safe resolver can still fall through to startBios('').
const page = fs.readFileSync(path.resolve(__dirname,
  '../app-hps2/entry/src/main/ets/pages/Index.ets'), 'utf8');
const bootMethod = page.slice(page.indexOf('  private async startBoot():'),
  page.indexOf('  private async setGameOrientation('));
const chooseMethod = page.slice(page.indexOf('  private async chooseGame('),
  page.indexOf('  private addExternalGameEntry('));
assert.ok(bootMethod.includes('effectiveGamePath'));
const bootModule = { exports: {} };
let nativeStarts = 0;
vm.runInNewContext(ts.transpileModule('export class BootHarness {\n' + bootMethod + chooseMethod + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, {
  exports: bootModule.exports,
  hps2core: { startBios: () => { nativeStarts++; return 1; }, canOpenGameFile: () => '1' },
  GameStorage, fs: adapter, libHumanSize: n => `${n} B`,
  hilog: { info() {}, error() {} }, DOMAIN: 0, TAG: 'test'
});
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'hps2-storage-'));
const games = path.join(root, 'games');
fs.mkdirSync(games);
let checks = 0;
function ok(value, message) { assert.ok(value, message); checks++; }

(async () => {
  let approvals = 0, copies = 0, launches = 0;
  const approve = async () => { approvals++; return true; };
  const copy = async () => { copies++; return 'private/game.chd'; };
  assert.equal(await resolveBootImage('external/game.chd', () => true, approve, copy), 'external/game.chd');
  ok(approvals === 0 && copies === 0, 'direct reads must never copy');
  const cancelled = await resolveBootImage('external/game.chd', () => false, async () => false, copy);
  if (cancelled !== null) launches++;
  ok(cancelled === null && copies === 0 && launches === 0, 'cancel cannot fall through to BIOS boot');
  assert.equal(await resolveBootImage('', () => { throw new Error('should not check BIOS'); }, approve, copy), '');
  ok(approvals === 0 && copies === 0, 'deliberate BIOS boot remains available');
  assert.equal(await resolveBootImage('external/game.chd', () => false, approve, copy), 'private/game.chd');
  ok(approvals === 1 && copies === 1, 'copy requires explicit approval');
  await assert.rejects(resolveBootImage('external/game.chd', () => false, approve,
    async () => { throw new Error('copy failed'); }), /copy failed/);
  checks++;
  const boot = new bootModule.exports.BootHarness();
  Object.assign(boot, {
    gameStorageBusy: false, scanning: false, picking: '', stopping: false, busy: false,
    biosPath: 'bios.bin', storeBuild: false, jitChecked: true, jitAvailable: true,
    clearError() { this.statusError = ''; },
    resolveGamePathForBoot: async () => null,
    setGameOrientation: async () => { throw new Error('cancelled boot changed orientation'); }
  });
  await boot.startBoot();
  ok(nativeStarts === 0 && !boot.busy && boot.statusError.includes('取消'),
    'real startBoot stops on cancellation without calling native or changing orientation');
  boot.resolveGamePathForBoot = async () => { throw new Error('simulated copy error'); };
  await boot.startBoot();
  ok(nativeStarts === 0 && !boot.busy && boot.statusError.includes('simulated copy error'),
    'real startBoot stops on copy error and unlocks the start button');
  let orientationChanges = 0;
  Object.assign(boot, {
    resolveGamePathForBoot: async () => '',
    setGameOrientation: async () => { orientationChanges++; },
    dataRoot: () => 'root', biosDir: () => 'bios', setupVirtualPad() {},
    setImmersive() {}, syncJitFromStatus() {}, startPolling() {}
  });
  await boot.startBoot();
  ok(nativeStarts === 1 && orientationChanges === 1 && boot.viewMode === 'game' && !boot.busy,
    'real startBoot still allows an intentional BIOS-only boot');
  const chooser = new bootModule.exports.BootHarness();
  const selectedDir = '/storage/Users/currentUser/Download/PS2';
  const dirUri = 'file://docs' + selectedDir;
  Object.assign(chooser, {
    busy: false, statusRunning: false, stopping: false, gameStorageBusy: false, scanning: false,
    gameStoragePath: selectedDir, selectedGameUriPersisted: true,
    gameStorageConfig: { introSeen: true, directoryPath: selectedDir, directoryUri: dirUri, sources: [] },
    pickInPlace: async () => 'file://docs' + selectedDir + '/game.chd|game.chd|1 MB',
    uriToPath: () => selectedDir + '/game.chd', saveGameStorage: () => true,
    saveGameSelection() {}, addExternalGameEntry() {}, refreshGames() {}, refreshMemoryCards() {}, endLoading() {}
  });
  await chooser.chooseGame(true);
  ok(chooser.gameStorageConfig.directoryUri === dirUri && chooser.gameStorageConfig.directoryPath === selectedDir,
    'verifying a game must preserve the explicitly selected directory grant');
  chooser.uriToPath = () => '/storage/Users/currentUser/ps2/other.chd';
  await chooser.chooseGame(true);
  ok(chooser.gameStorageConfig.directoryUri === dirUri && chooser.gameStorageConfig.directoryPath === selectedDir,
    'testing another game must not replace the configured game directory');
  chooser.gameStorageConfig = { introSeen: false, directoryPath: '', directoryUri: '', sources: [] };
  await chooser.chooseGame(true);
  ok(chooser.gameStorageConfig.directoryPath === '/storage/Users/currentUser/ps2' &&
    chooser.gameStorageConfig.directoryUri === '', 'file selection may infer a location but never a directory grant');

  const external = path.join(root, 'original.chd');
  const payload = Buffer.from('original game image fixture');
  fs.writeFileSync(external, payload);
  fs.writeFileSync(path.join(games, 'game.chd'), 'existing game');
  const dest = await GameStorage.copyImage(external, root, 'game.chd');
  ok(dest.endsWith('/game-2.chd'), 'same-name imports get a distinct destination');
  assert.equal(fs.readFileSync(path.join(games, 'game.chd'), 'utf8'), 'existing game');
  ok(fs.readFileSync(dest).equals(payload) && fs.readFileSync(external).equals(payload), 'copy preserves both existing and source files');
  failCopy = true;
  await assert.rejects(GameStorage.copyImage(external, root, 'failed.chd'), /storage full/);
  ok(!fs.existsSync(path.join(games, 'failed.chd')) && !fs.readdirSync(games).some(n => n.startsWith('.hps2-import-')),
    'failed copies remove temporary bytes and never publish an incomplete image');
  failCopy = false;
  fs.writeFileSync(path.join(root, 'empty.chd'), '');
  await assert.rejects(GameStorage.copyImage(path.join(root, 'empty.chd'), root, 'empty.chd'));
  ok(!fs.existsSync(path.join(games, 'empty.chd')), 'empty image is not accepted');
  for (const name of ['../original.chd', '/original.chd', '..', 'x\\y.chd', 'x\0.chd']) {
    await assert.rejects(GameStorage.copyImage(external, root, name));
    assert.throws(() => GameStorage.deletePrivateFile(root, name));
  }
  checks++;
  fs.writeFileSync(path.join(games, 'settings.json'), '{}');
  fs.symlinkSync(external, path.join(games, 'linked.chd'));
  fs.writeFileSync(path.join(games, '.hps2-import-interrupted'), 'partial');
  const files = GameStorage.privateFiles(root);
  ok(!files.some(f => f.name === 'linked.chd' || f.name === 'settings.json') &&
    files.some(f => f.incomplete), 'cleanup list excludes symlinks/metadata and includes interrupted imports');
  assert.throws(() => GameStorage.deletePrivateFile(root, 'linked.chd'));
  assert.throws(() => GameStorage.deletePrivateFile(root, 'settings.json'));
  GameStorage.deletePrivateFile(root, 'game-2.chd');
  GameStorage.deletePrivateFile(root, '.hps2-import-interrupted');
  ok(!fs.existsSync(dest) && fs.existsSync(external) && fs.existsSync(path.join(games, 'game.chd')),
    'cleanup only deletes the selected private file');

  const config = GameStorage.load(root);
  GameStorage.rememberSource(config, '/external/game.chd', 'file://docs/external/game.chd');
  config.introSeen = true;
  GameStorage.save(root, config);
  const restored = GameStorage.load(root);
  ok(restored.introSeen && GameStorage.sourceUri(restored, '/external/game.chd') === 'file://docs/external/game.chd',
    'original authorized URI survives restart for fallback copying');
  GameStorage.rememberSource(restored, '/external/game.chd', 'file://docs/new/game.chd');
  ok(restored.sources.length === 1 && restored.sources[0].uri === 'file://docs/new/game.chd', 'reselection replaces the source URI');
  const otherRoot = path.join(root, 'other');
  fs.mkdirSync(otherRoot);
  fs.symlinkSync(games, path.join(otherRoot, 'games'));
  assert.throws(() => GameStorage.deletePrivateFile(otherRoot, 'game.chd'));
  await assert.rejects(GameStorage.copyImage(external, otherRoot, 'game.chd'));
  checks++;
  console.log(`PASS: ${checks} game-storage checks (real host files; device authorization/UI pending)`);
})().catch(e => { console.error(e); process.exitCode = 1; })
  .finally(() => fs.rmSync(root, { recursive: true, force: true }));
