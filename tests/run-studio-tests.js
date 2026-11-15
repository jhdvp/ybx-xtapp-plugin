const fs=require('fs');const path=require('path');const {LuaFactory}=require('wasmoon');
(async()=>{const root=path.resolve(__dirname,'../source/ybx-studio');const lua=await new LuaFactory().createEngine();try{
for(const f of ['index.lua','lockscreen.lua','app/sync.lua','app/reading.lua','app/sleep_card.lua','app/diagnostics.lua','app/updater.lua']){const code=fs.readFileSync(path.join(root,f),'utf8');lua.global.set('sourceText',code);await lua.doString('assert(load(sourceText))');}
const manifest=JSON.parse(fs.readFileSync(path.join(root,'manifest.json')));const app=fs.readFileSync(path.join(root,'index.lua'),'utf8');if(!app.includes(`local VERSION = '${manifest.version}'`))throw Error('Version mismatch');
for(const name of ['sync','diagnostics','updater','reading','sleep_card']) await lua.doString('package.preload["app.'+name+'"]=function()\n'+fs.readFileSync(path.join(root,'app/'+name+'.lua'),'utf8')+'\nend');
lua.global.set('appSource',app);
for(const name of ['StudioInputTest.lua','StudioSyncTest.lua','StudioDiagnosticsTest.lua','StudioUpdaterTest.lua']) await lua.doString(fs.readFileSync(path.join(__dirname,name),'utf8'));console.log('PASS: all cloud Lua files parse; manifest/code version agree');
}finally{lua.global.close();}})().catch(e=>{console.error(e);process.exit(1)});
