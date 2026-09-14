/*
 * 解密 DevEco 生成的应用签名口令密文。
 *
 * 背景：hvigor 的 SignHap 任务要求 build-profile.json5 中的
 * storePassword/keyPassword 为 DevEco 加密后的十六进制串
 * （AES-128-GCM，密钥由 ~/.ohos/config/material 下的材料派生）。
 * 本脚本复刻了 hvigor 自带 DecipherUtil 的算法，使 CI/脚本也能签名。
 *
 * 用法： node devpwd.js <cipherHex> [materialParentDir]
 * 输出： 仅打印口令长度与前缀，不完整回显；同时写入 $TMPDIR 供脚本读取。
 */
const fs=require('fs'), path=require('path'), crypto=require('crypto');
const DIRS=['fd','ac','ce'];
const COMPONENT=[49,243,9,115,214,175,91,184,211,190,177,88,101,131,192,119];
const toI8=b=>Array.from(b).map(x=>x>127?x-256:x);
const toU8=a=>Buffer.from(a.map(x=>x&0xff));

function readDirBytes(p){
  const out=[];
  for(const e of fs.readdirSync(p).filter(f=>f!=='.DS_Store').sort()){
    const full=path.resolve(p,e);
    if(fs.statSync(full).isDirectory())
      for(const i of fs.readdirSync(full).filter(f=>f!=='.DS_Store').sort())
        out.push(toI8(fs.readFileSync(path.resolve(full,i))));
    else out.push(toI8(fs.readFileSync(full)));
  }
  return out;
}
const xor=(a,b)=>{const n=Math.max(a.length,b.length),o=[];
  for(let i=0;i<n;i++)o.push((a[i%a.length]??0)^(b[i%b.length]??0));return o;};
function xorComponents(l){let e=xor(l[0],l[1]);for(let i=2;i<l.length;i++)e=xor(e,l[i]);return toU8(e);}
function gcm(key,data){
  const r=toU8(data), e=(r[0]<<24)|(r[1]<<16)|(r[2]<<8)|r[3], i=r.length-4-e;
  const d=crypto.createDecipheriv('aes-128-gcm',toU8(key),r.slice(4,4+i));
  d.setAuthTag(r.slice(r.length-16));
  return Buffer.concat([d.update(r.subarray(4+i,r.length-16)),d.final()]);
}
function decryptPwd(parent,cipherHex){
  const mat=path.resolve(parent,'material');
  const fd=readDirBytes(path.resolve(mat,DIRS[0]));
  if(fd.length!==3) throw new Error('fd 块数异常: '+fd.length);
  const salt=readDirBytes(path.resolve(mat,DIRS[1]))[0];
  const work=readDirBytes(path.resolve(mat,DIRS[2]))[0];
  const root=toI8(crypto.pbkdf2Sync(xorComponents(fd.concat([COMPONENT])).toString(),toU8(salt),10000,16,'sha256'));
  return gcm(toI8(gcm(root,work)),Buffer.from(cipherHex,'hex')).toString('utf8');
}
const hex=process.argv[2], parent=process.argv[3]||(process.env.HOME+'/.ohos/config');
if(!hex){console.error('用法: node devpwd.js <cipherHex> [materialParentDir]');process.exit(1);}
try{
  const v=decryptPwd(parent,hex);
  console.log(`OK len=${v.length} prefix=${v.slice(0,2)}****`);
  fs.writeFileSync(process.env.HPS2_PWD_OUT||'/tmp/hps2_pwd.txt',v);
}catch(e){console.error('FAIL '+e.message);process.exit(2);}
