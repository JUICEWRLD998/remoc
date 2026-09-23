const RPCS=["https://eth-mainnet.public.blastapi.io","https://eth.drpc.org"];
const EULER="0x27182842E098f60e3D576794A5bFFb0777E025d3";
const PRE=16700000; // ~2023-03-07, before the 2023-03-13 exploit
async function rpc(method,params){
  for(const u of RPCS){
    try{
      const r=await fetch(u,{method:"POST",headers:{"content-type":"application/json"},
        body:JSON.stringify({jsonrpc:"2.0",id:1,method,params}),signal:AbortSignal.timeout(15000)});
      const j=await r.json();
      if(j.result!==undefined) return {ok:true,val:j.result,rpc:u};
      if(j.error) return {ok:false,err:JSON.stringify(j.error).slice(0,140),rpc:u};
    }catch(e){ var last=e.message; }
  }
  return {ok:false,err:last||"all rpc failed"};
}
// 1. does code exist at the pre-exploit block?
const code=await rpc("eth_getCode",[EULER,"0x"+PRE.toString(16)]);
console.log("eth_getCode @block",PRE,"->",code.ok?`OK len=${(code.val.length-2)/2} bytes via ${code.rpc}`:`FAIL ${code.err}`);
// 2. block timestamp sanity (proves the RPC really serves historical state)
const blk=await rpc("eth_getBlockByNumber",["0x"+PRE.toString(16),false]);
if(blk.ok) console.log("block",PRE,"timestamp ->",new Date(parseInt(blk.val.timestamp,16)*1000).toISOString());
// 3. read a live slot value historically (proxy implementation slot EIP-1967)
const impl=await rpc("eth_getStorageAt",[EULER,"0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc","0x"+PRE.toString(16)]);
console.log("EIP-1967 impl slot @",PRE,"->",impl.ok?impl.val:`FAIL ${impl.err}`);
