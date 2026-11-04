import fs from '@ohos.file.fs';

export interface GameSource {
  path: string;
  uri: string;
}

export interface GameStorageConfig {
  introSeen: boolean;
  directoryPath: string;
  directoryUri: string;
  sources: Array<GameSource>;
}

export interface PrivateGameFile {
  name: string;
  size: number;
  incomplete: boolean;
}

/** An empty path deliberately boots BIOS; cancellation must remain distinct from it. */
export async function resolveBootImage(path: string, canOpen: () => boolean,
  approveCopy: () => Promise<boolean>, copy: () => Promise<string>): Promise<string | null> {
  if (path.length === 0 || canOpen()) {
    return path;
  }
  if (!await approveCopy()) {
    return null;
  }
  return await copy();
}

export class GameStorage {
  static load(root: string): GameStorageConfig {
    const empty: GameStorageConfig = {
      introSeen: false, directoryPath: '', directoryUri: '', sources: []
    };
    try {
      const value = JSON.parse(fs.readTextSync(root + '/game-storage.json')) as GameStorageConfig;
      empty.introSeen = value.introSeen === true;
      if (typeof value.directoryPath === 'string') empty.directoryPath = value.directoryPath;
      if (typeof value.directoryUri === 'string') empty.directoryUri = value.directoryUri;
      if (Array.isArray(value.sources)) {
        empty.sources = value.sources.filter((s: GameSource) => s !== null &&
          typeof s.path === 'string' && typeof s.uri === 'string' && s.uri.startsWith('file://'));
      }
    } catch (_e) {
      // A missing/invalid preference never authorizes copying or deleting anything.
    }
    return empty;
  }

  static save(root: string, config: GameStorageConfig): void {
    const path = root + '/game-storage.json';
    const tmp = path + '.tmp';
    const file = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(config));
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, path);
  }

  static rememberSource(config: GameStorageConfig, path: string, uri: string): void {
    config.sources = config.sources.filter((s: GameSource) => s.path !== path);
    config.sources.push({ path: path, uri: uri });
  }

  static sourceUri(config: GameStorageConfig, path: string): string {
    for (const source of config.sources) {
      if (source.path === path) return source.uri;
    }
    return path;
  }

  static isGameName(name: string): boolean {
    const lower = name.toLowerCase();
    return ['.iso', '.chd', '.bin', '.img', '.cso', '.gz', '.elf']
      .some((suffix: string) => lower.endsWith(suffix));
  }

  private static assertGameDir(root: string): string {
    const dir = root + '/games';
    const stat = fs.lstatSync(dir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('游戏副本目录无效');
    return dir;
  }

  private static assertName(name: string): void {
    if (!name || name === '.' || name === '..' || name.includes('/') ||
      name.includes('\\') || name.includes('\0')) throw new Error('文件名无效');
  }

  static privateFiles(root: string): Array<PrivateGameFile> {
    const dir = GameStorage.assertGameDir(root);
    const out: Array<PrivateGameFile> = [];
    for (const name of fs.listFileSync(dir)) {
      GameStorage.assertName(name);
      const stat = fs.lstatSync(dir + '/' + name);
      const incomplete = name.startsWith('.hps2-import-');
      if (stat.isFile() && !stat.isSymbolicLink() && (incomplete || GameStorage.isGameName(name))) {
        out.push({ name: name, size: stat.size, incomplete: incomplete });
      }
    }
    return out.sort((a: PrivateGameFile, b: PrivateGameFile) => b.size - a.size);
  }

  /** Only a regular, direct child of our own games directory can be removed. */
  static deletePrivateFile(root: string, name: string): void {
    GameStorage.assertName(name);
    const dir = GameStorage.assertGameDir(root);
    const path = dir + '/' + name;
    const stat = fs.lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() ||
      (!GameStorage.isGameName(name) && !name.startsWith('.hps2-import-'))) {
      throw new Error('只能清理应用目录内的游戏副本');
    }
    fs.unlinkSync(path);
  }

  /** Never truncate an existing image; failed transfers leave no selectable partial image. */
  static async copyImage(source: string, root: string, name: string): Promise<string> {
    GameStorage.assertName(name);
    if (!GameStorage.isGameName(name)) throw new Error('不支持的游戏镜像格式');
    const dir = GameStorage.assertGameDir(root);
    const dot = name.lastIndexOf('.');
    let dest = dir + '/' + name;
    let index = 2;
    while (fs.accessSync(dest)) {
      dest = dir + '/' + name.substring(0, dot) + '-' + index.toString() + name.substring(dot);
      index++;
    }
    let temp = dir + '/.hps2-import-' + Date.now().toString();
    while (fs.accessSync(temp)) temp += '-';
    let sourceFile: fs.File | null = null;
    let destFile: fs.File | null = null;
    try {
      sourceFile = fs.openSync(source, fs.OpenMode.READ_ONLY);
      const size = fs.statSync(sourceFile.fd).size;
      if (size <= 0) throw new Error('游戏文件为空');
      destFile = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try {
        await fs.copyFile(sourceFile.fd, destFile.fd);
        if (fs.statSync(destFile.fd).size !== size) throw new Error('游戏复制不完整');
      } finally {
        const closedFile = destFile;
        destFile = null;
        fs.closeSync(closedFile);
      }
      if (fs.accessSync(dest)) throw new Error('目标文件已存在，请重试');
      fs.renameSync(temp, dest);
      return dest;
    } finally {
      try {
        if (destFile !== null) fs.closeSync(destFile);
      } finally {
        try {
          if (sourceFile !== null) fs.closeSync(sourceFile);
        } finally {
          if (fs.accessSync(temp)) fs.unlinkSync(temp);
        }
      }
    }
  }
}
