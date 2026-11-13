#!/usr/bin/env python3
"""Fresh Anvil acceptance test. Python stdlib only; mock assets and unlocked local accounts."""
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def tool(name):
    found = shutil.which(name)
    fallback = Path.home() / ".foundry" / "bin" / name
    if found:
        return found
    if fallback.is_file():
        return str(fallback)
    raise RuntimeError(f"Install Foundry; missing {name}")

def command(*args):
    p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=120)
    if p.returncode:
        raise RuntimeError(f"{args[0]} failed\n{p.stdout[-6000:]}\n{p.stderr[-3000:]}")
    return p.stdout.strip()

def words(raw):
    return [int(raw[i:i+64],16) for i in range(2,len(raw),64)]

def main():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1",0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    def rpc(method,params=None):
        payload = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params or []}).encode()
        req = urllib.request.Request(url,payload,{"Content-Type":"application/json"})
        with urllib.request.urlopen(req,timeout=10) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]

    with tempfile.TemporaryDirectory(prefix="harbor-anvil-") as directory:
        logpath = Path(directory)/"node.log"
        with logpath.open("w") as log:
            node = subprocess.Popen(
                [tool("anvil"),"--host","127.0.0.1","--port",str(port),"--chain-id","31337","--silent"],
                stdout=log,stderr=subprocess.STDOUT,
            )
            try:
                for _ in range(100):
                    if node.poll() is not None:
                        raise RuntimeError(logpath.read_text())
                    try:
                        rpc("eth_chainId")
                        break
                    except OSError:
                        time.sleep(0.1)
                else:
                    raise RuntimeError("Local Anvil did not start")
                account = rpc("eth_accounts")[0]
                output = command(tool("forge"),"script","script/LocalDemo.s.sol:LocalDemo",
                                 "--rpc-url",url,"--sender",account,"--unlocked","--broadcast","--non-interactive","-vv")
                def address(label):
                    found = re.search(label+r":\s*(0x[0-9a-fA-F]{40})",output)
                    if not found:
                        raise RuntimeError(f"Missing {label}\n{output[-5000:]}")
                    return found.group(1).lower()
                market = address("Demo market")
                manager = address("PoolManager")
                hook = address("Harbor hook")
                def call(to,signature,*args):
                    data = command(tool("cast"),"calldata",signature,*args)
                    return words(rpc("eth_call",[{"to":to,"data":data},"latest"]))
                token0 = "0x"+format(call(market,"token0()")[0],"040x")
                token1 = "0x"+format(call(market,"token1()")[0],"040x")
                topic = command(tool("cast"),"keccak",
                                "InternalSwap(bytes32,address,bool,bool,uint256,uint256,uint256)").lower()
                native_topic = command(tool("cast"),"keccak",
                                "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)").lower()

                def snapshot():
                    values = call(market,"snapshot()")
                    assert len(values)==6
                    x,y,c0,c1,supply,native_liquidity=values
                    assert x==c0 and y==c1, f"claims do not match reserves: {values}"
                    assert native_liquidity==0, "native concentrated liquidity must remain unused"
                    assert call(token0,"balanceOf(address)",manager)[0]==x
                    assert call(token1,"balanceOf(address)",manager)[0]==y
                    return values

                def send(signature):
                    data = command(tool("cast"),"calldata",signature)
                    tx = rpc("eth_sendTransaction",[{"from":account,"to":market,"data":data,"gas":hex(3_000_000)}])
                    for _ in range(100):
                        receipt = rpc("eth_getTransactionReceipt",[tx])
                        if receipt:
                            break
                        time.sleep(0.05)
                    assert receipt and int(receipt["status"],16)==1, f"{signature} reverted: {tx}"
                    return tx,receipt

                initial = snapshot()
                assert initial==[1000*10**18]*5+[0]
                balance_b = call(token1,"balanceOf(address)",market)[0]
                first_tx,first_receipt = send("swapExactInput()")
                first = snapshot()
                expected_out=98_911_870_414_558_559_985
                assert first[0]==1100*10**18 and first[1]==1000*10**18-expected_out
                assert call(token1,"balanceOf(address)",market)[0]-balance_b==expected_out
                events = [e for e in first_receipt["logs"] if e["address"].lower()==hook and e["topics"][0].lower()==topic]
                assert len(events)==1
                assert words(events[0]["data"])==[1,1,100*10**18,expected_out,10**17]
                native = [e for e in first_receipt["logs"] if e["address"].lower()==manager and e["topics"][0].lower()==native_topic]
                assert len(native)==1 and words(native[0]["data"])[:2]==[0,0], "expected native no-op"

                balance_a = call(token0,"balanceOf(address)",market)[0]
                second_tx,second_receipt = send("swapExactOutput()")
                second = snapshot()
                assert call(token0,"balanceOf(address)",market)[0]-balance_a==10*10**18
                assert second[0]==first[0]-10*10**18 and second[1]>first[1]
                events = [e for e in second_receipt["logs"] if e["address"].lower()==hook and e["topics"][0].lower()==topic]
                assert len(events)==1
                reverse=words(events[0]["data"])
                assert reverse[:2]==[0,0] and reverse[3]==10*10**18 and reverse[2]>0 and reverse[4]>0

                exit_tx,_ = send("exit()")
                final = snapshot()
                assert final==[0]*6
                assert call(token0,"balanceOf(address)",market)[0]==10_000*10**18
                assert call(token1,"balanceOf(address)",market)[0]==10_000*10**18
                print(json.dumps({"result":"PASS","chain_id":31337,"hook":hook,
                                  "initial_reserves":[initial[0],initial[1]],
                                  "exact_input":{"transaction":first_tx,"input":100*10**18,"output":expected_out,"fee":10**17},
                                  "reverse_exact_output":{"transaction":second_tx,"input":reverse[2],"output":reverse[3],"fee":reverse[4]},
                                  "native_liquidity":0,"claims_match_reserves":True,
                                  "full_exit_transaction":exit_tx,"final_reserves":[0,0],"final_lp_supply":0},indent=2))
            finally:
                node.terminate()
                try:
                    node.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    node.kill()
                    node.wait()

if __name__=="__main__":
    main()
