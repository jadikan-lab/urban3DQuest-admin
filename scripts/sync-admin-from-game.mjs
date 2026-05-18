#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const adminRoot = path.resolve(__dirname, '..');
const defaultGameRoot = path.resolve(adminRoot, '..', 'urban3DQuest');
const cliArgs = process.argv.slice(2);
const checkOnly = cliArgs.includes('--check');
const gameRootArg = cliArgs.find(arg => arg !== '--check');
const gameRoot = gameRootArg ? path.resolve(gameRootArg) : defaultGameRoot;

const adminHtmlPath = path.join(adminRoot, 'admin.html');
const gameEnvPath = path.join(gameRoot, 'js', 'supabase-env.js');

if (!fs.existsSync(adminHtmlPath)) {
  throw new Error(`admin.html introuvable: ${adminHtmlPath}`);
}
if (!fs.existsSync(gameEnvPath)) {
  throw new Error(`supabase-env.js introuvable: ${gameEnvPath}`);
}

const envSource = fs.readFileSync(gameEnvPath, 'utf8');
const envMatch = envSource.match(/const\s+SUPABASE_ENVS\s*=\s*\{[\s\S]*?\n\};/);
if (!envMatch) {
  throw new Error('Bloc SUPABASE_ENVS non trouvé dans supabase-env.js');
}

const envBlock = envMatch[0]
  .replace(/^const\s+SUPABASE_ENVS\s*=\s*/, 'var SUPABASE_ENVS=')
  .replace(/\n\};$/, '\n};');

const headHash = execSync('git rev-parse --short HEAD', { cwd: gameRoot, encoding: 'utf8' }).trim();
if (!headHash) {
  throw new Error('Impossible de récupérer le hash git court du repo jeu');
}

let adminHtml = fs.readFileSync(adminHtmlPath, 'utf8');

const envStart = '// <SYNC:SUPABASE_ENVS_START>';
const envEnd = '// <SYNC:SUPABASE_ENVS_END>';
const verStart = '// <SYNC:GAME_WEB_VERSION_START>';
const verEnd = '// <SYNC:GAME_WEB_VERSION_END>';

const envPattern = new RegExp(`${envStart}[\\s\\S]*?${envEnd}`);
if (!envPattern.test(adminHtml)) {
  throw new Error('Marqueurs SUPABASE_ENVS introuvables dans admin.html');
}

const versionPattern = new RegExp(`${verStart}[\\s\\S]*?${verEnd}`);
if (!versionPattern.test(adminHtml)) {
  throw new Error('Marqueurs GAME_WEB_VERSION introuvables dans admin.html');
}

adminHtml = adminHtml.replace(
  envPattern,
  `${envStart}\n${envBlock}\n${envEnd}`
);

adminHtml = adminHtml.replace(
  versionPattern,
  `${verStart}\nvar GAME_WEB_VERSION='${headHash}'; // cache-busting for mobile scans — synced from urban3DQuest HEAD\n${verEnd}`
);

if (checkOnly) {
  const currentEnvBlock = adminHtml.match(envPattern)?.[0];
  const currentVersionBlock = adminHtml.match(versionPattern)?.[0];

  if (currentEnvBlock !== `${envStart}\n${envBlock}\n${envEnd}`) {
    throw new Error('admin.html n\'est pas synchronisé avec js/supabase-env.js');
  }

  if (currentVersionBlock !== `${verStart}\nvar GAME_WEB_VERSION='${headHash}'; // cache-busting for mobile scans — synced from urban3DQuest HEAD\n${verEnd}`) {
    throw new Error(`admin.html n\'est pas synchronisé avec le HEAD du repo jeu (${headHash})`);
  }

  console.log('admin.html est synchronisé avec le repo jeu');
  process.exit(0);
}

fs.writeFileSync(adminHtmlPath, adminHtml, 'utf8');

console.log(`Synced SUPABASE_ENVS and GAME_WEB_VERSION from: ${gameRoot}`);
console.log(`GAME_WEB_VERSION=${headHash}`);
