
# Mofu Mofu Genesis NFT Bridge – Aptos Move Contract

**Network:** Testnet  
**Module Address:** `0x3dd2940093837771f6396c3a20d5f4b7034830dee5540a6d0841a3a5eab4e81c`

---

## Overview

This Move contract implements a cross-chain NFT bridge for the Mofu Mofu Genesis collection, enabling secure NFT transfers from Ethereum to Aptos. It features validator-based signature verification, pre-minting, claim logic, and robust admin controls.

---

## Modules

- `bridge::bridge` – Main bridge logic, validator management, claim, and record creation.
- `bridge::bridge_message` – Message hash and signature verification utilities.
- `bridge::mofu_nft` – NFT minting, collection management, and royalty logic.

---

## Deployment

```sh
aptos move publish --profile <your-profile> --assume-yes
```

### Format Contracts

```sh
aptos move fmt --config max_width=100,indent_size=4
```