// Runs the mocked-host Lua suite on wasmoon (Lua 5.4); no native Lua needed.
// Usage: node tests/run-tests.js [test.lua] [index.lua]
const fs = require('fs');
const path = require('path');
const { LuaFactory } = require('wasmoon');

(async () => {
  const root = path.resolve(__dirname, '..');
  const testFile = process.argv[2] || path.join(__dirname, 'YbxAppTest.lua');
  const appFile = process.argv[3] || path.join(root, 'source', 'ybx', 'index.lua');
  const factory = new LuaFactory();
  const lua = await factory.createEngine();
  await lua.doString(`arg = {[1]=${JSON.stringify(appFile.replace(/\\/g, '/'))}}`);
  lua.global.set('dofile', (p) => lua.doStringSync(fs.readFileSync(String(p), 'utf8')));
  lua.global.set('print', (...args) => console.log(...args.map(String)));
  try {
    await lua.doString(fs.readFileSync(testFile, 'utf8'));
    console.log('TEST SUITE OK');
  } catch (e) {
    console.error('TEST FAILURE:', e && e.message ? e.message : e);
    process.exit(1);
  } finally {
    lua.global.close();
  }
})();
