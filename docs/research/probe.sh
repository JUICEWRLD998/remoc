WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
BLK=0xE4E1C0   # 15000000
for RPC in https://ethereum-rpc.publicnode.com https://eth.llamarpc.com https://eth.drpc.org https://1rpc.io/eth https://eth-mainnet.public.blastapi.io https://rpc.ankr.com/eth; do
  R=$(curl -s -m 12 -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$WETH\",\"$BLK\"]}" "$RPC")
  LEN=$(printf '%s' "$R" | wc -c)
  printf '%-42s bytes=%s  %s\n' "$RPC" "$LEN" "$(printf '%s' "$R" | cut -c1-90)"
done
