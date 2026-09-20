import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, mkdir, writeFile, readFile, copyFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import test from 'node:test';

const run=promisify(execFile);

test('HLS library restore requires a trusted digest and preserves installed bytes on mismatch', async () => {
  const root=await mkdtemp(path.join(tmpdir(),'macidm-hls-library-'));
  try {
    const scripts=path.join(root,'scripts');
    const lib=path.join(root,'BrowserExtension/chrome/lib');
    const bin=path.join(root,'bin');
    await Promise.all([mkdir(scripts),mkdir(lib,{recursive:true}),mkdir(bin)]);
    const script=path.join(scripts,'fetch-hls.sh');
    await copyFile(new URL('../../../scripts/fetch-hls.sh',import.meta.url),script);
    const bytes='var Hls = {}; /*'+ 'x'.repeat(51000)+'*/';
    const fixture=path.join(root,'download.js');
    await writeFile(fixture,bytes);
    const stub='#!/bin/bash\nwhile [[ $# -gt 0 ]]; do\n  if [[ "$1" == "-o" ]]; then cp "$HLS_FIXTURE" "$2"; exit; fi\n  shift\ndone\nexit 1\n';
    await writeFile(path.join(bin,'curl'),stub,{mode:0o700});
    const env={...process.env,PATH:bin+path.delimiter+process.env.PATH,HLS_FIXTURE:fixture,HLS_JS_SHA256:'',HLS_JS_VERSION:'1.5.13'};
    await assert.rejects(run('bash',[script],{env}),/expected SHA-256 is required/);
    await writeFile(path.join(lib,'hls.light.min.js.integrity'),createHash('sha256').update(bytes).digest('hex')+'\n1.5.13\n');
    await run('bash',[script],{env});
    assert.equal(await readFile(path.join(lib,'hls.light.min.js'),'utf8'),bytes);
    await writeFile(fixture,bytes+'tampered');
    await assert.rejects(run('bash',[script],{env}),/sha256 mismatch/);
    assert.equal(await readFile(path.join(lib,'hls.light.min.js'),'utf8'),bytes);
  } finally { await rm(root,{recursive:true,force:true}); }
});
